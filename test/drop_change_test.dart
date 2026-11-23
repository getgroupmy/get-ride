import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/core/drop_change.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/fare_tariff.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/core/ride_services.dart' show baseCostPerKm;

void main() {
  group('DropChangeSettings', () {
    test('defaults', () {
      const s = DropChangeSettings.standard;
      expect(s.allow, isTrue);
      expect(s.autoApproveCheaper, isTrue);
      expect(s.autoApproveRm, 3);
      expect(s.autoApprovePct, 15);
      expect(s.responseWindowSec, 30);
      expect(s.maxChangesPerRide, 2);
      expect(s.responseWindow, const Duration(seconds: 30));
    });

    test('clamps and round-trips', () {
      final s = DropChangeSettings.fromJson({
        'allow': false,
        'autoApproveCheaper': false,
        'autoApproveRm': 999,
        'autoApprovePct': -5,
        'responseWindowSec': 5,
        'maxChangesPerRide': 50,
      });
      expect(s.allow, isFalse);
      expect(s.autoApproveCheaper, isFalse);
      expect(s.autoApproveRm, 50); // max
      expect(s.autoApprovePct, 0); // min
      expect(s.responseWindowSec, 10); // min
      expect(s.maxChangesPerRide, 10); // max
      expect(DropChangeSettings.fromJson(s.toJson()), s);
    });

    test('a non-map is the standard settings', () {
      expect(DropChangeSettings.fromJson(null), DropChangeSettings.standard);
      expect(DropChangeSettings.fromJson('x'), DropChangeSettings.standard);
    });
  });

  group('dropChangeKind', () {
    const rules = DropChangeSettings(autoApproveRm: 3, autoApprovePct: 15);

    test('cheaper applies instantly', () {
      expect(dropChangeKind(oldFare: 18, newFare: 15, rules: rules), DropChangeKind.instant);
      expect(dropChangeKind(oldFare: 18, newFare: 18, rules: rules), DropChangeKind.instant);
    });

    test('a small increase within RM applies instantly', () {
      // +RM2 ≤ max(RM3, 15% of 18 = 2.70) = RM3.
      expect(dropChangeKind(oldFare: 18, newFare: 20, rules: rules), DropChangeKind.instant);
    });

    test('a bigger increase needs the driver', () {
      // +RM6 > RM3 and > 15% (2.70).
      expect(dropChangeKind(oldFare: 18, newFare: 24, rules: rules), DropChangeKind.needsDriver);
    });

    test('percent threshold wins when it is larger', () {
      // Old RM100, 15% = RM15 > RM3; +RM10 is within.
      expect(dropChangeKind(oldFare: 100, newFare: 110, rules: rules), DropChangeKind.instant);
      expect(dropChangeKind(oldFare: 100, newFare: 120, rules: rules), DropChangeKind.needsDriver);
    });

    test('cheaper needs the driver when auto-approve-cheaper is off', () {
      const strict = DropChangeSettings(autoApproveCheaper: false);
      expect(dropChangeKind(oldFare: 18, newFare: 15, rules: strict), DropChangeKind.needsDriver);
    });
  });

  // Migration 0437: the server prices a change; the app shows its answer.
  group('DropChangeQuote', () {
    test("the server's answer: the fare and whether it applies at once", () {
      final q = DropChangeQuote.fromJson({'fare': 22, 'instant': true})!;
      expect(q.fare, 22);
      expect(q.instant, isTrue);
      expect(q.kind, DropChangeKind.instant);

      final held = DropChangeQuote.fromJson({'fare': 35.5, 'instant': false})!;
      expect(held.fare, 35.5);
      expect(held.kind, DropChangeKind.needsDriver);
    });

    test('a fare sent as text is read too', () {
      expect(DropChangeQuote.fromJson({'fare': '19.25', 'instant': false})!.fare, 19.25);
    });

    test('a ride with no fare yet has none in its quote', () {
      final q = DropChangeQuote.fromJson({'fare': null, 'instant': false})!;
      expect(q.fare, isNull);
      expect(q.kind, DropChangeKind.needsDriver);
    });

    test('anything else is no quote', () {
      expect(DropChangeQuote.fromJson(null), isNull);
      expect(DropChangeQuote.fromJson('22'), isNull);
      expect(DropChangeQuote.fromJson(const <String, dynamic>{}), isNull);
      expect(DropChangeQuote.fromJson({'fare': 22}), isNull);
      expect(DropChangeQuote.fromJson({'fare': 22, 'instant': 'yes'}), isNull);
      expect(DropChangeQuote.fromJson({'fare': -1, 'instant': true}), isNull);
      expect(DropChangeQuote.fromJson({'fare': 'x', 'instant': true}), isNull);
      expect(DropChangeQuote.fromJson({'fare': double.nan, 'instant': true}), isNull);
    });
  });

  group('parseDropChangeAnswer', () {
    test('applied at once, at the fare the server put on it', () {
      final a = parseDropChangeAnswer({'applied': true, 'pending': false, 'fare': 22});
      expect(a.applied, isTrue);
      expect(a.fare, 22);
    });

    test('held for the driver', () {
      final a = parseDropChangeAnswer({'applied': false, 'pending': true, 'fare': 35});
      expect(a.applied, isFalse);
      expect(a.fare, 35);
    });

    test('an answer that says nothing is not applied and has no fare', () {
      expect(parseDropChangeAnswer(null), (applied: false, fare: null));
      expect(parseDropChangeAnswer({'applied': 'true'}), (applied: false, fare: null));
      expect(parseDropChangeAnswer({'applied': true}), (applied: true, fare: null));
    });
  });

  // The server's ride_card_fare (0437) is the booking sheet's quote in the
  // database. supabase/tests/drop_change_0341.sql, section 19, prices the same
  // cards and services over the same trip there: the two lists are to agree.
  group("the fare card's price for 9.5 km in 24 minutes, as the server works it out too", () {
    const typeId = 'type', premiumId = 'premium';
    const cards = [
      FareTariff(level: 'country', country: 'Testland 0341', baseFare: 5.25, perKm: 0.5, perMinute: 0.5),
      FareTariff(level: 'country', country: 'Testland 0341', baseFare: 2, perKm: 1, serviceType: typeId),
      FareTariff(level: 'country', country: 'Testland 0341', baseFare: 8, perKm: 2, vehicleService: premiumId),
      FareTariff(
        level: 'city',
        country: 'Testland 0341',
        state: 'Teststate 0431',
        city: 'Testcity 0431',
        baseFare: 10,
        perKm: 1,
        minimumFare: 25,
        bookingFee: 1,
      ),
    ];
    const premium = {'name': 'Test Premium 0431', 'costPerKm': 3, 'costPerMin': 0.2, 'minFareAmount': 12};
    const bike = {'name': 'Test Bike 0431', 'costPerKm': 0.75};
    const van = {'name': 'Test Van 0431', 'costPerKm': 3};
    const teksi = {'name': 'Test Teksi 0431', 'costPerKm': 1.8};
    const testland = Geo(country: 'Testland 0341');
    const testcity = Geo(country: 'Testland 0341', state: 'Teststate 0431', city: 'Testcity 0431');
    const nowhere = Geo(country: 'Nowhere 0431');

    // As the booking sheet prices a service from the catalogue: its multiplier
    // is its Cost per km over the base, its own rates price it with no card.
    double fare(Geo geo, {Map<String, dynamic>? service, String? id, Set<String> types = const {}, double km = 9.5, double min = 24}) {
      final cost = service == null ? null : (service['costPerKm'] as num).toDouble();
      return quoteFare(
        resolveFareTariff(cards, geo, vehicleService: id, serviceTypes: types),
        km,
        min,
        multiplier: cost == null ? 1 : cost / baseCostPerKm,
        rates: service == null ? null : ServiceRates.fromValues(service),
      ).fare;
    }

    test("the country's card for every service", () {
      expect(fare(testland), 22.00);
      expect(fare(const Geo(country: 'testland 0341 ', state: 'Elsewhere', city: 'Anytown')), 22.00);
    });

    test("at the service's multiplier", () => expect(fare(testland, service: van, id: 'van'), 44.00));

    test("its type's card beats the one for every service", () {
      expect(fare(testland, service: bike, id: 'bike', types: {typeId}), 5.75);
    });

    test("the vehicle's own card beats its type's, with no multiplier on top", () {
      expect(fare(testland, service: premium, id: premiumId, types: {typeId}), 27.00);
    });

    test("the city's card decides inside the city, and only there", () {
      expect(fare(testcity), 26.00);
      expect(fare(testcity, service: premium, id: premiumId, types: {typeId}), 40.00);
      expect(fare(const Geo(country: 'Testland 0341', state: 'Another state', city: 'Testcity 0431')), 22.00);
    });

    test("with no card, the service's own rates", () {
      expect(fare(nowhere, service: premium, id: premiumId, types: {typeId}), 33.30);
      expect(fare(nowhere, service: premium, id: premiumId, types: {typeId}, km: 1, min: 1), 12.00);
    });

    test('with neither, the built-in tariff, a taxi at its multiplier', () {
      expect(fare(nowhere), 19.05);
      expect(fare(nowhere, service: teksi, id: 'teksi'), 22.86);
      expect(fare(nowhere, km: 0.8, min: 3), 4.00);
      expect(fare(nowhere, km: -5, min: -5), 4.00);
    });

    test('rounded as the region books fares', () {
      // The drop-off changes the server tests price: 9.05 is 10 where fares
      // are whole amounts.
      expect(quoteDropChangeFare(card: cards.first, distanceKm: 1.6, durationMin: 6), 9.05);
      expect(
        quoteDropChangeFare(card: cards.first, distanceKm: 1.6, durationMin: 6, pricing: const RegionPricing(wholeFare: true)),
        10,
      );
      expect(quoteDropChangeFare(card: cards.first, distanceKm: 21.5, durationMin: 38), 35.00);
    });
  });
}
