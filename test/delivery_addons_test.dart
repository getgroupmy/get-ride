// Freight and Courier add-ons (migration 0312): the rules (Default and a
// region rule that keeps only what it sets), the amounts as the server
// checks them, the booking lines and refusals, the Courier page with cover
// and cash on delivery, the driver's COD and return leg, the admin's rules
// page and the cover claims -- light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/catalogue/catalogue_logic.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show RegionEntry;
import 'package:get_ride/src/admin/screens/meterapp/delivery_addons_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/courier.dart';
import 'package:get_ride/src/core/delivery_addons.dart';
import 'package:get_ride/src/core/freight.dart';
import 'package:get_ride/src/core/partner_type_rules.dart' show RegionScope;
import 'package:get_ride/src/core/payment_types.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/core/ride_option_charges.dart';
import 'package:get_ride/src/core/ride_option_places.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/delivery_addons_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/freight_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_option_places_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/delivery_addons_driver.dart';
import 'package:get_ride/src/features/ride/courier_screen.dart';
import 'package:get_ride/src/features/ride/delivery_addons_parts.dart';
import 'package:get_ride/src/features/ride/freight_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notice.dart';
import 'text_contrast.dart';

String _rm(double v) => 'RM${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2)}';

const _my = RegionScope(country: 'Malaysia');
const _sabah = RegionScope(country: 'Malaysia', state: 'Sabah');

/// Default with everything on; Sabah lowers the stairs and COD, and switches the cold truck off.
AddonRules _rules() => const AddonRules([
  AddonRule(values: {
    'cover': {'on': true},
    'roundTrip': {'on': true},
    'stairs': {'on': true},
    'cold': {'on': true},
    'cod': {'on': true},
  }),
  AddonRule(scope: _sabah, values: {
    'stairs': {'perFloor': 10},
    'cold': {'on': false},
    'cod': {'max': 500, 'carry': 500},
  }),
]);

class _Repo implements DeliveryAddonsRepository {
  final calls = <Invocation>[];
  Invocation? call(Symbol name) => calls.where((c) => c.memberName == name).lastOrNull;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation);
    switch (invocation.memberName) {
      case #codCollected:
        return Future.value(<String, dynamic>{'amount': 250, 'fee': 5, 'paid': 245});
      case #codRefused:
        return Future.value(<String, dynamic>{'return_fare': 8});
      case #returnStart:
        return Future.value(<String, dynamic>{'wait_fee': 2.5});
      case #fileClaim:
        return Future.value(const CoverClaim(
          id: 'cl1', rideId: 'k1', amount: 300, declaredValue: 800, reason: 'Cracked', status: 'open'));
      case #save:
      case #remove:
      case #returnArrived:
      case #decideClaim:
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class _Rides implements RideRepository {
  final calls = <Invocation>[];
  Invocation? call(Symbol name) => calls.where((c) => c.memberName == name).lastOrNull;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation);
    if (invocation.memberName == #createRequest) {
      return Future<Booked>.value((now: RideRequest({'id': 'new', 'status': 'open'}), later: null));
    }
    return super.noSuchMethod(invocation);
  }
}

Future<void> _pump(WidgetTester tester, Widget home, List<Override> overrides, Brightness b,
    {Size size = const Size(420, 1800)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    retry: (_, _) => null,
    overrides: overrides,
    child: MaterialApp(theme: appTheme(b), home: home),
  ));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await closeAnyNotice(tester);
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

