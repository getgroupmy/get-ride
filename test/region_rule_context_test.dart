import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/core/region_rules.dart';
import 'package:get_ride/src/core/ride_bidding.dart';

// Friday 9 October 2026, 23:00 in Kuala Lumpur (UTC+8) is 15:00 UTC.
final fridayNightKl = DateTime.utc(2026, 10, 9, 15);
final fridayNoonKl = DateTime.utc(2026, 10, 9, 4);

const night = RuleSchedule(allDay: false, start: 22 * 60, end: 6 * 60);

void main() {
  const country = BiddingRegion(
    country: 'Malaysia',
    timezone: 'Asia/Kuala_Lumpur',
    services: {'car', 'bike'},
    rules: [
      RegionRule(id: 'sst', kind: RuleKind.tax, name: 'SST', amount: 6),
      RegionRule(
        id: 'late',
        kind: RuleKind.surcharge,
        name: 'Night',
        charge: ChargeKind.fixed,
        amount: 2,
        schedule: night,
      ),
    ],
  );
  const city = BiddingRegion(
    country: 'Malaysia',
    state: 'Selangor',
    city: 'Shah Alam',
    rules: [
      // No bikes at night in the city, and bidding off for Premium.
      RegionRule(
        id: 'no-bikes',
        kind: RuleKind.availability,
        on: false,
        target: RuleTarget(categories: {'bike'}),
        schedule: night,
      ),
      RegionRule(
        id: 'fixed-premium',
        kind: RuleKind.bidding,
        on: false,
        target: RuleTarget(vehicleTypes: {'premium'}),
      ),
    ],
  );
  final ctx = RegionRuleContext(const [city, country]);

  test('times are the region\'s own', () {
    expect(ctx.timezone, 'Asia/Kuala_Lumpur');
    expect(ctx.localTime(fridayNightKl), DateTime(2026, 10, 9, 23));
  });

  test('availability: a scheduled rule, else the region\'s Services switches', () {
    expect(ctx.available(types: {'bike'}, vehicleType: 'moto', nowUtc: fridayNoonKl), isTrue);
    expect(ctx.available(types: {'bike'}, vehicleType: 'moto', nowUtc: fridayNightKl), isFalse);
    expect(ctx.available(types: {'car'}, vehicleType: 'ride', nowUtc: fridayNightKl), isTrue);
    expect(
      ctx.available(types: {'delivery'}, nowUtc: fridayNoonKl),
      isFalse,
      reason: 'switched off in Services',
    );
    expect(ctx.available(nowUtc: fridayNoonKl), isTrue, reason: 'a service with no type is not restricted');
  });

  test('bidding: a rule for the vehicle type, else the region switch', () {
    expect(ctx.bidding(types: {'car'}, vehicleType: 'premium', nowUtc: fridayNoonKl, fallback: true), isFalse);
    expect(ctx.bidding(types: {'car'}, vehicleType: 'ride', nowUtc: fridayNoonKl, fallback: true), isTrue);
    expect(ctx.bidding(types: {'car'}, vehicleType: 'ride', nowUtc: fridayNoonKl, fallback: false), isFalse);
  });

  test('pricing: the taxes and surcharges in force, tax on fare and surcharge', () {
    const base = RegionPricing(wholeFare: true);
    final noon = ctx.pricingFor(base, types: {'car'}, vehicleType: 'ride', nowUtc: fridayNoonKl);
    expect(noon.linesFor(10).map((l) => (l.amount, l.isTax)), [(0.6, true)]);
    final late = ctx.pricingFor(base, types: {'car'}, vehicleType: 'ride', nowUtc: fridayNightKl);
    final lines = late.linesFor(10);
    expect(lines.map((l) => (l.amount, l.isTax)), [(2.0, false), (0.72, true)]);
    expect(late.surchargesOn(10), 2);
    expect(late.taxOn(10), 0.72);
    expect(late.extrasOn(10), 2.72);
    expect(late.wholeFare, isTrue, reason: 'rules keep the region\'s rounding');
  });

  test('rule taxes replace the plain Tax; the stamp round-trips through the ride row', () {
    const base = RegionPricing(
      tax: RegionTax(name: 'GST', kind: TaxKind.percent, value: 10),
    );
    final p = ctx.pricingFor(base, nowUtc: fridayNightKl);
    expect(p.tax, isNull);
    final row = p.toRideColumns();
    expect(row['charges'], isA<List>());
    final back = RegionPricing.fromRide(row);
    expect(back, p);
    expect(back.linesFor(10).length, 2);
    expect(RegionPricing.none.toRideColumns()['charges'], isNull);
  });

  test('without rules nothing changes', () {
    const base = RegionPricing(
      tax: RegionTax(name: 'GST', kind: TaxKind.percent, value: 10),
    );
    expect(RegionRuleContext.empty.pricingFor(base, nowUtc: fridayNoonKl), base);
    expect(RegionRuleContext.empty.available(types: {'x'}, nowUtc: fridayNoonKl), isTrue);
    expect(RegionRuleContext.empty.bidding(nowUtc: fridayNoonKl, fallback: true), isTrue);
  });
}
