// The advance-booking surcharge resolver (migration 0414): per service type and
// region, narrowest-first with a service-specific row beating an all-service
// one, falling back to the global scheduled-rides fee. Mirrors the server's
// scheduling_surcharge_fee.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/core/scheduled_rides.dart' show ScheduledRidesConfig, schedulingFee;
import 'package:get_ride/src/core/scheduling_surcharge.dart';

void main() {
  const my = Geo(country: 'Malaysia', state: 'Selangor', city: 'Shah Alam');
  // A global fee of RM2 + 5% of the fare.
  const config = ScheduledRidesConfig(enabled: true, feeFixed: 2, feePercent: 5);

  double fee(List<SchedulingSurchargeRule> rules, {String? service, Geo geo = my, double fare = 100}) =>
      resolveSchedulingSurcharge(rules, config, fare: fare, service: service, geo: geo);

  test('no rules: the global scheduled-rides fee', () {
    expect(fee(const []), schedulingFee(100, config)); // 2 + 5 = 7
    expect(fee(const []), 7);
  });

  test('a master all-service row overrides the global fee everywhere', () {
    final rules = [const SchedulingSurchargeRule(level: 'master', feeFixed: 5)];
    expect(fee(rules, service: 'ride'), 5);
    expect(fee(rules, service: 'teksi', geo: const Geo(country: 'Thailand')), 5);
  });

  test('fixed + percentage together', () {
    final rules = [const SchedulingSurchargeRule(level: 'master', feeFixed: 3, feePercent: 5)];
    expect(fee(rules, fare: 100), 8); // 3 + 5% of 100
  });

  test('a service-specific row beats an all-service row at the same level', () {
    final rules = [
      const SchedulingSurchargeRule(level: 'master', feeFixed: 5), // all services
      const SchedulingSurchargeRule(level: 'master', service: 'teksi', feePercent: 10),
    ];
    expect(fee(rules, service: 'teksi', fare: 100), 10, reason: 'the teksi row wins');
    expect(fee(rules, service: 'ride', fare: 100), 5, reason: 'ride stays on the all-service row');
    expect(fee(rules, service: 'TEKSI', fare: 100), 10, reason: 'service match is case-insensitive');
  });

  test('a narrower region beats a wider one', () {
    final rules = [
      const SchedulingSurchargeRule(level: 'master', feeFixed: 5),
      const SchedulingSurchargeRule(level: 'country', country: 'Malaysia', feeFixed: 12),
    ];
    expect(fee(rules, service: 'ride'), 12, reason: 'country beats master in Malaysia');
    expect(fee(rules, service: 'ride', geo: const Geo(country: 'Thailand')), 5,
        reason: 'the country row does not apply in Thailand');
  });

  test('inactive rows are ignored', () {
    final rules = [
      const SchedulingSurchargeRule(level: 'master', feeFixed: 5),
      const SchedulingSurchargeRule(level: 'country', country: 'Malaysia', feeFixed: 12, active: false),
    ];
    expect(fee(rules, service: 'ride'), 5, reason: 'the inactive country row is skipped');
  });

  test('no matching row (service and region miss): global fallback', () {
    // A suburb row for a different suburb cannot match; nothing else is set.
    final rules = [
      const SchedulingSurchargeRule(
          level: 'suburb', country: 'Malaysia', state: 'Selangor', city: 'Kajang', suburb: 'Sungai Chua', feeFixed: 9),
    ];
    expect(fee(rules, service: 'ride'), schedulingFee(100, config));
  });

  test('feeOn rounds to the cent', () {
    const rule = SchedulingSurchargeRule(level: 'master', feePercent: 7.5);
    expect(rule.feeOn(33), closeTo(2.48, 0.001)); // 7.5% of 33 = 2.475 -> 2.48
  });
}