void main() {
  group('the rules', () {
    test('Default is the built-in values, every add-on off', () {
      final a = AddonRules.none.here(_my);
      for (final x in DeliveryAddon.values) {
        expect(a.on(x), isFalse, reason: x.key);
      }
      expect(a.coverPct, 1);
      expect(a.coverMin, 2);
      expect(a.coverMax, 5000);
      expect(a.returnPct, 80);
      expect(a.freeWait, 15);
      expect(a.perFloor, 15);
      expect(a.helperFrom, 3);
      expect(a.coldLevels.map((l) => l.id), ['chilled', 'frozen']);
      expect(a.codCarry, 1000);
      expect(a.claimDays, 7);
      expect(a.excluded, isNotEmpty);
    });

    test('a region rule keeps only what it sets; the most specific place wins', () {
      final rules = _rules();
      final my = rules.here(_my), sabah = rules.here(_sabah);
      final ranau = rules.here(const RegionScope(country: 'Malaysia', state: 'Sabah', city: 'Ranau'));
      expect(my.perFloor, 15);
      expect(sabah.perFloor, 10);
      expect(sabah.maxFloors, 10, reason: 'not set in Sabah: Default\'s');
      expect(sabah.on(DeliveryAddon.stairs), isTrue);
      expect(sabah.on(DeliveryAddon.cold), isFalse);
      expect(sabah.codMax, 500);
      expect(sabah.codPct, 2);
      expect(ranau.perFloor, 10, reason: 'a city follows its state');
      expect(rules.fromWhere(_sabah, DeliveryAddon.stairs, 'perFloor'), _sabah);
      expect(rules.fromWhere(_sabah, DeliveryAddon.stairs, 'maxFloors'), isNull);
      expect(rules.fromWhere(_sabah, DeliveryAddon.stairs, 'on')!.isAll, isTrue);
      expect(sabah.offered(freight: true), [DeliveryAddon.cover, DeliveryAddon.roundTrip, DeliveryAddon.stairs]);
      expect(sabah.offered(freight: false), [DeliveryAddon.cover, DeliveryAddon.roundTrip, DeliveryAddon.cod]);
    });

    test('a rule sets and clears fields; its row is as the table keeps it', () {
      var r = const AddonRule(scope: _sabah);
      r = r.withField(DeliveryAddon.cod, 'max', 300).withField(DeliveryAddon.cod, 'pct', 3);
      expect(r.values, {'cod': {'max': 300, 'pct': 3}});
      expect(r.withField(DeliveryAddon.cod, 'max', null).values, {'cod': {'pct': 3}});
      expect(r.cleared(DeliveryAddon.cod).values, isEmpty);
      expect(r.toRow(), {
        'level': 'state', 'country': 'Malaysia', 'state': 'Sabah', 'city': null, 'suburb': null,
        'values': {'cod': {'max': 300, 'pct': 3}},
      });
      final back = AddonRule.fromRow({'id': 'x', 'level': 'state', 'country': 'Malaysia', 'state': 'Sabah', 'values': r.values});
      expect(back.scope, _sabah);
      expect(back.sets(DeliveryAddon.cod, 'pct'), isTrue);
    });

    test('the admin steppers keep within bounds; a level gets a free id', () {
      final pct = addonFields[DeliveryAddon.cover]!.first;
      expect(pct.stepped(1, up: true), 1.5);
      expect(pct.stepped(0, up: false), isNull);
      final wait = addonFields[DeliveryAddon.roundTrip]![2];
      expect(wait.stepped(0.5, up: true), 0.6);
      expect(wait.format(0.5, _rm), 'RM0.50');
      expect(addonFields[DeliveryAddon.cover]![3].format(1, _rm), '1 day');
      expect(coldLevelId('Chilled 0 to 8 °C', const []), 'chilled-0-to-8-c');
      expect(coldLevelId('Frozen', const ['frozen']), 'frozen-2');
      expect(withExcludedItem(const ['Cash'], ' cash '), ['Cash']);
      expect(withExcludedItem(const ['Cash'], 'Art'), ['Cash', 'Art']);
    });
  });

  group('the amounts, as the server checks them', () {
    final a = _rules().here(_my);
    test('premium, return leg, wait, stairs, COD fee', () {
      expect(coverPremium(800, a), 8);
      expect(coverPremium(50, a), 2, reason: 'the minimum');
      expect(returnLegCharge(180, a), 144);
      expect(returnWaitFee(20, a), 2.5);
      expect(returnWaitFee(10, a), 0);
      expect(returnWaitFee(500, a), 52.5, reason: 'at most the longest wait');
      expect(stairsCharge(2, 1, a), 45);
      expect(codFee(250, a), 5);
      expect(codFee(20, a), 1);
      expect(codFee(0.5, a), 0.5, reason: 'never more than the amount');
      expect(codPayout(250, a), 245);
    });

    test('the lines a booking adds, under the server\'s kinds', () {
      const p = AddonPicks(cover: true, roundTrip: true, stairsPickup: 2, coldLevel: 'chilled', cod: 250);
      final lines = addonLines(p, a, offer: 100, declared: 800);
      expect([for (final l in lines) l.kind], ['parcel-cover', 'round-trip', 'stairs', 'cold-truck']);
      expect([for (final l in lines) l.amount], [8, 80, 30, 60]);
      expect(lines[2].name, 'Stairs, 2 floors');
      expect(lines.every((l) => l.name.length <= 60), isTrue);
      expect(p.toColumns(), {
        'parcel_cover': true, 'round_trip': true, 'stairs_pickup': 2, 'cold_level': 'chilled', 'cod_amount': 250,
      });
      expect(AddonPicks.fromJson(p.toJson()).toColumns(), p.toColumns());
    });

    test('what is not offered is dropped; refusals in the server\'s words', () {
      final sabah = _rules().here(_sabah);
      const p = AddonPicks(stairsPickup: 3, coldLevel: 'chilled', cod: 100);
      expect(p.offeredBy(sabah, freight: true).coldLevel, isNull, reason: 'off in Sabah');
      expect(p.offeredBy(sabah, freight: true).cod, isNull, reason: 'Courier only');
      expect(addonPicksProblem(const AddonPicks(stairsPickup: 3), a, freight: true), 'From 3 floors without a lift, add a helper.');
      expect(addonPicksProblem(const AddonPicks(stairsPickup: 3), a, freight: true, hasHelper: true), isNull);
      expect(addonPicksProblem(const AddonPicks(stairsDrop: 11), a, freight: true, hasHelper: true),
          'At most 10 floors without a lift at each end here.');
      expect(addonPicksProblem(const AddonPicks(coldLevel: 'chilled'), a, freight: true),
          'Choose a refrigerated vehicle for the cold truck.');
      expect(addonPicksProblem(const AddonPicks(coldLevel: 'chilled'), a, freight: true, refrigerated: true), isNull);
      expect(addonPicksProblem(const AddonPicks(cover: true), a, freight: false, declared: 6000, money: _rm),
          'Parcel cover goes up to RM5000 here.');
      expect(addonPicksProblem(const AddonPicks(cod: 600), sabah, freight: false, money: _rm),
          'Cash on delivery goes up to RM500 a parcel here.');
      expect(addonPicksProblem(const AddonPicks(cod: 50), a, freight: true), 'Cash on delivery for the item is for Courier only.');
    });

    test('the breakdown: the trip, the lines, the wait, the COD, what the sender pays', () {
      const p = AddonPicks(cover: true, roundTrip: true, cod: 250);
      final lines = addonLines(p, a, offer: 12, declared: 800);
      final b = addonBreakdown(tripLabel: 'Motorcycle, 9 km', offer: 12, lines: lines, picks: p, a: a, money: _rm);
      expect([for (final l in b.lines) l.label], [
        'Motorcycle, 9 km', 'Parcel cover', 'Return leg (20% off)', 'Wait at drop-off, first 15 min free',
        'COD: recipient pays RM250',
      ]);
      expect(b.lines.last.value, 'to you, less RM5');
      expect(b.total, 12 + 8 + 9.6);
      for (final l in b.lines) {
        expect(l.label.contains('→') || l.value.contains('→'), isFalse);
      }
    });

    test('a booked ride: its legs, the COD, the claim days', () {
      final r = RideAddons.fromRow({
        'round_trip': true, 'cod_amount': 250, 'cod_fee': 5, 'cod_status': 'pending',
        'return_arrived_at': '2026-10-28T10:00:00Z',
        'addon_terms': {'roundTrip': {'freeWait': 10}},
      });
      expect(r.step, ReturnLegStep.waiting);
      expect(r.codPending, isTrue);
      expect(r.rule.freeWait, 10);
      expect(r.rule.returnPct, 80, reason: 'the rest built in');
      expect(addonsCompleteProblem(r), startsWith('Collect the cash'));
      final back = RideAddons.fromRow({'cod_amount': 50, 'cod_status': 'refused', 'return_started_at': '2026-10-28T10:00:00Z'});
      expect(back.step, ReturnLegStep.returning);
      expect(addonsCompleteProblem(back), isNull);
      final ended = DateTime(2026, 10, 20);
      expect(claimOpen(covered: true, ended: ended, claimDays: 7, now: DateTime(2026, 10, 27)), isTrue);
      expect(claimOpen(covered: true, ended: ended, claimDays: 7, now: DateTime(2026, 10, 28)), isFalse);
      expect(claimProblem(900, 'Cracked screen', 800, _rm), 'Claim up to the declared value, RM800.');
      expect(claimProblem(300, 'Cracked screen', 800, _rm), isNull);
    });

    test('Vehicle Services keep the refrigerated flag', () {
      final r = buildVehicleServiceValues(
        text: const {'name': 'Cold lorry'},
        numbers: const {'costPerKm': '2', 'costPerMin': '0.5', 'minFareAmount': '20', 'displayPriority': '1'},
        serviceTypes: const ['Freight'],
        fuel: const [],
        status: true,
        refrigerated: true,
      );
      expect(r.error, isNull);
      expect(r.values[refrigeratedKey], isTrue);
      expect(vehicleServiceMeta(r.values), contains('Refrigerated'));
      final v = freightVehiclesFrom([(id: 'v1', values: r.values)]);
      expect(v.single.refrigerated, isTrue);
    });
  });

  for (final b in Brightness.values) {
    group('screens (${b.name})', () {
      testWidgets('the add-ons section: cover with its value, COD with its amount, the breakdown', (tester) async {
        var picks = const AddonPicks();
        double? declared;
        final a = _rules().here(_my);
        await _pump(
          tester,
          Scaffold(
            body: StatefulBuilder(builder: (context, set) {
              final lines = addonLines(picks, a, offer: 12, declared: declared);
              final bd = addonBreakdown(tripLabel: 'Motorcycle, 9 km', offer: 12, lines: lines, picks: picks, a: a, money: _rm);
              return ListView(padding: const EdgeInsets.all(16), children: [
                DeliveryAddonsSection(
                  freight: false,
                  addons: a,
                  picks: picks,
                  money: _rm,
                  declared: declared,
                  onDeclared: (v) => set(() => declared = v),
                  onChanged: (p) => set(() {
                    if (p.cover && declared == null) declared = 800;
                    picks = p;
                  }),
                ),
                if (picks.any) DeliveryBreakdown(lines: bd.lines, total: bd.total, money: _rm),
              ]);
            }),
          ),
          const [],
          b,
        );
        expect(find.byKey(const ValueKey('addon-stairs-pickup-up')), findsNothing, reason: 'Freight only');
        expect(find.text('1% of the declared value, min RM2, up to RM5000'), findsOneWidget);
        await _tap(tester, 'addon-cover');
        expect(find.byKey(const ValueKey('addon-cover-excluded')), findsOneWidget);
        await _tap(tester, 'addon-cover-value-up');
        expect(declared, 900);
        await _tap(tester, 'addon-cod');
        expect(picks.cod, 100);
        await _tap(tester, 'addon-cod-amount-up');
        expect(picks.cod, 110);
        await _tap(tester, 'addon-round-trip');
        expect(find.text('COD: recipient pays RM110'), findsOneWidget);
        expect(find.text('Return leg (20% off)'), findsOneWidget);
        expect(tester.widget<Text>(find.byKey(const ValueKey('delivery-breakdown-total'))).data, 'RM30.60');
        expect(unreadableTexts(tester, find.byType(ListView)), isEmpty);
      });

      testWidgets('the Courier page books a covered parcel over the place cap, with COD', (tester) async {
        SharedPreferences.setMockInitialValues({});
        final rides = _Rides();
        const moto = FreightVehicle(id: 'c3', name: 'Courier Motorcycle', maxLoadKg: 10, serviceTypes: [courierServiceType]);
        await _pump(tester, const CourierScreen(), [
          rideRepositoryProvider.overrideWithValue(rides),
          deliveryAddonRulesProvider.overrideWith((ref) async => _rules()),
          courierVehiclesProvider.overrideWith((ref) async => const [moto]),
          freightVehiclesProvider.overrideWith((ref) async => const []),
          courierConfigProvider.overrideWith((ref) async => const CourierConfig()),
          freightConfigProvider.overrideWith((ref) async => const FreightConfig()),
          displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
          rideOptionPlacesProvider.overrideWith((ref) async => OptionPlaces.none),
          fareTariffsProvider.overrideWith((ref) async => const []),
          serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
          paymentChoicesProvider.overrideWith((ref) async => const [PaymentChoice('Cash', 'Cash', PaymentKind.cash)]),
          myCourierRequestsProvider.overrideWith((ref) => Stream.value(const [])),
          myFreightRequestsProvider.overrideWith((ref) => Stream.value(const [])),
          deviceBlockedProvider.overrideWith((ref) async => false),
          profileProvider.overrideWith((ref) async => null),
          freightPlaceSearchProvider.overrideWithValue((context, {required title, near, onMap = false}) async =>
              title == 'Where to pick up'
                  ? const Place(name: 'Eco Majestic', address: 'Semenyih', point: LatLng(2.93, 101.84))
                  : const Place(name: 'Pavilion', address: 'Bukit Bintang', point: LatLng(3.149, 101.713))),
          freightPickupContextProvider.overrideWithValue(
            (p) async => (area: const AreaInfo(country: 'Malaysia'), place: _my, pricing: RegionPricing.none, timezone: null),
          ),
          freightRouteProvider.overrideWithValue((x, y) async => (km: 9.0, min: 20.0)),
        ], b);
        await _tap(tester, 'courier-pickup');
        await _tap(tester, 'courier-drop');
        await _tap(tester, 'courier-recipient');
        await tester.enterText(find.byKey(const ValueKey('freight-recipient-phone')), '+60 12 345 6789');
        await tester.tap(find.byKey(const ValueKey('freight-recipient-done')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('delivery-addons')), findsOneWidget);
        await _tap(tester, 'addon-cover');
        for (var i = 0; i < 7; i++) {
          await _tap(tester, 'addon-cover-value-up');
        }
        expect(find.text('RM800'), findsWidgets, reason: 'over the place cap of RM500, within the cover');
        await _tap(tester, 'addon-cod');
        await _tap(tester, 'courier-prohibited-ack');
        await _tap(tester, 'courier-offer');
        await tester.enterText(find.byKey(const ValueKey('freight-offer-field')), '16');
        await tester.tap(find.byKey(const ValueKey('freight-offer-done')));
        await tester.pumpAndSettle();
        await closeAnyNotice(tester);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('delivery-breakdown')),
          200,
          scrollable: find.descendant(of: find.byKey(const ValueKey('courier-form')), matching: find.byType(Scrollable)).first,
        );
        expect(find.byKey(const ValueKey('delivery-breakdown')), findsOneWidget);
        expect(unreadableTexts(tester, find.byKey(const ValueKey('courier-form'))), isEmpty);
        await _tap(tester, 'courier-create');
        final args = rides.call(#createRequest)!.namedArguments;
        expect(args[#declaredValue], 800);
        expect((args[#addons] as AddonPicks).toColumns(), {'parcel_cover': true, 'cod_amount': 100.0});
        final lines = args[#optionCharges] as List<OptionChargeLine>;
        expect([for (final l in lines) (l.kind, l.amount)], [('parcel-cover', 8.0)]);
        expect(args[#fare], 24);
      });

      testWidgets('the driver: collect the COD, or bring it back', (tester) async {
        final repo = _Repo();
        RideRequest ride(String codStatus) => RideRequest({
          'id': 'k1', 'status': 'on_trip', 'currency': 'MYR', 'fare': 12, 'service': 'Courier Motorcycle',
          'cargo_description': 'Shoes', 'parcel_size': 'S', 'declared_value': 800, 'parcel_cover': true,
          'cod_amount': 250, 'cod_fee': 5, 'cod_status': codStatus,
          'pickup_proof_path': 'd/proof.jpg', 'addon_terms': {'cod': {'carry': 1000}},
        });
        await _pump(
          tester,
          Scaffold(body: ListView(children: [DeliveryAddonsDriverPanel(request: ride('pending'))])),
          [deliveryAddonsRepositoryProvider.overrideWithValue(repo)],
          b,
        );
        expect(find.text('Collect RM250.00 cash for the item'), findsOneWidget);
        expect(find.text('Covered parcel · declared RM800.00'), findsOneWidget);
        expect(find.textContaining('You can carry up to RM1,000.00'), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(ListView)), isEmpty);
        await tester.tap(find.byKey(const ValueKey('driver-cod-collect')));
        await pumpNotice(tester);
        expect(repo.call(#codCollected)!.positionalArguments, ['k1']);
        expect(find.text('Delivered, COD settled'), findsOneWidget);
        await closeNotice(tester);
        await tester.tap(find.byKey(const ValueKey('driver-cod-refuse')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('driver-cod-refused-confirm')));
        await tester.pumpAndSettle();
        expect(repo.call(#codRefused)!.positionalArguments, ['k1']);

        await _pump(
          tester,
          Scaffold(body: ListView(children: [DeliveryAddonsDriverPanel(request: ride('refused'))])),
          [deliveryAddonsRepositoryProvider.overrideWithValue(repo)],
          b,
        );
        expect(find.text('Bring the parcel back'), findsOneWidget);
        expect(find.byKey(const ValueKey('driver-cod-collect')), findsNothing);
        expect(unreadableTexts(tester, find.byType(ListView)), isEmpty);
      });

      testWidgets('the driver: a round trip waits at the drop-off, then heads back', (tester) async {
        final repo = _Repo();
        final arrived = DateTime.now().subtract(const Duration(minutes: 20));
        await _pump(
          tester,
          Scaffold(
            body: ListView(children: [
              DeliveryAddonsDriverPanel(
                request: RideRequest({
                  'id': 'k2', 'status': 'on_trip', 'currency': 'MYR', 'fare': 180, 'cargo_description': 'Crates',
                  'round_trip': true, 'return_leg_fare': 80, 'stairs_pickup': 2, 'cold_level': 'chilled',
                  'return_arrived_at': arrived.toUtc().toIso8601String(),
                  'addon_terms': {'roundTrip': {'freeWait': 15, 'waitPerMin': 0.5, 'maxWait': 120}},
                }),
              ),
            ]),
          ),
          [deliveryAddonsRepositoryProvider.overrideWithValue(repo)],
          b,
        );
        expect(find.textContaining('so far RM2.50'), findsOneWidget);
        expect(find.text('Stairs without a lift: 2 at pickup, 0 at drop-off'), findsOneWidget);
        expect(find.text('Cold truck: Chilled 0 to 8 °C'), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(ListView)), isEmpty);
        await tester.tap(find.byKey(const ValueKey('driver-return-start')));
        await pumpNotice(tester);
        expect(repo.call(#returnStart)!.positionalArguments, ['k2']);
        expect(find.text('The wait at the drop-off added RM2.50 to the fare.'), findsOneWidget);
        await closeNotice(tester);
      });

      testWidgets('the sender files a cover claim', (tester) async {
        final repo = _Repo();
        await _pump(
          tester,
          Scaffold(
            body: CoverClaimTile(
              rideId: 'k1', declared: 800, claimDays: 7, ended: DateTime.now().subtract(const Duration(days: 1)), money: _rm),
          ),
          [
            deliveryAddonsRepositoryProvider.overrideWithValue(repo),
            rideCoverClaimProvider.overrideWith((ref, id) async => null),
          ],
          b,
        );
        await _tap(tester, 'cover-claim-open');
        await tester.enterText(find.byKey(const ValueKey('cover-claim-amount')), '900');
        await tester.enterText(find.byKey(const ValueKey('cover-claim-reason')), 'The screen arrived cracked');
        await tester.tap(find.byKey(const ValueKey('cover-claim-send')));
        await pumpNotice(tester);
        expect(find.text('Claim up to the declared value, RM800.'), findsOneWidget);
        await closeNotice(tester);
        await tester.enterText(find.byKey(const ValueKey('cover-claim-amount')), '300');
        await tester.tap(find.byKey(const ValueKey('cover-claim-send')));
        await pumpNotice(tester);
        expect(repo.call(#fileClaim)!.positionalArguments, ['k1', 300.0, 'The screen arrived cracked']);
      });

      testWidgets('the admin page: rules, switches, steppers, a region that follows Default', (tester) async {
        final repo = _Repo();
        await _pump(
          tester,
          const DeliveryAddonsScreen(),
          [
            deliveryAddonsRepositoryProvider.overrideWithValue(repo),
            deliveryAddonRulesProvider.overrideWith((ref) async => _rules()),
            pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
            regionsProvider.overrideWith((ref) async => [
              RegionEntry(id: 'r1', values: const {'country': 'Malaysia', 'state': 'Penang'}),
            ]),
          ],
          b,
          size: const Size(1200, 2200),
        );
        expect(find.text('Add-ons, cover and cash on delivery'), findsOneWidget);
        expect(find.byKey(const ValueKey('addons-rule-default')), findsOneWidget);
        expect(find.byKey(const ValueKey('addons-rule-malaysia|sabah')), findsOneWidget);
        expect(tester.widget<Text>(find.byKey(const ValueKey('addons-stairs-perFloor-value'))).data, 'RM15');
        await _tap(tester, 'addons-stairs-perFloor-up');
        expect((repo.call(#save)!.positionalArguments.single as AddonRule).values['stairs'], {'on': true, 'perFloor': 16.0});
        await _tap(tester, 'addons-switch-cod');
        expect((repo.call(#save)!.positionalArguments.single as AddonRule).values['cod'], {'on': false});
        expect(unreadableTexts(tester, find.byType(ListView)), isEmpty);

        await _tap(tester, 'addons-rule-malaysia|sabah');
        expect(tester.widget<Text>(find.byKey(const ValueKey('addons-stairs-perFloor-value'))).data, 'RM10');
        expect(find.text('As Default'), findsWidgets);
        await _tap(tester, 'addons-clear-stairs');
        final cleared = repo.call(#save)!.positionalArguments.single as AddonRule;
        expect(cleared.scope, _sabah);
        expect(cleared.values.containsKey('stairs'), isFalse);

        await _tap(tester, 'addons-add-rule');
        expect(find.text('Penang'), findsWidgets);
        await tester.tap(find.text('Penang').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('addons-rule-malaysia|penang')), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(ListView)), isEmpty);
      });

      testWidgets('the cover claims page: approve and pay', (tester) async {
        final repo = _Repo();
        await _pump(
          tester,
          const CoverClaimsScreen(),
          [
            deliveryAddonsRepositoryProvider.overrideWithValue(repo),
            pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
            coverClaimsProvider.overrideWith((ref) async => const [
              CoverClaim(id: 'cl1', rideId: 'k1', amount: 300, declaredValue: 800, reason: 'Screen cracked',
                  status: 'open', service: 'Courier Motorcycle', currency: 'MYR'),
              CoverClaim(id: 'cl2', rideId: 'k2', amount: 50, declaredValue: 100, reason: 'Box wet',
                  status: 'rejected', currency: 'MYR', adminNote: 'Not covered'),
            ]),
          ],
          b,
        );
        expect(find.text('Waiting for a decision'), findsOneWidget);
        expect(find.byKey(const ValueKey('cover-claim-approve-cl2')), findsNothing);
        expect(unreadableTexts(tester, find.byType(ListView)), isEmpty);
        await _tap(tester, 'cover-claim-approve-cl1');
        await tester.enterText(find.byKey(const ValueKey('cover-claim-decide-amount')), '250');
        await tester.tap(find.byKey(const ValueKey('cover-claim-decide-confirm')));
        await pumpNotice(tester);
        final c = repo.call(#decideClaim)!;
        expect(c.positionalArguments, ['cl1']);
        expect(c.namedArguments[#approve], isTrue);
        expect(c.namedArguments[#amount], 250);
      });
    });
  }
}
