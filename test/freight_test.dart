// Freight (migration 0267): the sizes from Vehicle Services under Freight,
// the home box that opens the page only when there is one, the options'
// fixed charges by place, the request it books (a ride request with the
// cargo, bid on), My freight requests (offers, accept, cancel), the
// driver's view of the cargo and the admin's fields -- light and dark.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/catalogue/catalogue_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/freight.dart';
import 'package:get_ride/src/core/home_sections.dart';
import 'package:get_ride/src/core/option_charge.dart';
import 'package:get_ride/src/core/partner_type_rules.dart' show RegionScope;
import 'package:get_ride/src/core/payment_types.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/core/request_viewers.dart';
import 'package:get_ride/src/core/ride_assistance.dart';
import 'package:get_ride/src/core/ride_option_charges.dart';
import 'package:get_ride/src/core/ride_option_places.dart';
import 'package:get_ride/src/core/ride_option_settings.dart';
import 'package:get_ride/src/core/ride_pets.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/freight_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/photo_picker.dart';
import 'package:get_ride/src/data/ride_option_places_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/request_sheet.dart';
import 'package:get_ride/src/features/ride/freight_parts.dart';
import 'package:get_ride/src/features/ride/freight_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:latlong2/latlong.dart';

import 'text_contrast.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

const _van = FreightVehicle(
  id: 'v1',
  name: 'Van (S)',
  description: 'boxes, small appliances',
  maxLoadKg: 500,
  lengthM: 2,
  widthM: 1.4,
  heightM: 1.3,
);
const _lorry = FreightVehicle(id: 'v2', name: '3-tonne lorry (L)', maxLoadKg: 3000, closedBody: true);

const _place = RegionScope(country: 'Malaysia');

/// Ride Options in Malaysia: 1 helper RM30, 2 helpers RM60, riding along
/// RM10, a closed body free; riding along blocked on the lorry.
OptionPlaces _places() => const OptionPlaces([
  OptionPlaceSettings(
    scope: _place,
    charges: {
      'helper-1': PlaceCharge(OptionCharge(value: 30)),
      'helper-2': PlaceCharge(OptionCharge(value: 60)),
      'ride-along': PlaceCharge(OptionCharge(value: 10)),
    },
    blocked: {
      RideOptionKind.rideAlong: {'v2'},
    },
  ),
]);

/// The ride repository the page books through: every call is kept.
class _Rides implements RideRepository {
  final calls = <Invocation>[];

  Invocation? call(Symbol name) => calls.where((c) => c.memberName == name).lastOrNull;

  @override
  Future<RequestViewers> viewers(String requestId) async => RequestViewers.none;

