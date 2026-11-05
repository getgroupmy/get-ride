import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/rider_id_gate.dart';

void main() {
  group('RiderIdGateRule', () {
    test('defaults and clamps', () {
      const s = RiderIdGateRule.standard;
      expect([s.require, s.idType, s.nthBooking, s.selfie, s.allowPhoto, s.autoVerifyScore],
          [false, 'either', 1, true, true, 85]);
      final r = RiderIdGateRule.fromJson({'require': true, 'idType': 'x', 'nthBooking': 999, 'autoVerifyScore': 10});
      expect([r.require, r.idType, r.nthBooking, r.autoVerifyScore], [true, 'either', 50, 60]);
      expect(RiderIdGateRule.fromJson(r.toJson()), r);
    });
  });

  group('RiderIdGateConfig.ruleFor', () {
    final cfg = RiderIdGateConfig.fromJson({
      'master': {'require': true, 'nthBooking': 3},
      'Malaysia': {'require': true, 'nthBooking': 1},
    });

    test('country rule wins, else master', () {
      expect(cfg.ruleFor('Malaysia')?.nthBooking, 1);
      expect(cfg.ruleFor('Singapore')?.nthBooking, 3); // master
      expect(cfg.ruleFor(null)?.nthBooking, 3); // master
    });

    test('no rules at all', () {
      expect(RiderIdGateConfig.empty.ruleFor('Malaysia'), isNull);
    });
  });

  group('riderIdGateBlocks', () {
    final cfg = RiderIdGateConfig.fromJson({
      'Malaysia': {'require': true, 'nthBooking': 1},
      'Thailand': {'require': true, 'nthBooking': 3},
      'Laos': {'require': false},
    });

    test('nth=1 blocks an unverified rider before their first booking', () {
      expect(riderIdGateBlocks(config: cfg, country: 'Malaysia', priorBookings: 0, verified: false), isTrue);
    });

    test('a verified rider is never blocked', () {
      expect(riderIdGateBlocks(config: cfg, country: 'Malaysia', priorBookings: 0, verified: true), isFalse);
    });

    test('nth=3 lets the first two through, blocks the third', () {
      expect(riderIdGateBlocks(config: cfg, country: 'Thailand', priorBookings: 1, verified: false), isFalse);
      expect(riderIdGateBlocks(config: cfg, country: 'Thailand', priorBookings: 2, verified: false), isTrue);
    });

    test('require=off never blocks', () {
      expect(riderIdGateBlocks(config: cfg, country: 'Laos', priorBookings: 99, verified: false), isFalse);
    });

    test('no rule for the country and no master never blocks', () {
      expect(riderIdGateBlocks(config: cfg, country: 'Nowhere', priorBookings: 99, verified: false), isFalse);
    });
  });
}
