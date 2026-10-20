// Ride Options by place (migration 0253): the smallest place with its own
// value wins, places inherit, nothing set is free, an option off by place
// or blocked by service is hidden from the rider and its charge left out;
// the blob's amounts as Default; and the admin's page (pick a place, set a
// charge, use the place above's, switch an option off, block a service,
// the summaries) in light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show RegionEntry;
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_store.dart';
import 'package:get_ride/src/admin/screens/meterapp/ride_option_places_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/option_charge.dart';
import 'package:get_ride/src/core/partner_type_rules.dart' show RegionScope;
import 'package:get_ride/src/core/ride_assistance.dart';
import 'package:get_ride/src/core/ride_confirm.dart' show RideOptions;
import 'package:get_ride/src/core/ride_option_charges.dart';
import 'package:get_ride/src/core/ride_option_places.dart';
import 'package:get_ride/src/core/ride_option_settings.dart';
import 'package:get_ride/src/core/ride_pets.dart';
import 'package:get_ride/src/data/ride_option_places_repository.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

const _my = RegionScope(country: 'Malaysia');
const _sel = RegionScope(country: 'Malaysia', state: 'Selangor');
const _pj = RegionScope(country: 'Malaysia', state: 'Selangor', city: 'Petaling Jaya');
const _ss15 = RegionScope(country: 'Malaysia', state: 'Selangor', city: 'Petaling Jaya', suburb: 'SS15');
const _kl = RegionScope(country: 'Malaysia', state: 'Kuala Lumpur');
const _sg = RegionScope(country: 'Singapore');

PlaceCharge _rm(double v, {bool? perPet}) => PlaceCharge(OptionCharge(value: v), perPet: perPet);

/// The sample's places: cats RM5 (S$4 in Singapore), dogs RM8 (RM10 in KL),
/// luggage help RM5 (RM4 in Selangor), a child seat RM5, nothing for the
/// wheelchair; pets blocked on Premium everywhere, off in KL.
final _places = OptionPlaces([
  OptionPlaceSettings(
    charges: {
      OptionChargeKey.pet('Cat'): _rm(5, perPet: true),
      OptionChargeKey.pet('Dog'): _rm(8, perPet: true),
      OptionChargeKey.petSize('L'): _rm(3),
      OptionChargeKey.assist('luggage'): _rm(5),
      OptionChargeKey.childSeat: _rm(5),
    },
    blocked: {RideOptionKind.pet: {'premium'}},
  ),
  OptionPlaceSettings(scope: _sg, charges: {OptionChargeKey.pet('Cat'): _rm(4, perPet: true)}),
  OptionPlaceSettings(scope: _kl, charges: {OptionChargeKey.pet('Dog'): _rm(10, perPet: true)}, offered: {RideOptionKind.pet: false}),
  OptionPlaceSettings(scope: _sel, charges: {OptionChargeKey.assist('luggage'): _rm(4)}),
  OptionPlaceSettings(scope: _ss15, charges: {OptionChargeKey.childSeat: PlaceCharge.free}, blocked: {RideOptionKind.pet: {}}),
]);

class _FakeStore implements DisplaySettingsStore {
  _FakeStore(Map<String, dynamic> raw) : blob = mergeDisplaySettings(raw);
  Map<String, dynamic> blob;

  @override
  Future<Map<String, dynamic>> fetch() async => blob;

  @override
  Future<Map<String, dynamic>> update(DisplayEdit edit) async => blob = edit(blob);

  @override
  Future<List<Map<String, dynamic>>> entries(String category) async => const [];
}

/// The places table in memory.
class _FakePlaces implements RideOptionPlacesRepository {
  _FakePlaces(this.rows);
  List<OptionPlaceSettings> rows;

  @override
  Future<List<OptionPlaceSettings>?> all() async => rows;

  @override
  Future<OptionPlaceSettings> edit(RegionScope scope, OptionPlaceSettings Function(OptionPlaceSettings) edit) async {
    final next = edit(OptionPlaces(rows).at(scope));
    await save(next);
    return next;
  }

