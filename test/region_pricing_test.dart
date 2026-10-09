// Fare pricing per region (Admin → Country / States / Cities): whole fares
// rounded up and the tax on top, resolved like the bidding switch.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:get_ride/src/core/format.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/core/ride_bidding.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:latlong2/latlong.dart';

BiddingRegion _region(Map<String, dynamic> v) => BiddingRegion.fromValues(v)!;

void main() {
  group('a region\'s pricing', () {
    test('a country always sets it; below a country only when it overrides', () {
      expect(RegionPricing.fromValues({'country': 'Malaysia'}), RegionPricing.none);
      expect(RegionPricing.fromValues({'country': 'Malaysia', 'state': 'Selangor', 'wholeFare': true}), isNull);
      expect(
        RegionPricing.fromValues({
          'country': 'Malaysia',
          'state': 'Selangor',
          'pricingOverride': true,
          'wholeFare': true,
        }),
        const RegionPricing(wholeFare: true),
      );
    });

    test('a tax needs a name and an amount', () {
      final v = {'country': 'Malaysia', 'taxEnabled': true, 'taxName': 'SST', 'taxType': 'percent', 'taxAmount': 6};
      expect(RegionPricing.fromValues(v)!.tax!.label, 'SST 6%');
      expect(RegionPricing.fromValues({...v, 'taxName': ' '})!.tax, isNull);
      expect(RegionPricing.fromValues({...v, 'taxAmount': 0})!.tax, isNull);
      expect(RegionPricing.fromValues({...v, 'taxEnabled': false})!.tax, isNull);
    });

    test('whole fares round up and never down; otherwise to the cent', () {
      const whole = RegionPricing(wholeFare: true);
      expect(whole.roundFare(17.01), 18);
      expect(whole.roundFare(17.6), 18);
      expect(whole.roundFare(18), 18);
      expect(RegionPricing.none.roundFare(17.604), 17.6);
      expect(whole.fareDecimals, 0);
    });

    test('the tax: a percentage of the fare to the cent, or a fixed amount', () {
      const pct = RegionTax(name: 'SST', kind: TaxKind.percent, value: 6);
      const flat = RegionTax(name: 'Levy', kind: TaxKind.fixed, value: 1.5);
      expect(pct.on(18), 1.08);
      expect(flat.on(18), 1.5);
      expect(flat.label, 'Levy');
    });
  });

  group('which region decides', () {
    final regions = [
      _region({'country': 'Malaysia', 'taxEnabled': true, 'taxName': 'SST', 'taxType': 'percent', 'taxAmount': 6}),
      // Set up just for its geofence: the country's pricing still applies.
      _region({'country': 'Malaysia', 'state': 'Johor'}),
      _region({'country': 'Malaysia', 'state': 'Selangor', 'pricingOverride': true, 'wholeFare': true}),
    ];
    const kl = LatLng(3.15, 101.71);

    test('the most specific region that sets pricing, by name', () {
      expect(
        pricingAt(
          regions,
          kl,
          area: const AreaInfo(country: 'Malaysia', state: 'Selangor'),
        ),
        const RegionPricing(wholeFare: true),
      );
      expect(
        pricingAt(
          regions,
          kl,
          area: const AreaInfo(country: 'Malaysia', state: 'Johor'),
        ).tax!.name,
        'SST',
      );
      expect(pricingAt(regions, kl, area: const AreaInfo(country: 'Singapore')), RegionPricing.none);
    });

    test('a mapped boundary decides first', () {
      final mapped = [
        ...regions,
        _region({
          'country': 'Malaysia',
          'state': 'Kuala Lumpur',
          'pricingOverride': true,
          'wholeFare': true,
          'boundary': '{"bbox":{"north":3.3,"south":3.0,"east":101.8,"west":101.6}}',
        }),
      ];
      expect(
        pricingAt(
          mapped,
          kl,
          area: const AreaInfo(country: 'Malaysia', state: 'Johor'),
        ).wholeFare,
        isTrue,
      );
    });
  });

  test('the admin form writes pricing in full, or clears it', () {
    final country = RegionForm(country: 'Malaysia', wholeFare: true, taxEnabled: true, taxName: 'SST', taxAmount: '6');
    final v = country.toValues();
    expect([v['wholeFare'], v['taxName'], v['taxType'], v['taxAmount']], [true, 'SST', 'percent', 6.0]);
    expect(v.containsKey('pricingOverride'), isFalse);
    final inherit = RegionForm(country: 'Malaysia', state: 'Johor', wholeFare: true).toValues();
    expect(inherit['pricingOverride'], false);
    expect(inherit['wholeFare'], isNull, reason: 'left to the country');
    expect(
      regionPricingProblem(taxEnabled: true, taxName: '', taxKind: TaxKind.percent, taxAmount: '6'),
      'Enter the tax name, e.g. SST.',
    );
    expect(
      regionPricingProblem(taxEnabled: true, taxName: 'SST', taxKind: TaxKind.percent, taxAmount: '120'),
      'A percentage tax is at most 100%.',
    );
  });

  test('a booked ride shows its fare whole and adds its tax to the total', () {
    final r = RideRequest({
      'id': 'r',
      'status': 'completed',
      'fare': 18,
      'currency': 'MYR',
      'whole_fare': true,
      'tax_name': 'SST',
      'tax_kind': 'percent',
      'tax_value': 6,
      'toll_charges': 2.5,
    });
    expect(r.fareText(18), formatMoney(18, 'MYR', 0));
    expect(r.fareText(18), isNot(contains('.')));
    expect(r.taxAmount, 1.08);
    expect(r.totalDue, closeTo(18 + 1.08 + 2.5, 1e-9));
    // A ride booked before 0119 is priced as before.
    expect(RideRequest({'id': 'o', 'fare': 18.5, 'toll_charges': 1}).totalDue, 19.5);
  });
}
