// Pure logic of the staged dispatch ladder (lib/src/core/dispatch_ladder.dart):
// parsing the stored rings, expanding them to the runtime ladder, the reach a
// request has been offered to (by pushed step and by elapsed time), and the
// narrowest-first rule resolution. Mirrors supabase/tests/dispatch_ladder_0417.sql.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/core/dispatch_ladder.dart';

void main() {
  const steps = [
    (radiusKm: 2.0, holdSec: 5),
    (radiusKm: 5.0, holdSec: 5),
    (radiusKm: 10.0, holdSec: 0),
  ];

  group('expand', () {
    test('cumulative after_sec + a trailing everybody ring', () {
      final l = const DispatchLadderRule(level: 'master', steps: steps, offerEveryone: true).expand();
      expect(l.rings.map((r) => r.afterSec).toList(), [0, 5, 10, 10]);
      expect(l.rings.map((r) => r.radiusKm).toList(), [2.0, 5.0, 10.0, null]);
    });

    test('no everybody ring when offer_everyone is false', () {
      final l = const DispatchLadderRule(level: 'master', steps: steps, offerEveryone: false).expand();
      expect(l.rings.length, 3);
      expect(l.rings.last.radiusKm, 10.0);
    });
  });

  group('reach by pushed step (what the on-screen list gates on)', () {
    final l = const DispatchLadderRule(level: 'master', steps: steps, offerEveryone: true).expand();
    test('nothing pushed yet -> 0', () => expect(l.reachedRadiusKmByStep(0), 0));
    test('one ring pushed -> 2 km', () => expect(l.reachedRadiusKmByStep(1), 2));
    test('two rings pushed -> 5 km', () => expect(l.reachedRadiusKmByStep(2), 5));
    test('three rings pushed -> 10 km', () => expect(l.reachedRadiusKmByStep(3), 10));
    test('everybody ring pushed -> unbounded', () => expect(l.reachedRadiusKmByStep(4), double.infinity));
    test('a step past the end clamps to the last ring', () => expect(l.reachedRadiusKmByStep(9), double.infinity));
  });

  group('reach by elapsed time (parity with the server)', () {
    final l = const DispatchLadderRule(level: 'master', steps: steps, offerEveryone: true).expand();
    test('t=0 -> 2 km', () => expect(l.reachedRadiusKmByTime(0), 2));
    test('t=7 -> 5 km', () => expect(l.reachedRadiusKmByTime(7), 5));
    test('t=10 -> everybody', () => expect(l.reachedRadiusKmByTime(10), double.infinity));
  });

  group('fromStamped', () {
    test('parses the frozen array; null radius is the everybody ring', () {
      final l = DispatchLadder.fromStamped([
        {'after_sec': 0, 'radius_km': 2},
        {'after_sec': 5, 'radius_km': 5},
        {'after_sec': 10, 'radius_km': null},
      ]);
      expect(l, isNotNull);
      expect(l!.reachedRadiusKmByStep(2), 5);
      expect(l.reachedRadiusKmByStep(3), double.infinity);
    });

    test('null / empty / non-list is no ladder', () {
      expect(DispatchLadder.fromStamped(null), isNull);
      expect(DispatchLadder.fromStamped(const []), isNull);
      expect(DispatchLadder.fromStamped('nope'), isNull);
    });
  });

  group('parseLadderSteps', () {
    test('keeps valid rings, drops a non-positive radius', () {
      final s = parseLadderSteps([
        {'radius_km': 2, 'hold_sec': 5},
        {'radius_km': 0, 'hold_sec': 5}, // dropped
        {'radius_km': 8, 'hold_sec': 3},
      ]);
      expect(s.length, 2);
      expect(s.first.radiusKm, 2);
      expect(s.last.holdSec, 3);
    });
  });

  group('resolveDispatchLadderRule', () {
    const master = DispatchLadderRule(level: 'master', steps: [(radiusKm: 2.0, holdSec: 5)]);
    const teksi = DispatchLadderRule(level: 'master', service: 'teksi', steps: [(radiusKm: 1.0, holdSec: 3)]);
    const myCountry = DispatchLadderRule(level: 'country', country: 'Malaysia', steps: [(radiusKm: 4.0, holdSec: 9)]);

    test('a service-specific row beats the all-service master (case-insensitive)', () {
      final r = resolveDispatchLadderRule(const [master, teksi], service: 'TEKSI');
      expect(r?.service, 'teksi');
    });

    test('another service falls to the all-service master', () {
      final r = resolveDispatchLadderRule(const [master, teksi], service: 'ride');
      expect(r?.service, isNull);
      expect(r?.steps.first.radiusKm, 2);
    });

    test('a country row beats master inside that country', () {
      final r = resolveDispatchLadderRule(const [master, myCountry],
          service: 'ride', geo: const Geo(country: 'Malaysia'));
      expect(r?.level, 'country');
    });

    test('elsewhere the master still applies', () {
      final r = resolveDispatchLadderRule(const [master, myCountry],
          service: 'ride', geo: const Geo(country: 'Thailand'));
      expect(r?.level, 'master');
    });

    test('an inactive row is ignored', () {
      final r = resolveDispatchLadderRule(
          const [master, DispatchLadderRule(level: 'country', country: 'Malaysia', active: false, steps: [(radiusKm: 4.0, holdSec: 9)])],
          service: 'ride', geo: const Geo(country: 'Malaysia'));
      expect(r?.level, 'master');
    });

    test('no rules -> null (server uses the legacy config)', () {
      expect(resolveDispatchLadderRule(const [], service: 'ride'), isNull);
    });
  });
}