  @override
  Future<void> markViewed(String requestId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation);
    switch (invocation.memberName) {
      case #createRequest:
        return Future<Booked>.value((now: RideRequest({'id': 'new', 'status': 'open'}), later: null));
      case #acceptOffer:
        return Future<RideRequest?>.value(RideRequest({'id': 'f1', 'status': 'accepted'}));
      case #declineOffer:
      case #cancel:
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

RideRequest _request({String status = 'open', bool offer = false}) => RideRequest({
  'id': 'f1',
  'rider_id': 'rider',
  'status': status,
  'service': 'Van (S)',
  'fare': 180,
  'ride_fare': 180,
  'currency': 'MYR',
  'offer_me': true,
  'pickup_name': '12, Jalan Ampang, Kuala Lumpur',
  'drop_name': '8, Jalan SS2/24, Petaling Jaya',
  'pickup_lat': 3.1579,
  'pickup_lng': 101.7116,
  'drop_lat': 3.1180,
  'drop_lng': 101.6230,
  'distance_km': 14.2,
  'duration_min': 28,
  'payment_mode': 'Cash',
  'passengers': 1,
  'cargo_description': 'Single-door fridge and 6 boxes',
  'cargo_photo_path': 'rider/cargo-1.jpg',
  'option_names': {'helper-1': '1 helper', 'closed-body': 'Closed body'},
  'option_charges': [
    {'kind': 'helper-1', 'name': '1 helper', 'amount': 30},
  ],
  'created_at': DateTime.now().toUtc().toIso8601String(),
  if (offer) 'offered_fare': 190,
  if (offer) 'partner_id': 'driver-1',
  if (offer) 'partner_name': 'Ali',
});

/// The page's places: the city first, then the street, then the pin.
Future<Place?> _search(BuildContext context, {required String title, LatLng? near, bool onMap = false}) async {
  if (title.contains('city or town')) {
    return title.startsWith('From')
        ? const Place(name: 'Kuala Lumpur', address: 'Kuala Lumpur', point: LatLng(3.139, 101.687))
        : const Place(name: 'Petaling Jaya', address: 'Petaling Jaya', point: LatLng(3.107, 101.607));
  }
  return (near?.latitude ?? 0) > 3.12
      ? const Place(name: '12, Jalan Ampang', address: '12, Jalan Ampang, Kuala Lumpur', point: LatLng(3.158, 101.712))
      : const Place(name: '8, Jalan SS2/24', address: '8, Jalan SS2/24, Petaling Jaya', point: LatLng(3.118, 101.623));
}

List<Override> _overrides(_Rides rides, {List<RideRequest> mine = const [], List<FreightVehicle> vehicles = const [_van, _lorry]}) => [
  rideRepositoryProvider.overrideWithValue(rides),
  freightVehiclesProvider.overrideWith((ref) async => vehicles),
  displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
  rideOptionPlacesProvider.overrideWith((ref) async => _places()),
  fareTariffsProvider.overrideWith((ref) async => const []),
  serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
  paymentChoicesProvider.overrideWith((ref) async => const [PaymentChoice('Cash', 'Cash', PaymentKind.cash)]),
  myFreightRequestsProvider.overrideWith((ref) => Stream.value(mine)),
  deviceBlockedProvider.overrideWith((ref) async => false),
  profileProvider.overrideWith((ref) async => null),
  photoCameraAvailableProvider.overrideWithValue(false),
  photoPickerProvider.overrideWithValue((_) async => (bytes: _png, name: 'cargo.png')),
  freightCargoPhotoUploadProvider.overrideWithValue((bytes, name) async => 'rider/cargo-1.png'),
  freightPlaceSearchProvider.overrideWithValue(_search),
  freightPickupContextProvider.overrideWithValue(
    (p) async => (area: const AreaInfo(country: 'Malaysia'), place: _place, pricing: RegionPricing.none, timezone: null),
  ),
  freightRouteProvider.overrideWithValue((a, b) async => (km: 40.0, min: 60.0)),
  freightConfigProvider.overrideWith((ref) async => const FreightConfig()),
];

Future<void> _pump(WidgetTester tester, Widget home, List<Override> overrides, Brightness b) async {
  tester.view.physicalSize = const Size(420, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: overrides,
      child: MaterialApp(theme: appTheme(b), home: home),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _address(WidgetTester tester, String field) async {
  await tester.tap(find.byKey(ValueKey(field)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('freight-address-city')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('freight-address-street')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('freight-address-next')));
  await tester.pumpAndSettle();
}

void main() {
  group('pure', () {
    test('the sizes: active Vehicle Services under Freight, with their load', () {
      final sizes = freightVehiclesFrom([
        (id: 'a', values: {'name': 'Ride', 'serviceTypes': ['Car']}),
        (
          id: 'b',
          values: {
            'name': 'Van (S)',
            'serviceTypes': [' freight '],
            'maxLoadKg': 500,
            'loadLengthM': '2',
            'loadWidthM': 1.4,
            'loadHeightM': 1.3,
            'shortDescription': 'boxes',
            'displayPriority': 2,
          },
        ),
        (id: 'c', values: {'name': 'Old lorry', 'serviceTypes': ['Freight'], 'status': false}),
        (id: 'd', values: {'name': '5-tonne lorry', 'serviceTypes': ['Freight'], 'maxLoadKg': 5000, 'closedBody': true, 'displayPriority': 1}),
      ]);
      expect(sizes.map((v) => v.name), ['5-tonne lorry', 'Van (S)'], reason: 'active ones, in display priority');
      expect(sizes.last.loadText, 'up to 500 kg');
      expect(sizes.first.loadText, 'up to 5,000 kg');
      expect(sizes.last.sizeText, 'len/wid/hgt 2.0/1.4/1.3 m');
      expect(sizes.first.sizeText, isNull);
      expect(sizes.first.closedBody, isTrue);
      expect(sizes.last.subtitle, 'up to 500 kg · boxes');
      expect(freightAvailable(sizes), isTrue);
      expect(freightAvailable(freightVehiclesFrom([(id: 'a', values: {'name': 'Ride'})])), isFalse);
      expect(isFreightService(const RideService('Van', '', 1, 1, serviceTypes: ['Freight'])), isTrue);
      expect(isFreightService(const RideService('Ride', '', 1, 4, serviceTypes: ['Car'])), isFalse);
      expect(freightVehicleNamed(sizes, 'van (s)')?.id, 'b');
    });

    test('the home Freight box opens the page only with a size to book', () {
      final settings = {
        'serviceBoxes': [
          {},
          {},
          {},
          {},
          {'comingSoon': true},
        ],
      };
      expect(serviceBoxViews(settings).last.route, isNull, reason: 'no freight size: coming soon');
      expect(serviceBoxViews(settings).last.badge, 'SOON');
      final open = serviceBoxViews(settings, freightAvailable: true).last;
      expect(open.freight, isTrue);
      expect(open.route, freightPageRoute, reason: 'derived from the sizes, whatever the stored flag says');
      expect(open.badge, isNull);
      expect(serviceBoxViews(settings, freightAvailable: true, serviceEnabled: false).last.route, isNull);
      // Renamed, but linked to the Freight service type.
      final linked = serviceBoxViews(
        {
          'serviceBoxes': [
            {'name': 'Lorries', 'serviceId': 's9'},
          ],
        },
        serviceNames: {'s9': 'Freight'},
        freightAvailable: true,
      );
      expect(linked.first.route, freightPageRoute);
      expect(serviceBoxViews(settings, freightAvailable: true).first.freight, isFalse);
    });

    test('options: offered and blocked by place, one helper choice, fixed charges', () {
      const config = RideOptionsConfig();
      final here = _places().here(_place);
      expect(freightOptionsHere(config, here, vehicleId: 'v1'), RideOptionKind.freightKinds);
      expect(freightOptionsHere(config, here, vehicleId: 'v2'), isNot(contains(RideOptionKind.rideAlong)));
      expect(config.shown(), isNot(contains(RideOptionKind.helperOne)), reason: 'never on a ride\'s sheet');
      var picked = toggleFreightOption(const {}, RideOptionKind.helperOne);
      picked = toggleFreightOption(picked, RideOptionKind.rideAlong);
      picked = toggleFreightOption(picked, RideOptionKind.helperTwo);
      expect(picked, {RideOptionKind.helperTwo, RideOptionKind.rideAlong});
      final lines = freightOptionCharges(picked, here, config);
      expect([for (final l in lines) (l.kind, l.name, l.amount)], [('helper-2', '2 helpers', 60.0), ('ride-along', "I'll ride along", 10.0)]);
      expect(freightOptionCharges({RideOptionKind.closedBody}, here, config), isEmpty, reason: 'free: no line');
      expect(freightChargeText(here.freight(RideOptionKind.helperOne), (v) => 'RM${v.round()}'), 'RM30');
      expect(freightChargeText(here.freight(RideOptionKind.closedBody), (v) => 'RM$v'), 'Free');
      expect(freightOptionCharges(picked, OptionPlaces.none.here(RegionScope.all), config), isEmpty,
          reason: 'nothing set anywhere: free');
      expect(config.freightNamesFor(picked), {'helper-2': '2 helpers', 'ride-along': "I'll ride along"});
      final renamed = RideOptionsConfig.fromSettings({
        RideOptionsConfig.key: {
          'labels': {'helper-1': 'One mover'},
          'hidden': ['closed-body'],
        },
      });
      expect(renamed.freightShown, [RideOptionKind.helperOne, RideOptionKind.helperTwo, RideOptionKind.rideAlong]);
      expect(renamed.freightNamesFor({RideOptionKind.helperOne}), {'helper-1': 'One mover'});
      expect(freightOptionsOf({'helper-1': 'One mover', 'pet': 'Pet'}), [RideOptionKind.helperOne]);
    });

    test('the admin page: a fixed charge each, reordered within the freight list', () {
      final slots = optionChargeSlots(const RideOptionsConfig(), const PetConfig(), const AssistanceCatalogue());
      final freight = [for (final s in slots) if (s.option.freight) s];
      expect([for (final s in freight) (s.key, s.label, s.fixedOnly)], [
        ('helper-1', '1 helper', true),
        ('helper-2', '2 helpers', true),
        ('closed-body', 'Closed body', true),
        ('ride-along', "I'll ride along", true),
      ]);
      // Up from the first freight option: it stays first among them (the
      // ride options above are another list).
      final s = moveRideOption(const {}, RideOptionKind.helperOne, -1);
      expect(rideOptionsOf(s).order, const RideOptionsConfig().order);
      final down = moveRideOption(const {}, RideOptionKind.assistance, 1);
      expect(rideOptionsOf(down).order.indexOf(RideOptionKind.assistance), 3, reason: 'the last ride option stays last');
      final swapped = rideOptionsOf(moveRideOption(const {}, RideOptionKind.helperOne, 1)).order;
      expect(swapped.sublist(4, 6), [RideOptionKind.helperTwo, RideOptionKind.helperOne]);
    });

    test('the request: what is missing, the note, the fare and the cargo columns', () {
      expect(freightDraftProblem(const FreightDraft()), 'Add the pickup location.');
      expect(freightDraftProblem(const FreightDraft(pickup: true)), 'Add the destination.');
      expect(freightDraftProblem(const FreightDraft(pickup: true, drop: true)), 'Describe your cargo.');
      expect(freightDraftProblem(const FreightDraft(pickup: true, drop: true, description: 'Sofa')), 'Choose a vehicle size.');
      expect(freightDraftProblem(const FreightDraft(pickup: true, drop: true, description: 'Sofa', vehicle: _van)),
          'Enter the value of your items.');
      const ready = FreightDraft(
        pickup: true,
        drop: true,
        description: 'Sofa',
        vehicle: _van,
        offer: 150,
        declaredValue: 300,
        prohibitedAck: true,
      );
      expect(freightDraftProblem(ready), isNull);
      expect(
        freightDraftProblem(const FreightDraft(pickup: true, drop: true, description: 'Sofa', vehicle: _van, offer: 150)),
        'Enter the value of your items.',
      );
      expect(
        freightDraftProblem(const FreightDraft(
            pickup: true, drop: true, description: 'Sofa', vehicle: _van, offer: 150, declaredValue: 900, prohibitedAck: true)),
        'The value of your items is over the limit here.',
      );
      expect(
        freightDraftProblem(
            const FreightDraft(pickup: true, drop: true, description: 'Sofa', vehicle: _van, offer: 150, declaredValue: 10)),
        'Confirm that your cargo has none of the prohibited items.',
      );
      expect(
        freightDraftProblem(const FreightDraft(
          pickup: true,
          drop: true,
          description: 'Sofa',
          vehicle: _van,
          offer: 150,
          declaredValue: 300,
          prohibitedAck: true,
          photoUploading: true,
        )),
        'Wait for the photo to finish uploading.',
      );
      expect(freightNote(description: ' Sofa ', options: ['2 helpers'], time: FreightPickupTime.withinHour),
          'Freight: Sofa · 2 helpers · Pickup within 1 hour');
      const lines = [OptionChargeLine(kind: 'helper-1', name: '1 helper', amount: 30)];
      expect(freightFare(150, lines), 180);
      expect(freightOfferOf(180, lines), 150);
      expect(
        freightRequestColumns(
          description: ' Sofa ',
          photoPath: 'u/cargo-1.jpg',
          declaredValue: 300,
          prohibitedAck: true,
          recipient: (name: ' Mei ', phone: '+60123456789'),
        ),
        {
          'cargo_description': 'Sofa',
          'cargo_photo_path': 'u/cargo-1.jpg',
          'declared_value': 300.0,
          'prohibited_ack': true,
          'recipient_name': 'Mei',
          'recipient_phone': '+60123456789',
        },
      );
      expect(freightRequestColumns(description: 'Sofa', recipient: (name: 'Mei', phone: ' ')),
          {'cargo_description': 'Sofa', 'prohibited_ack': false});
      expect(rideCargoPhotoPath('u', 'x', 'PNG'), 'u/cargo-x.png');
      String m(double v) => 'RM ${v.round()}';
      expect(freightSuggestionText(150, m), 'Suggested RM 135 to RM 180 for this trip and vehicle.');
      expect(freightOfferProblem(null, 150, m), 'Enter your fare');
      expect(freightOfferProblem(50, 150, m), 'Minimum fare is RM 105');
      expect(freightOfferProblem(50, null, m), isNull, reason: 'no estimate yet: any amount');
      expect(freightStatusLabel('open'), 'Looking for drivers');
      expect(freightStatusLabel('completed'), 'Delivered');
    });

    test('Vehicle Services: the load and its size, optional, and the closed body', () {
      ValuesResult build(Map<String, String> freight, {bool? closed, Map<String, dynamic>? existing}) =>
          buildVehicleServiceValues(
            text: const {'name': 'Van (S)'},
            numbers: const {'costPerKm': '2', 'costPerMin': '0.3', 'minFareAmount': '20'},
            serviceTypes: const ['Freight'],
            fuel: const [],
            status: true,
            freight: freight,
            closedBody: closed,
            existing: existing,
          );
      final r = build({'maxLoadKg': '500', 'loadLengthM': '2', 'loadWidthM': '', 'loadHeightM': '1.3'}, closed: true);
      expect(r.error, isNull);
      expect([r.values['maxLoadKg'], r.values['loadLengthM'], r.values['loadHeightM'], r.values[closedBodyKey]],
          [500, 2, 1.3, true]);
      expect(r.values.containsKey('loadWidthM'), isFalse, reason: 'a blank field is not kept');
      final cleared = build({'maxLoadKg': ''}, closed: false, existing: r.values);
      expect(cleared.values.containsKey('maxLoadKg'), isFalse);
      expect(cleared.values.containsKey(closedBodyKey), isFalse);
      expect(cleared.values['loadLengthM'], 2, reason: 'a field not on the form is kept');
      expect(build({'maxLoadKg': '-1'}).error, 'Max load must be a number of 0 or more.');
      expect(vehicleServiceMeta(r.values), contains('Load 500 kg'));
      expect(vehicleServiceMeta(r.values), contains('Closed body'));
    });
  });

  for (final b in Brightness.values) {
    testWidgets('the Freight page: fill it in, pick the size and options, offer, create (${b.name})', (tester) async {
      final rides = _Rides();
      await _pump(tester, const FreightScreen(), _overrides(rides), b);
      expect(find.text('Freight'), findsWidgets);
      expect(find.text('Pickup location'), findsOneWidget);
      expect(find.text('Van (S)'), findsOneWidget, reason: 'the first size is chosen');
      // Nothing filled in: the button waits, and says what is missing first.
      FilledButton create() => tester.widget<FilledButton>(find.byKey(const ValueKey('freight-create')));
      expect(create().onPressed, isNull);
      expect(find.byKey(const ValueKey('freight-create-hint')), findsOneWidget);
      expect(find.text('Add the pickup location.'), findsOneWidget);

      await _address(tester, 'freight-pickup');
      expect(find.text('12, Jalan Ampang, Kuala Lumpur'), findsOneWidget);
      await _address(tester, 'freight-drop');
      expect(find.text('8, Jalan SS2/24, Petaling Jaya'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('freight-time-withinHour')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('freight-description')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('freight-description-field')), 'Single-door fridge and 6 boxes');
      await tester.tap(find.byKey(const ValueKey('freight-description-done')));
      await tester.pumpAndSettle();
      expect(find.text('Single-door fridge and 6 boxes'), findsOneWidget);

      // The declared value, within the cap here (RM500 with none set).
      await tester.ensureVisible(find.byKey(const ValueKey('freight-declared')));
      await tester.tap(find.byKey(const ValueKey('freight-declared')));
      await tester.pumpAndSettle();
      expect(find.text('Up to RM500. Items worth more need another way to send.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('freight-amount-field')), '600');
      await tester.tap(find.byKey(const ValueKey('freight-amount-done')));
      await tester.pumpAndSettle();
      expect(find.text('The value of your items can be at most RM500 here.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('freight-amount-field')), '400');
      await tester.tap(find.byKey(const ValueKey('freight-amount-done')));
      await tester.pumpAndSettle();
      expect(find.text('RM400'), findsOneWidget);
      // The prohibited items, and the sender's word for it.
      await tester.ensureVisible(find.byKey(const ValueKey('freight-prohibited-list')));
      await tester.tap(find.byKey(const ValueKey('freight-prohibited-list')));
      await tester.pumpAndSettle();
      expect(find.text('Explosives and fireworks'), findsOneWidget);
      await tester.tap(find.text('Close').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('freight-prohibited-ack')));
      await tester.pumpAndSettle();
      // The recipient, sent the tracking link when the trip starts.
      await tester.ensureVisible(find.byKey(const ValueKey('freight-recipient')));
      await tester.tap(find.byKey(const ValueKey('freight-recipient')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('freight-recipient-name')), 'Mei');
      await tester.enterText(find.byKey(const ValueKey('freight-recipient-phone')), 'abc');
      await tester.tap(find.byKey(const ValueKey('freight-recipient-done')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a phone number, such as +60 12 345 6789.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('freight-recipient-phone')), '+60 12 345 6789');
      await tester.tap(find.byKey(const ValueKey('freight-recipient-done')));
      await tester.pumpAndSettle();
      expect(find.text('Mei · +60 12 345 6789'), findsOneWidget);

      // The sizes, with their load and load size.
      await tester.tap(find.byKey(const ValueKey('freight-vehicle')));
      await tester.pumpAndSettle();
      expect(find.text('Which vehicle suits your cargo?'), findsOneWidget);
      expect(find.text('up to 500 kg · boxes, small appliances'), findsOneWidget);
      expect(find.text('len/wid/hgt 2.0/1.4/1.3 m'), findsOneWidget);
      expect(find.text('up to 3,000 kg'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('freight-vehicle-v1')));
      await tester.pumpAndSettle();

      // What the options mean, with their charges here.
      await tester.tap(find.byKey(const ValueKey('freight-options-info')));
      await tester.pumpAndSettle();
      expect(find.text('What the options mean'), findsOneWidget);
      expect(find.text('The driver loads and carries, up to 30 kg per item'), findsOneWidget);
      expect(find.text('RM30'), findsOneWidget);
      expect(find.text('RM60'), findsOneWidget);
      expect(find.text('Free'), findsOneWidget);
      expect(find.text('Helpers and options are added to your offer.'), findsOneWidget);
      expect(unreadableTexts(tester, find.byKey(const ValueKey('freight-options-sheet'))), isEmpty);
      await tester.tap(find.text('Close').last);
      await tester.pumpAndSettle();

      // 1 helper, then 2 helpers: one helper choice. Riding along too.
      await tester.tap(find.byKey(const ValueKey('freight-option-helper-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('freight-option-helper-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('freight-option-ride-along')));
      await tester.pumpAndSettle();
      FilterChip chip(String id) => tester.widget<FilterChip>(find.byKey(ValueKey('freight-option-$id')));
      expect([chip('helper-1').selected, chip('helper-2').selected, chip('ride-along').selected], [false, true, true]);

      // Closed body: the van isn't one, so the lorry is chosen, where riding
      // along is blocked.
      await tester.tap(find.byKey(const ValueKey('freight-option-closed-body')));
      await tester.pumpAndSettle(const Duration(seconds: 5));
      expect(find.text('3-tonne lorry (L)'), findsOneWidget);
      expect(find.byKey(const ValueKey('freight-option-ride-along')), findsNothing);
      // Its note goes before the photo and the offer below it are tapped.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // The photo, uploaded into the rider's folder.
      await tester.ensureVisible(find.byKey(const ValueKey('freight-photo')));
      await tester.tap(find.byKey(const ValueKey('freight-photo')));
      await tester.pumpAndSettle();
      expect(find.text('Added'), findsOneWidget);

      // The offer, with the suggested range for the trip and the size.
      await tester.ensureVisible(find.byKey(const ValueKey('freight-offer')));
      await tester.tap(find.byKey(const ValueKey('freight-offer')));
      await tester.pumpAndSettle();
      expect(find.text('Offer your fare'), findsWidgets);
      expect(find.byKey(const ValueKey('freight-offer-hint')), findsOneWidget);
      expect(find.textContaining('for this trip and vehicle.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('freight-offer-field')), '150');
      await tester.tap(find.byKey(const ValueKey('freight-offer-done')));
      await tester.pumpAndSettle();
      expect(find.text('RM150'), findsOneWidget);
      expect(find.byKey(const ValueKey('freight-total')), findsOneWidget);
      expect(find.textContaining('Total RM210'), findsOneWidget);
      expect(unreadableTexts(tester, find.byKey(const ValueKey('freight-form'))), isEmpty);

      // Everything filled in: the button is ready and the hint is gone.
      expect(create().onPressed, isNotNull);
      expect(find.byKey(const ValueKey('freight-create-hint')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('freight-create')));
      await tester.tap(find.byKey(const ValueKey('freight-create')));
      await tester.pumpAndSettle();
      final c = rides.call(#createRequest)!;
      final a = c.namedArguments;
      expect(a[#service], '3-tonne lorry (L)');
      expect(a[#fare], 210);
      expect(a[#offerMe], isTrue);
      expect(a[#paymentMode], 'Cash');
      expect(a[#scheduleAt], isNull);
      expect(a[#cargoDescription], 'Single-door fridge and 6 boxes');
      expect(a[#cargoPhotoPath], 'rider/cargo-1.png');
      expect(a[#optionNames], {'helper-2': '2 helpers', 'closed-body': 'Closed body'});
      expect([for (final l in a[#optionCharges] as List<OptionChargeLine>) (l.kind, l.amount)], [('helper-2', 60.0)]);
      expect(a[#pickupName], '12, Jalan Ampang, Kuala Lumpur');
      expect(a[#distanceKm], 40.0);
      expect(a[#note], 'Freight: Single-door fridge and 6 boxes · 2 helpers, Closed body · Pickup within 1 hour');
      expect((a[#metadata] as Map)['country'], 'Malaysia');
      expect(a[#declaredValue], 400);
      expect(a[#prohibitedAck], isTrue);
      expect(a[#recipient], (name: 'Mei', phone: '+60 12 345 6789'));
      // Sent: My requests.
      expect(find.text('My freight requests'), findsOneWidget);
      expect(find.text('Request sent. Drivers will send you their offers.'), findsOneWidget);
    });

    testWidgets('My freight requests: the status, a driver\'s offer, accept, cancel (${b.name})', (tester) async {
      final rides = _Rides();
      await _pump(tester, const FreightScreen(initialTab: 1), _overrides(rides, mine: [_request(offer: true)]), b);
      expect(find.text('My freight requests'), findsOneWidget);
      expect(find.text('Looking for drivers'), findsOneWidget);
      expect(find.textContaining('your offer RM150.00'), findsOneWidget, reason: 'the fare less the helpers');
      expect(find.byKey(const ValueKey('freight-request-offer-f1')), findsOneWidget);
      expect(find.textContaining('Ali'), findsWidgets);
      expect(find.textContaining('RM190.00'), findsWidgets);
      expect(unreadableTexts(tester, find.byKey(const ValueKey('freight-request-f1'))), isEmpty);
      await tester.tap(find.byKey(const ValueKey('freight-request-accept-f1')));
      await tester.pumpAndSettle();
      final accept = rides.call(#acceptOffer)!;
      expect(accept.positionalArguments, ['f1']);
      expect(accept.namedArguments[#partnerId], 'driver-1');
      expect(accept.namedArguments[#amount], 190);
      await tester.tap(find.byKey(const ValueKey('freight-request-decline-f1')));
      await tester.pumpAndSettle();
      expect(rides.call(#declineOffer)?.namedArguments[#partnerId], 'driver-1');
      await tester.tap(find.byKey(const ValueKey('freight-request-cancel-f1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('freight-cancel-confirm')));
      await tester.pumpAndSettle();
      expect((rides.call(#cancel)!.positionalArguments.first as RideRequest).id, 'f1');
    });

    testWidgets('the driver\'s request: the cargo, the size, the options, the photo after accepting (${b.name})',
        (tester) async {
      final rides = _Rides();
      await _pump(
        tester,
        Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: RideRequestSheet(
              request: _request(),
              shown: Duration.zero,
              now: DateTime.now(),
              onAccept: () async {},
              onSkip: () {},
              onOffer: (_) async {},
            ),
          ),
        ),
        _overrides(rides, vehicles: const [_van]),
        b,
      );
      final view = find.byKey(const ValueKey('freight-cargo-f1'));
      expect(view, findsOneWidget);
      expect(find.text('Single-door fridge and 6 boxes'), findsOneWidget);

      expect(find.text('Van (S) · up to 500 kg · len/wid/hgt 2.0/1.4/1.3 m'), findsOneWidget);
      expect(find.byKey(const ValueKey('freight-cargo-option-helper-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('freight-cargo-option-closed-body')), findsOneWidget);
      expect(find.text('The photo shows once you accept.'), findsOneWidget);
      expect(unreadableTexts(tester, view), isEmpty);
    });
  }

  testWidgets('no freight size: the page says so and books nothing', (tester) async {
    final rides = _Rides();
    await _pump(tester, const FreightScreen(), _overrides(rides, vehicles: const []), Brightness.light);
    expect(find.text('No vehicle sizes yet'), findsOneWidget);
    expect(rides.calls.where((c) => c.memberName == #createRequest), isEmpty);
    // A ride's cargo view says nothing.
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(rides),
        child: MaterialApp(home: Scaffold(body: FreightCargoView(request: RideRequest({'id': 'r', 'status': 'open'})))),
      ),
    );
    expect(find.byType(FreightCargoView), findsOneWidget);
    expect(find.byKey(const ValueKey('freight-cargo-r')), findsNothing);
  });
}