  @override
  Future<void> save(OptionPlaceSettings s) async {
    rows = [
      for (final r in rows)
        if (r.scope.key != s.scope.key) r,
      if (!s.isEmpty) s,
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await _settle(tester);
  await tester.tap(f);
  await _settle(tester);
}

Future<void> _tapKey(WidgetTester tester, String key) => _tap(tester, find.byKey(ValueKey(key)));

String _text(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

void main() {
  group('pure', () {
    test('the smallest place with its own amount wins, walking up to Default', () {
      final dog = OptionChargeKey.pet('Dog');
      expect(_places.chargeAt(_kl, dog).value, _rm(10, perPet: true), reason: 'the state sets its own');
      expect(_places.chargeAt(_kl, dog).from, _kl);
      expect(_places.chargeAt(_ss15, dog).value, _rm(8, perPet: true), reason: 'nothing below: Default');
      expect(_places.chargeAt(_ss15, dog).from, RegionScope.all);
      final luggage = OptionChargeKey.assist('luggage');
      expect(_places.chargeAt(_ss15, luggage).value.charge.value, 4, reason: 'the suburb inherits from its state');
      expect(_places.chargeAt(_ss15, luggage).from, _sel);
      expect(_places.chargeAt(_pj, luggage).from, _sel, reason: 'the city too');
      expect(_places.chargeAt(_kl, luggage).value.charge.value, 5, reason: 'another state: Default');
      expect(_places.chargeAt(_sg, OptionChargeKey.pet('Cat')).value.charge.value, 4);
      // Set to 0 in the suburb: free there, though Default charges.
      expect(_places.chargeAt(_ss15, OptionChargeKey.childSeat).value.charge.isZero, isTrue);
      expect(_places.chargeAt(_ss15, OptionChargeKey.childSeat).from, _ss15);
      expect(_places.chargeAt(_pj, OptionChargeKey.childSeat).value.charge.value, 5);
    });

    test('nothing set anywhere is free; none at all is free everywhere', () {
      final wheel = OptionChargeKey.assist('wheelchair');
      expect(_places.chargeAt(_ss15, wheel).value, PlaceCharge.free);
      expect(_places.chargeAt(_ss15, wheel).from, isNull);
      expect(OptionPlaces.none.chargeAt(_my, OptionChargeKey.childSeat).value, PlaceCharge.free);
      expect(OptionPlaces.none.offeredAt(_my, RideOptionKind.pet).value, isTrue);
      expect(OptionPlaces.none.blockedAt(_my, RideOptionKind.pet).value, isEmpty);
    });

    test('an option off by place, and places below inherit unless they set their own', () {
      expect(_places.offeredAt(_kl, RideOptionKind.pet).value, isFalse);
      expect(_places.offeredAt(const RegionScope(country: 'Malaysia', state: 'Kuala Lumpur', city: 'Bukit Bintang'),
          RideOptionKind.pet).value, isFalse);
      expect(_places.offeredAt(_sel, RideOptionKind.pet).value, isTrue);
      final on = OptionPlaces([
        ..._places.rows,
        const OptionPlaceSettings(
          scope: RegionScope(country: 'Malaysia', state: 'Kuala Lumpur', city: 'Cheras'),
          offered: {RideOptionKind.pet: true},
        ),
      ]);
      expect(on.offeredAt(const RegionScope(country: 'Malaysia', state: 'Kuala Lumpur', city: 'Cheras'), RideOptionKind.pet).value,
          isTrue);
    });

    test('blocked by service: by place, inherited, and cleared below', () {
      expect(_places.availableAt(_sel, RideOptionKind.pet, serviceId: 'premium'), isFalse);
      expect(_places.availableAt(_sel, RideOptionKind.pet, serviceId: 'ride'), isTrue);
      expect(_places.availableAt(_ss15, RideOptionKind.pet, serviceId: 'premium'), isTrue, reason: 'none blocked in SS15');
      expect(_places.availableAt(_kl, RideOptionKind.pet, serviceId: 'ride'), isFalse, reason: 'off in KL');
      expect(_places.availableAt(_sel, RideOptionKind.childSeat, serviceId: 'premium'), isTrue);
    });

    test("what the rider at a place is offered and pays", () {
      final base = RideOptionsConfig.fromSettings(const {});
      final here = _places.here(_sel);
      expect(here.config(base, serviceId: 'premium').shown(), isNot(contains(RideOptionKind.pet)));
      expect(here.config(base, serviceId: 'ride').shown(), contains(RideOptionKind.pet));
      expect(_places.here(_kl).config(base).shown(), isNot(contains(RideOptionKind.pet)));
      final pets = here.pets(const PetConfig());
      expect(pets.chargeFor('Dog'), const PetCharge(charge: OptionCharge(value: 8)));
      expect(pets.chargeFor('Rabbit').isZero, isTrue);
      expect(pets.sizeExtraFor('L'), 3);
      final help = here.assistance(const AssistanceCatalogue());
      expect(help.byId('luggage')!.charge, const OptionCharge(value: 4));
      expect(help.byId('wheelchair')!.charge.isZero, isTrue);
      // A booking with two dogs (one L), luggage help and two child seats.
      const o = RideOptions(
        pet: true,
        pets: [RidePet(type: 'Dog', size: 'L'), RidePet(type: 'Dog', size: 'S')],
        childSeat: true,
        childSeats: 2,
        assistance: RideAssistance(items: [AssistancePick(id: 'luggage', name: 'Help with luggage')]),
      );
      final lines = rideOptionCharges(o, 40, pets: pets, assistance: help, childSeat: here.childSeat);
      expect([for (final l in lines) (l.kind, l.amount)], [('child-seat', 10.0), ('pet', 19.0), ('assistance', 4.0)]);
      // In SS15 the child seat is free.
      final ss15 = _places.here(_ss15);
      expect(rideOptionCharges(o, 40, childSeat: ss15.childSeat).where((l) => l.kind == 'child-seat'), isEmpty);
      // More passengers, once for the ride, as a percentage.
      expect(
        rideOptionCharges(const RideOptions(morePassengers: true), 50,
            morePassengers: const OptionCharge(kind: OptionChargeKind.percent, value: 10)).single.amount,
        5,
      );
    });

    test("the blob's amounts become Default, and the row is written back as read", () {
      final blob = {
        ...const PetConfig(
          charges: {'Dog': PetCharge(charge: OptionCharge(value: 10)), 'Cat': PetCharge(charge: OptionCharge(kind: OptionChargeKind.percent, value: 5), perPet: false)},
          sizeExtras: {'L': 2.5},
        ).toSettings(),
        ...AssistanceCatalogue(items: [
          for (final i in defaultAssistanceItems)
            i.id == 'wheelchair' || i.id == guideDogAssistanceId ? i.copyWith(charge: const OptionCharge(value: 5)) : i,
        ]).toSettings(),
      };
      final p = OptionPlaces.fromBlob(blob);
      expect(p.rows.single.scope.isDefault, isTrue);
      expect(p.rows.single.charges, {
        'pet:Dog': _rm(10, perPet: true),
        'pet:Cat': const PlaceCharge(OptionCharge(kind: OptionChargeKind.percent, value: 5), perPet: false),
        'pet-size:L': _rm(2.5),
        'assist:wheelchair': _rm(5),
      }, reason: 'never the guide dog');
      // So nothing changes for riders: Default's amounts are what they were.
      final here = p.here(_ss15);
      expect(here.pets(PetConfig.fromSettings(blob)).chargeFor('Dog'), PetConfig.fromSettings(blob).chargeFor('Dog'));
      for (final r in _places.rows) {
        final back = OptionPlaceSettings.fromRow({...r.toRow()});
        expect(back.scope, r.scope);
        expect(back.charges, r.charges);
        expect(back.offered, r.offered);
        expect(back.blocked, r.blocked);
      }
      expect(_ss15.toString(), isNotEmpty);
      expect(_ss15.level, 'suburb');
      expect(RegionScope.all.level, 'default');
      expect(_ss15.chain, [_ss15, _pj, _sel, _my, RegionScope.all]);
      expect(_ss15.key, 'malaysia|selangor|petaling jaya|ss15', reason: "the server's place_key");
    });

    test('a pet type renamed takes its charges with it in every place', () {
      final renamed = _places.renamedCharge('pet:Dog', 'pet:Hound');
      expect([for (final r in renamed) r.scope], [RegionScope.all, _kl]);
      expect(renamed.first.charges['pet:Hound'], _rm(8, perPet: true));
      expect(renamed.first.charges.containsKey('pet:Dog'), isFalse);
    });

    test('the charge lines the admin sets, in the admin order', () {
      final slots = optionChargeSlots(RideOptionsConfig.fromSettings(const {}),
          const PetConfig(types: ['Dog'], sizes: ['L']), const AssistanceCatalogue());
      expect([for (final s in slots) s.key].take(4), ['child-seat', 'more-passengers', 'pet:Dog', 'pet-size:L']);
      expect(slots.any((s) => s.key == 'assist:$guideDogAssistanceId'), isFalse, reason: 'the guide dog is always free');
      expect(describePlaceCharge(_rm(5, perPet: true), (v) => 'RM${trimNumber(v)}'), 'RM5 per pet');
      expect(describePlaceCharge(PlaceCharge.free, (v) => '$v'), 'Free');
    });
  });

  for (final b in Brightness.values) {
    final mode = b == Brightness.dark ? ' (dark)' : '';

    group('Admin: Charges and where offered$mode', () {
      Future<_FakePlaces> pump(WidgetTester tester) async {
        tester.view.physicalSize = const Size(900, 3200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final places = _FakePlaces([..._places.rows]);
        await tester.pumpWidget(ProviderScope(
          retry: (_, _) => null,
          overrides: [
            supabaseProvider.overrideWithValue(_db),
            pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
            displayStoreProvider.overrideWithValue(_FakeStore({
              ...const PetConfig(types: ['Cat', 'Dog'], sizes: ['M', 'L']).toSettings(),
            })),
            rideOptionPlacesRepositoryProvider.overrideWithValue(places),
            regionsProvider.overrideWith((ref) async => [
              RegionEntry(id: 'my', values: const {'country': 'Malaysia', 'currencyName': 'MYR'}),
              RegionEntry(id: 'sel', values: const {'country': 'Malaysia', 'state': 'Selangor'}),
              RegionEntry(id: 'kl', values: const {'country': 'Malaysia', 'state': 'Kuala Lumpur'}),
              RegionEntry(id: 'pj', values: const {'country': 'Malaysia', 'state': 'Selangor', 'city': 'Petaling Jaya'}),
              RegionEntry(id: 'sg', values: const {'country': 'Singapore', 'currencyName': 'SGD'}),
            ]),
            settingsEntriesProvider.overrideWith((ref, category) async => category == 'vehicle-services'
                ? [
                    {'id': 'ride', 'values': {'name': 'Ride'}},
                    {'id': 'premium', 'values': {'name': 'Premium'}},
                  ]
                : const <Map<String, dynamic>>[]),
          ],
          child: MaterialApp(theme: appTheme(b), home: const RideOptionPlacesScreen()),
        ));
        await _settle(tester);
        return places;
      }

      Future<void> unmount(WidgetTester tester) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(minutes: 1));
      }

      testWidgets('Default, then a state: inherited amounts, set here, use the place above\'s', (tester) async {
        final places = await pump(tester);
        expect(find.byKey(const ValueKey('option-place-bar')), findsOneWidget);
        expect(_text(tester, 'place-charge-value-pet:Dog'), 'RM8 per pet');
        expect(find.byKey(const ValueKey('place-charge-clear-pet:Dog')), findsOneWidget, reason: 'set at Default');

        // Pick Selangor from the searchable place list.
        await _tapKey(tester, 'option-place-pick');
        await _tap(tester, find.text('Selangor').last);
        expect(find.byKey(const ValueKey('option-place-crumb-malaysia|selangor')), findsOneWidget);
        expect(find.byKey(const ValueKey('option-place-crumb-malaysia')), findsOneWidget);
        expect(_text(tester, 'option-place-note'), 'Amounts in MYR. Anything not set here uses Malaysia.');
        expect(find.descendant(of: find.byKey(const ValueKey('place-charge-pet:Dog')), matching: find.text('From Default (everywhere)')),
            findsOneWidget);
        expect(find.descendant(of: find.byKey(const ValueKey('place-charge-assist:luggage')), matching: find.text('Set here')),
            findsOneWidget, reason: "Selangor's own amount for luggage help");
        expect(find.descendant(of: find.byKey(const ValueKey('place-charge-assist:wheelchair')), matching: find.text('Nothing set')),
            findsOneWidget);

        // Set for Selangor: dogs RM7, once per ride.
        await _tapKey(tester, 'place-charge-set-pet:Dog');
        await tester.enterText(find.byKey(const ValueKey('place-charge-amount')), '7');
        await _tap(tester, find.text('Once per ride'));
        await _tapKey(tester, 'place-charge-save');
        expect(OptionPlaces(places.rows).at(_sel).charges['pet:Dog'],
            const PlaceCharge(OptionCharge(value: 7), perPet: false));
        expect(_text(tester, 'place-charge-value-pet:Dog'), 'RM7 once per ride');
        expect(_text(tester, 'summary-from-pet:Dog'), 'Set here');

        // Use Malaysia's: back to Default's amount.
        await _tapKey(tester, 'place-charge-reset-pet:Dog');
        expect(OptionPlaces(places.rows).at(_sel).charges.containsKey('pet:Dog'), isFalse);
        expect(_text(tester, 'summary-pays-pet:Dog'), 'RM8 per pet');
        expect(_text(tester, 'summary-from-pet:Dog'), 'Default (everywhere)');
        expect(_text(tester, 'summary-from-pet-size:M'), 'Nothing set, so free');
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });

      testWidgets('an option off here, a service blocked, and the summaries', (tester) async {
        final places = await pump(tester);
        await _tap(tester, find.byKey(const ValueKey('option-place-crumb-')));
        await _tapKey(tester, 'option-place-pick');
        await _tap(tester, find.text('Kuala Lumpur').last);
        // Pets are off in KL (set there): riders don't see them.
        expect(tester.widget<Switch>(find.descendant(of: find.byKey(const ValueKey('place-offered-pet')),
            matching: find.byType(Switch))).value, isFalse);
        expect(find.textContaining("Riders in Kuala Lumpur don't see Pet with me."), findsOneWidget);
        expect(find.byKey(const ValueKey('summary-service-pet-ride')), findsOneWidget);
        expect(find.descendant(of: find.byKey(const ValueKey('summary-service-pet-ride')), matching: find.text('Blocked')),
            findsOneWidget);
        expect(_text(tester, 'summary-pays-pet:Dog'), '—');
        // Use Malaysia's: on again.
        await _tapKey(tester, 'place-offered-reset-pet');
        expect(OptionPlaces(places.rows).at(_kl).offered, isEmpty);

        // Child seats off on Premium in Malaysia.
        await _tap(tester, find.byKey(const ValueKey('option-place-crumb-malaysia')));
        expect(find.descendant(of: find.byKey(const ValueKey('summary-service-child-seat-premium')),
            matching: find.text('Offered')), findsOneWidget);
        await _tapKey(tester, 'place-service-child-seat-premium');
        expect(OptionPlaces(places.rows).at(_my).blocked[RideOptionKind.childSeat], {'premium'});
        expect(find.descendant(of: find.byKey(const ValueKey('summary-service-child-seat-premium')),
            matching: find.text('Blocked')), findsOneWidget);
        // Pets: blocked on Premium from Default.
        expect(find.descendant(of: find.byKey(const ValueKey('summary-service-pet-premium')),
            matching: find.text('Blocked')), findsOneWidget);
        // Switched off in Malaysia.
        await _tap(tester, find.descendant(of: find.byKey(const ValueKey('place-offered-assistance')), matching: find.byType(Switch)));
        expect(OptionPlaces(places.rows).at(_my).offered[RideOptionKind.assistance], isFalse);
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });
    });
  }
}
