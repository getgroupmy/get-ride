import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/region_rules.dart';

// Friday 9 October 2026.
DateTime at(int h, [int m = 0, int day = 9]) => DateTime(2026, 10, day, h, m);

void main() {
  group('schedule', () {
    test('always, all day, and a time window', () {
      expect(RuleSchedule.always.matches(at(3)), isTrue);
      const peak = RuleSchedule(allDay: false, start: 7 * 60, end: 9 * 60);
      expect(peak.matches(at(7)), isTrue);
      expect(peak.matches(at(8, 59)), isTrue);
      expect(peak.matches(at(9)), isFalse, reason: 'the end is not included');
      expect(peak.label, 'Every day · 07:00–09:00');
    });

    test('a window past midnight belongs to the day it started', () {
      // Fridays 22:00–06:00: Saturday 02:00 is Friday night's.
      const fridayNight = RuleSchedule(mode: ScheduleMode.days, days: {5}, allDay: false, start: 22 * 60, end: 6 * 60);
      expect(fridayNight.matches(at(23, 0, 8)), isFalse, reason: 'Thursday night');
      expect(fridayNight.matches(at(2, 0, 9)), isFalse, reason: 'Friday 02:00 is Thursday night');
      expect(fridayNight.matches(at(23, 0, 9)), isTrue, reason: 'Friday 23:00');
      expect(fridayNight.matches(at(2, 0, 10)), isTrue, reason: 'Saturday 02:00, still Friday night');
      expect(fridayNight.matches(at(7, 0, 10)), isFalse);
    });

    test('days of the week and date ranges', () {
      const weekdays = RuleSchedule(mode: ScheduleMode.days, days: {1, 2, 3, 4, 5});
      expect(weekdays.matches(at(12)), isTrue);
      expect(weekdays.matches(at(12, 0, 10)), isFalse, reason: 'Saturday');
      expect(weekdays.label, 'Mon–Fri · all day');

      final december = RuleSchedule(mode: ScheduleMode.dates, from: DateTime(2026, 12, 1), to: DateTime(2026, 12, 31));
      expect(december.matches(DateTime(2026, 12, 31, 23, 59)), isTrue);
      expect(december.matches(DateTime(2027, 1, 1)), isFalse);
      expect(december.matches(at(12)), isFalse);
    });

    test('round-trips through JSON', () {
      const s = RuleSchedule(mode: ScheduleMode.days, days: {6, 7}, allDay: false, start: 600, end: 1320);
      final back = RuleSchedule.fromJson(s.toJson());
      expect(back.days, {6, 7});
      expect([back.allDay, back.start, back.end], [false, 600, 1320]);
      expect(s.toJson()['start'], '10:00');
      // Equal start and end is no window: read as all day.
      expect(
        RuleSchedule.fromJson({'mode': 'always', 'allDay': false, 'start': '10:00', 'end': '10:00'}).allDay,
        isTrue,
      );
    });
  });

  group('target', () {
    test('a vehicle type beats its category, which beats every service', () {
      const t = RuleTarget(categories: {'car'}, vehicleTypes: {'premium'});
      expect(t.specificityFor(categories: {'car'}, vehicleType: 'premium'), 2);
      expect(t.specificityFor(categories: {'car', 'delivery'}, vehicleType: 'ride'), 1);
      expect(t.specificityFor(categories: {'bike'}, vehicleType: 'moto'), isNull);
      expect(RuleTarget.everything.specificityFor(categories: {'bike'}), 0);
    });
  });

  group('rules', () {
    test('stored and read back; bad entries skipped', () {
      final rules = [
        const RegionRule(
          id: 'a',
          kind: RuleKind.bidding,
          on: false,
          schedule: RuleSchedule(mode: ScheduleMode.days, days: {7}),
        ),
        const RegionRule(id: 'b', kind: RuleKind.tax, name: 'SST', amount: 8),
      ];
      final back = parseRegionRules(encodeRegionRules(rules));
      expect(back.map((r) => r.id), ['a', 'b']);
      expect(back.first.on, isFalse);
      expect(back.last.chargeLabel(), 'SST 8%');
      expect(
        parseRegionRules([
          {'id': 'x', 'kind': 'nonsense'},
          {'kind': 'tax'},
          'junk',
        ]),
        isEmpty,
      );
    });

    test('problems', () {
      expect(regionRuleProblem(const RegionRule(id: 'a', kind: RuleKind.tax, amount: 8)), contains('name'));
      expect(
        regionRuleProblem(const RegionRule(id: 'a', kind: RuleKind.tax, name: 'SST', amount: 120)),
        contains('100'),
      );
      expect(
        regionRuleProblem(
          const RegionRule(
            id: 'a',
            kind: RuleKind.availability,
            schedule: RuleSchedule(mode: ScheduleMode.days),
          ),
        ),
        contains('day'),
      );
      expect(
        regionRuleProblem(
          const RegionRule(id: 'a', kind: RuleKind.surcharge, name: 'Night', amount: 5, charge: ChargeKind.fixed),
        ),
        isNull,
      );
    });

    test('charges', () {
      const pct = RegionRule(id: 'a', kind: RuleKind.tax, name: 'SST', amount: 8);
      const fixed = RegionRule(id: 'b', kind: RuleKind.surcharge, name: 'Night', amount: 5, charge: ChargeKind.fixed);
      expect(pct.chargeOn(50), 4);
      expect(fixed.chargeOn(50), 5);
      expect(fixed.chargeLabel('RM'), 'Night RM5.00');
    });
  });

  group('resolving', () {
    const car = 'car', ride = 'ride', premium = 'premium';
    const night = RuleSchedule(allDay: false, start: 0, end: 6 * 60);

    test('the most specific region with a live rule decides; outside its hours the switches do', () {
      final chain = <RegionRules>[
        (specificity: 0, rules: const [RegionRule(id: 'c', kind: RuleKind.bidding, on: false)]),
        (specificity: 2, rules: const [RegionRule(id: 'k', kind: RuleKind.bidding, on: true, schedule: night)]),
      ];
      expect(
        resolveRules(chain, categories: {car}, vehicleType: ride, local: at(2)).bidding,
        isTrue,
        reason: 'city, at night',
      );
      expect(
        resolveRules(chain, categories: {car}, vehicleType: ride, local: at(12)).bidding,
        isFalse,
        reason: 'country by day',
      );
      expect(resolveRules(const [], local: at(12)).bidding, isNull);
    });

    test('within a region the vehicle type beats the category', () {
      final chain = <RegionRules>[
        (
          specificity: 0,
          rules: const [
            RegionRule(
              id: 'v',
              kind: RuleKind.availability,
              on: false,
              target: RuleTarget(vehicleTypes: {premium}),
            ),
            RegionRule(
              id: 'c',
              kind: RuleKind.availability,
              on: true,
              target: RuleTarget(categories: {car}),
            ),
          ],
        ),
      ];
      expect(resolveRules(chain, categories: {car}, vehicleType: premium, local: at(12)).available, isFalse);
      expect(resolveRules(chain, categories: {car}, vehicleType: ride, local: at(12)).available, isTrue);
      expect(resolveRules(chain, categories: {'bike'}, vehicleType: 'moto', local: at(12)).available, isNull);
    });

    test('taxes and surcharges: the deciding region\'s list, live ones only', () {
      final chain = <RegionRules>[
        (specificity: 0, rules: const [RegionRule(id: 't0', kind: RuleKind.tax, name: 'SST', amount: 8)]),
        (
          specificity: 2,
          rules: const [
            RegionRule(
              id: 't1',
              kind: RuleKind.tax,
              name: 'City tax',
              amount: 2,
              target: RuleTarget(vehicleTypes: {premium}),
            ),
            RegionRule(
              id: 's1',
              kind: RuleKind.surcharge,
              name: 'Night',
              amount: 5,
              charge: ChargeKind.fixed,
              schedule: night,
            ),
          ],
        ),
      ];
      final premiumNow = resolveRules(chain, categories: {car}, vehicleType: premium, local: at(2));
      expect(premiumNow.taxes!.map((r) => r.id), ['t1'], reason: 'the city\'s taxes replace the country\'s');
      expect(premiumNow.surcharges.map((r) => r.id), ['s1']);

      final rideNoon = resolveRules(chain, categories: {car}, vehicleType: ride, local: at(12));
      expect(rideNoon.taxes!.map((r) => r.id), ['t0'], reason: 'the city has no tax for Ride');
      expect(rideNoon.surcharges, isEmpty, reason: 'only at night');
    });

    test('a parked rule does nothing', () {
      final chain = <RegionRules>[
        (specificity: 0, rules: const [RegionRule(id: 'a', kind: RuleKind.bidding, on: false, enabled: false)]),
      ];
      expect(resolveRules(chain, local: at(12)).bidding, isNull);
    });
  });
}
