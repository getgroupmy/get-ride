// Region ride-display rules (0411): the AI-fare / distance-time switches
// resolve narrowest-first, exactly like the commission rate.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/core/ride_display_rules.dart';

RideDisplayRule rule(
  String level, {
  bool ai = false,
  bool dist = false,
  bool active = true,
  String? country,
  String? state,
  String? city,
  String? suburb,
  int priority = 0,
  String? id,
  DateTime? updatedAt,
}) =>
    RideDisplayRule(
      level: level,
      aiFareOff: ai,
      distanceTimeOff: dist,
      active: active,
      country: country,
      state: state,
      city: city,
      suburb: suburb,
      priority: priority,
      id: id,
      updatedAt: updatedAt,
    );

const kl = Geo(country: 'Malaysia', state: 'Selangor', city: 'Kajang', suburb: 'Sungai Chua');

void main() {
  group('resolveRideDisplay', () {
    test('no rules shows everything', () {
      final d = resolveRideDisplay(const [], geo: kl);
      expect(d.aiFareOff, isFalse);
      expect(d.distanceTimeOff, isFalse);
    });

    test('a master rule applies everywhere and carries both switches', () {
      final d = resolveRideDisplay([rule('master', ai: true, dist: true)], geo: kl);
      expect(d.aiFareOff, isTrue);
      expect(d.distanceTimeOff, isTrue);
      // And with no geo at all.
      expect(resolveRideDisplay([rule('master', ai: true)]).aiFareOff, isTrue);
    });

    test('the narrowest matching rule wins (city over state over country over master)', () {
      final rules = [
        rule('master', ai: true, dist: true),
        rule('country', country: 'Malaysia', ai: true, dist: true),
        rule('state', country: 'Malaysia', state: 'Selangor', ai: true, dist: true),
        rule('city', country: 'Malaysia', state: 'Selangor', city: 'Kajang', ai: true, dist: false),
      ];
      final d = resolveRideDisplay(rules, geo: kl);
      // The city rule wins: AI off, distance kept.
      expect(d.aiFareOff, isTrue);
      expect(d.distanceTimeOff, isFalse);
    });

    test('a rule for another place does not apply', () {
      final d = resolveRideDisplay(
        [rule('state', country: 'Malaysia', state: 'Penang', ai: true, dist: true)],
        geo: kl,
      );
      expect(d.aiFareOff, isFalse);
      expect(d.distanceTimeOff, isFalse);
    });

    test('inactive rules are ignored', () {
      final d = resolveRideDisplay([rule('master', ai: true, dist: true, active: false)], geo: kl);
      expect(d.aiFareOff, isFalse);
      expect(d.distanceTimeOff, isFalse);
    });

    test('between rules at the same level, higher priority wins', () {
      final rules = [
        rule('country', country: 'Malaysia', ai: false, dist: true, priority: 0, id: 'a'),
        rule('country', country: 'Malaysia', ai: true, dist: false, priority: 5, id: 'b'),
      ];
      final d = resolveRideDisplay(rules, geo: kl);
      expect(d.aiFareOff, isTrue);
      expect(d.distanceTimeOff, isFalse);
    });

    test('suburb beats city', () {
      final rules = [
        rule('city', country: 'Malaysia', state: 'Selangor', city: 'Kajang', ai: false, dist: true),
        rule('suburb',
            country: 'Malaysia', state: 'Selangor', city: 'Kajang', suburb: 'Sungai Chua', ai: true, dist: false),
      ];
      final d = resolveRideDisplay(rules, geo: kl);
      expect(d.aiFareOff, isTrue);
      expect(d.distanceTimeOff, isFalse);
    });
  });

  group('RideDisplayRule.fromRow', () {
    test('reads the switch columns and tolerates missing ones', () {
      final r = RideDisplayRule.fromRow({
        'level': 'country',
        'country': 'Malaysia',
        'ai_fare_off': true,
        'distance_time_off': false,
        'priority': 3,
        'id': 'x',
      });
      expect(r.level, 'country');
      expect(r.aiFareOff, isTrue);
      expect(r.distanceTimeOff, isFalse);
      expect(r.active, isTrue);
      expect(r.priority, 3);
    });
  });

  group('rideDisplayRequiredScope', () {
    test('each level needs its parents', () {
      expect(rideDisplayRequiredScope('master'), isEmpty);
      expect(rideDisplayRequiredScope('country'), ['country']);
      expect(rideDisplayRequiredScope('city'), ['country', 'state', 'city']);
      expect(rideDisplayRequiredScope('suburb'), ['country', 'state', 'city', 'suburb']);
    });
  });

  group('rideDisplayScopeLabel', () {
    test('master and a place', () {
      expect(rideDisplayScopeLabel({'level': 'master'}), 'Platform default');
      expect(
        rideDisplayScopeLabel({'level': 'city', 'country': 'Malaysia', 'state': 'Selangor', 'city': 'Kajang'}),
        'Kajang, Selangor, Malaysia',
      );
    });
  });
}
