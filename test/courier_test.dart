// Courier (migration 0268): the vehicles from Vehicle Services under
// Courier, the parcel sizes and the vehicles that carry them, who pays, the
// confirmation code (the sender's card, the courier's dialog), the Courier
// page and My deliveries, the driver's view of the parcel, the home Couriers
// box and its admin editor ("Link to page" and what the box opens) -- light
// and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/meterapp/courier_settings_screen.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_screen.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_store.dart' show settingsEntriesProvider;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/courier.dart';
import 'package:get_ride/src/core/freight.dart';
import 'package:get_ride/src/core/home_sections.dart';
import 'package:get_ride/src/core/option_charge.dart';
import 'package:get_ride/src/core/partner_type_rules.dart' show RegionScope;
import 'package:get_ride/src/core/payment_types.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/core/ride_option_places.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/freight_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_option_places_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/ride/courier_parts.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart' show accentFill;
import 'package:get_ride/src/features/ride/courier_screen.dart';
import 'package:get_ride/src/features/ride/freight_parts.dart';
import 'package:get_ride/src/features/ride/freight_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/core/page_styles.dart';
import 'package:get_ride/src/features/ride/delivery_look.dart';
import 'package:get_ride/src/features/ride/place_search.dart' show routeSheetFill;
import 'package:get_ride/src/widgets/page_style_host.dart';
import 'package:latlong2/latlong.dart';

import 'text_contrast.dart';
import 'notice.dart';

const _walker = FreightVehicle(
  id: 'c1',
  name: 'Courier Walker',
  maxLoadKg: 5,
  lengthM: 0.3,
  widthM: 0.3,
  heightM: 0.3,
  serviceTypes: [courierServiceType],
);
const _moto = FreightVehicle(id: 'c3', name: 'Courier Motorcycle', maxLoadKg: 10, serviceTypes: [courierServiceType]);
const _car = FreightVehicle(
  id: 'c4',
  name: 'Courier Car',
  maxLoadKg: 20,
  lengthM: 0.7,
  widthM: 0.5,
  heightM: 0.5,
  serviceTypes: [courierServiceType],
);

const _place = RegionScope(country: 'Malaysia');

/// Malaysia: 5 free minutes for a courier, the cap RM300.
OptionPlaces _places() => const OptionPlaces([
  OptionPlaceSettings(
    scope: _place,
    charges: {
      CourierPlaceKey.waitFreeMin: PlaceCharge(OptionCharge(value: 5)),
      CourierPlaceKey.declaredCap: PlaceCharge(OptionCharge(value: 300)),
    },
  ),
]);

class _Rides implements RideRepository {
  final calls = <Invocation>[];

  Invocation? call(Symbol name) => calls.where((c) => c.memberName == name).lastOrNull;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation);
    switch (invocation.memberName) {
      case #createRequest:
        return Future<Booked>.value((now: RideRequest({'id': 'new', 'status': 'open'}), later: null));
      case #acceptOffer:
        return Future<RideRequest?>.value(RideRequest({'id': 'k1', 'status': 'accepted'}));
      case #declineOffer:
      case #cancel:
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

RideRequest _delivery({String status = 'open', bool offer = false, bool recipientPays = true, String? codeOk}) =>
    RideRequest({
      'id': 'k1',
      'rider_id': 'rider',
      'status': status,
      'service': 'Courier Motorcycle',
      'fare': 12,
      'ride_fare': 12,
      'currency': 'MYR',
      'offer_me': true,
      'pickup_name': 'Eco Majestic',
      'drop_name': 'Pavilion Kuala Lumpur',
      'pickup_lat': 2.93,
      'pickup_lng': 101.84,
      'drop_lat': 3.149,
      'drop_lng': 101.713,
      'payment_mode': 'Cash',
      'cargo_description': 'Documents',
      'parcel_size': 'S',
      'payer': recipientPays ? 'recipient' : 'sender',
      'delivery_code_ok_at': ?codeOk,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      if (offer) 'offered_fare': 14,
      if (offer) 'partner_id': 'driver-1',
      if (offer) 'partner_name': 'Ali',
    });

Future<Place?> _search(BuildContext context, {required String title, LatLng? near, bool onMap = false}) async =>
    title == 'Where to pick up'
        ? const Place(name: 'Eco Majestic', address: 'Eco Majestic, Semenyih', point: LatLng(2.93, 101.84))
        : const Place(name: 'Pavilion Kuala Lumpur', address: 'Bukit Bintang', point: LatLng(3.149, 101.713));

List<Override> _overrides(
  _Rides rides, {
  List<RideRequest> mine = const [],
  List<FreightVehicle> vehicles = const [_walker, _moto, _car],
  CourierConfig config = const CourierConfig(),
  String? code = '4817',
  Future<String> Function(String, String)? check,
}) => [
  rideRepositoryProvider.overrideWithValue(rides),
  courierVehiclesProvider.overrideWith((ref) async => vehicles),
  freightVehiclesProvider.overrideWith((ref) async => const []),
  courierConfigProvider.overrideWith((ref) async => config),
  freightConfigProvider.overrideWith((ref) async => const FreightConfig()),
  displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
  rideOptionPlacesProvider.overrideWith((ref) async => _places()),
  fareTariffsProvider.overrideWith((ref) async => const []),
  serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
  paymentChoicesProvider.overrideWith(
    (ref) async => const [PaymentChoice('Get Pay', 'GET.wallet', PaymentKind.wallet), PaymentChoice('Cash', 'Cash', PaymentKind.cash)],
  ),
  myCourierRequestsProvider.overrideWith((ref) => Stream.value(mine)),
  myFreightRequestsProvider.overrideWith((ref) => Stream.value(const [])),
  courierDeliveryCodeProvider.overrideWith((ref, id) async => code),
  courierCodeCheckProvider.overrideWithValue(check ?? (id, c) async => c == '4817' ? 'ok' : 'wrong_code'),
  deviceBlockedProvider.overrideWith((ref) async => false),
  profileProvider.overrideWith((ref) async => null),
  freightPlaceSearchProvider.overrideWithValue(_search),
  freightPickupContextProvider.overrideWithValue(
    (p) async => (area: const AreaInfo(country: 'Malaysia'), place: _place, pricing: RegionPricing.none, timezone: null),
  ),
  freightRouteProvider.overrideWithValue((a, b) async => (km: 30.0, min: 45.0)),
  pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
];

Future<void> _pump(WidgetTester tester, Widget home, List<Override> overrides, Brightness b) async {
  tester.view.physicalSize = const Size(420, 1600);
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

Future<void> _tap(WidgetTester tester, String key) async {
  // A message from the last step is closed first, as the user would.
  await closeAnyNotice(tester);
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

void main() {
  group('pure', () {
    test('the vehicles: active Vehicle Services under Courier, not Freight or rides', () {
      final entries = [
        (id: 'a', values: <String, dynamic>{'name': 'Ride', 'serviceTypes': ['Car']}),
        (id: 'b', values: <String, dynamic>{'name': 'Van', 'serviceTypes': ['Freight'], 'maxLoadKg': 500}),
        (id: 'c', values: <String, dynamic>{
          'name': 'Courier Walker', 'serviceTypes': [' courier '], 'maxLoadKg': 5, 'loadLengthM': 0.3,
          'loadWidthM': 0.3, 'loadHeightM': 0.3, 'displayPriority': 2,
        }),
        (id: 'd', values: <String, dynamic>{'name': 'Courier Car', 'serviceTypes': ['Courier'], 'status': false}),
      ];
      final courier = freightVehiclesFrom(entries, kind: DeliveryKind.courier);
      expect([for (final v in courier) v.id], ['c'], reason: 'the inactive car is left out');
      expect(courier.single.shortName, 'Walker');
      expect(courier.single.sizeText, '30 x 30 x 30 cm');
      expect(courier.single.loadText, 'up to 5 kg');
      expect([for (final v in freightVehiclesFrom(entries)) v.id], ['b'], reason: 'freight stays freight');
      expect(deliveryKindOfValues(entries[2].values), DeliveryKind.courier);
      expect(deliveryKindOfValues(entries[1].values), DeliveryKind.freight);
      expect(deliveryKindOfValues(entries[0].values), isNull);
      expect(isCourierService(courier.single.service), isTrue);
      expect(isFreightService(courier.single.service), isFalse);
      expect(const FreightVehicle(id: 'v', name: 'Van (S)').shortName, 'Van (S)');
      expect(courierAvailable(courier), isTrue);
      expect(courierAvailable(const []), isFalse);
    });

    test('parcel sizes: only the vehicles that carry them', () {
      const c = CourierConfig();
      expect([for (final v in courierVehiclesFor(const [_walker, _moto, _car], ParcelSize.s, c)) v.id], ['c1', 'c3', 'c4']);
      expect([for (final v in courierVehiclesFor(const [_walker, _moto, _car], ParcelSize.m, c)) v.id], ['c4']);
      expect([for (final v in courierVehiclesFor(const [_walker, _moto, _car], ParcelSize.l, c)) v.id], ['c4']);
      final lighter = c.copyWith(parcelKg: {ParcelSize.m: 8});
      expect([for (final v in courierVehiclesFor(const [_walker, _moto, _car], ParcelSize.m, lighter)) v.id], ['c3', 'c4']);
      expect(parcelSizeText(ParcelSize.l, c), 'L · up to 20 kg');
      expect(ParcelSize.byId('m'), ParcelSize.m);
      expect(ParcelSize.byId('XL'), isNull);
    });

    test('the Courier settings: read within bounds, written in order', () {
      final c = CourierConfig.fromJson({
        'codeChannels': ['whatsapp', 'fax', 'sms'],
        'cancelApproveMinutes': 500,
        'parcelSizes': {'S': 3, 'M': 5000, 'L': '20'},
        'prohibitedItems': ['Explosives', ' '],
      });
      expect(c.codeChannels, {'whatsapp', 'sms'});
      expect(c.cancelApproveMinutes, 60);
      expect([c.kgOf(ParcelSize.s), c.kgOf(ParcelSize.m), c.kgOf(ParcelSize.l)], [3, 15, 20]);
      expect(c.prohibitedItems, ['Explosives']);
      expect(c.senderSeesCode, isFalse);
      expect(c.toJson()['codeChannels'], ['sms', 'whatsapp']);
      expect(CourierConfig.fromJson({'codeChannels': []}).codeChannels, {'sender'}, reason: 'someone gets the code');
      expect(const CourierConfig(codeChannels: {'sender'}).senderSeesCode, isTrue);
      expect(const CourierConfig().messageChannels, {'sms'});
      expect(courierCodeHelp(const CourierConfig()), startsWith('We also send it to the recipient by SMS.'));
      expect(courierCodeHelp(const CourierConfig(codeChannels: {'sender'})), startsWith('Give this code to the recipient.'));
    });

    test('the draft, what is sent and the columns', () {
      const c = CourierConfig();
      const ready = CourierDraft(
        pickup: true,
        drop: true,
        size: ParcelSize.s,
        vehicle: _walker,
        recipientPhone: '+60 12 345 6789',
        declaredValue: 100,
        prohibitedAck: true,
        offer: 8,
      );
      expect(courierDraftProblem(ready, c), isNull);
      expect(courierDraftProblem(const CourierDraft(), c), 'Add where to pick up.');
      expect(
        courierDraftProblem(const CourierDraft(pickup: true, drop: true, size: ParcelSize.m, vehicle: _walker, recipientPhone: '0123456789'), c),
        'This parcel is too heavy for a Walker.',
      );
      expect(courierDraftProblem(const CourierDraft(pickup: true, drop: true), c), "Add the recipient's phone number.");
      expect(courierItemText(['Food', 'Documents'], ' fragile '), 'Food, Documents. fragile');
      expect(courierItemText(const [], ''), 'Parcel');
      expect(toggleCourierItem(toggleCourierItem(const [], 'Food'), 'Food'), isEmpty);
      expect(courierRequestColumns(size: ParcelSize.l, payer: CourierPayer.recipient), {'parcel_size': 'L', 'payer': 'recipient'});
      expect(courierNote(items: 'Food', size: ParcelSize.s, payer: CourierPayer.recipient),
          'Courier: Food · Size S · Recipient pays cash');
      expect(CourierPayer.of('recipient'), CourierPayer.recipient);
      expect(CourierPayer.of(null), CourierPayer.sender);
    });

    test('the code: what the server answers, for the courier', () {
      expect(courierCodeMessage('ok'), isNull);
      expect(courierCodeMessage('wrong_code'), "That code isn't right. Ask the recipient again.");
      expect(courierCodeMessage('rate_limited:90'), 'Too many tries. Try again in 2 min.');
      expect(courierCodeOk('4817'), isTrue);
      expect(courierCodeOk('48a7'), isFalse);
      expect(courierStatusLabel('open'), 'Looking for couriers');
      expect(deliveryStatusLabel(DeliveryKind.freight, 'open'), 'Looking for drivers');
    });

    test('courier waiting, cancel fee and cap, by place', () {
      final v = freightPlaceValues(_places(), const RegionScope(country: 'Malaysia', city: 'Kuala Lumpur'),
          kind: DeliveryKind.courier);
      expect(v, (waitFreeMin: 5.0, waitPerMin: 0.0, cancelFee: 0.0, declaredCap: 300.0));
      expect(freightPlaceValues(OptionPlaces.none, RegionScope.all, kind: DeliveryKind.courier),
          (waitFreeMin: 10.0, waitPerMin: 0.0, cancelFee: 0.0, declaredCap: 500.0));
      expect(freightPlaceValues(_places(), _place).waitFreeMin, 20, reason: 'freight keeps its own');
      expect(deliveryPlaceMax(CourierPlaceKey.declaredCap), OptionChargeKey.freightDeclaredCapMax);
      final parsed = OptionPlaceSettings.fromRow({
        'level': 'country',
        'country': 'Malaysia',
        'charges': {'courier-declared-cap': {'value': 50000}},
      });
      expect(parsed.charges['courier-declared-cap']?.charge.value, 50000, reason: 'over an option charge\'s most');
    });

    test('the home Couriers box opens the Courier page only with a vehicle', () {
      final s = {
        'serviceBoxes': [
          {'name': 'Groceries'},
          {'name': 'City rides'},
          {'name': 'City to City'},
          {'comingSoon': true},
          {'name': 'Freight'},
        ],
      };
      var boxes = serviceBoxViews(s);
      expect(boxes[3].title, 'Couriers');
      expect(boxes[3].courier, isTrue);
      expect(boxes[3].route, isNull);
      expect(boxes[3].badge, 'SOON');
      boxes = serviceBoxViews(s, courierAvailable: true);
      expect(boxes[3].route, courierPageRoute);
      expect(boxes[4].route, isNull, reason: 'Freight still waits for its own');
      expect(serviceBoxDelivery(route: '/courier', title: 'Send'), DeliveryKind.courier);
      expect(serviceBoxDelivery(route: null, title: 'Box', linked: 'Courier'), DeliveryKind.courier);
      expect(serviceBoxDelivery(route: null, title: 'Freight'), DeliveryKind.freight);
      expect(serviceBoxDelivery(route: '/wallet', title: 'Wallet'), isNull);
    });

    test('Admin: the Freight and Courier pages in "Link to page", and what a box opens', () {
      expect(allAppRoutes, containsAll(['/freight', '/courier']));
      expect(routeLabel('/freight'), 'Freight');
      expect(routeLabel('/courier'), 'Courier');
      expect(
        serviceBoxOpensText(route: null, title: 'Box 5', linked: 'Freight'),
        'Freight page — opens once a Vehicle Service under Freight is active (none yet)',
      );
      expect(
        serviceBoxOpensText(route: '/courier', title: 'Send', active: {DeliveryKind.courier: 2}),
        'Courier page — opens once a Vehicle Service under Courier is active (2 active)',
      );
      expect(serviceBoxOpensText(route: null, title: 'Box 1'), 'Nothing yet — shows Coming Soon');
      expect(serviceBoxOpensText(route: '/wallet', title: 'Wallet'), 'Wallet');
    });
  });

  for (final b in Brightness.values) {

    testWidgets('the page in the app\'s look, and the admin\'s App Page Settings (${b.name})', (tester) async {
      Color? fill(Finder f) =>
          tester.widget<Material>(find.descendant(of: f, matching: find.byType(Material)).first).color;
      Material boxOf(String key) =>
          tester.widget<Material>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Material)).first);

      // Nothing set: "Find a driver"'s blue button, the route sheet's grey
      // boxes, the home vehicle bar's chosen colour.
      await _pump(tester, const CourierScreen(), _overrides(_Rides()), b);
      final button = find.byKey(const ValueKey('courier-create'));
      final style = tester.widget<FilledButton>(button).style;
      expect(style?.backgroundColor?.resolve({}), accentFill, reason: 'the ride flow\'s request blue');
      expect(style?.foregroundColor?.resolve({}), Colors.white);
      expect(tester.getSize(button).height, 52, reason: 'the theme\'s button height');
      final ctx = tester.element(find.byKey(const ValueKey('courier-pickup')));
      expect(boxOf('courier-pickup').color, routeSheetFill(Theme.of(ctx)));
      final look = DeliveryLook.of(ctx);
      expect(look.chosen, b == Brightness.dark ? const Color(0xFF2B2E8C) : const Color(0xFFD8EEFB));
      expect(Theme.of(ctx).brightness, b);
      expect(fill(button), isNot(accentFill), reason: 'greyed out while the form is empty');
      // The chosen size: the chosen colour, its words readable on it.
      expect(boxOf('courier-size-S').color, look.chosen);
      expect(unreadableTexts(tester, find.byKey(const ValueKey('courier-form'))), isEmpty);

      // The admin's values for the page.
      const field = Color(0xFF334455), chosen = Color(0xFF225588);
      await _pump(
        tester,
        PageStyleScope(
          styles: PageStyles({
            'page:ride.courier': {
              'fieldColor': styleHex(field),
              'fieldColor.dark': styleHex(field),
              'chosenColor': styleHex(chosen),
              'chosenColor.dark': styleHex(chosen),
              'buttonHeight': 60,
              'inputRadius': 20,
            },
          }),
          child: SurfaceFrame(id: 'page:ride.courier', child: const CourierScreen()),
        ),
        _overrides(_Rides()),
        b,
      );
      expect(tester.getSize(find.byKey(const ValueKey('courier-create'))).height, 60);
      expect(boxOf('courier-pickup').color, field);
      expect(boxOf('courier-pickup').borderRadius, BorderRadius.circular(20));
      expect(DeliveryLook.of(tester.element(find.byKey(const ValueKey('courier-pickup')))).chosen, chosen);
    });
    testWidgets('the Courier page: fill it in, size, vehicle, recipient pays, find a courier (${b.name})', (tester) async {
      final rides = _Rides();
      await _pump(tester, const CourierScreen(), _overrides(rides), b);
      expect(find.text('Courier'), findsWidgets);
      expect(find.text('Send a parcel'), findsOneWidget);
      // Nothing filled in: the button waits, and says what is missing first.
      FilledButton create() => tester.widget<FilledButton>(find.byKey(const ValueKey('courier-create')));
      expect(create().onPressed, isNull);
      expect(find.byKey(const ValueKey('courier-create-hint')), findsOneWidget);
      expect(find.text('Add where to pick up.'), findsOneWidget);

      await _tap(tester, 'courier-pickup');
      expect(find.text('Eco Majestic'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('courier-pickup-details')), 'Block B, unit 3');
      await _tap(tester, 'courier-drop');
      expect(find.text('Pavilion Kuala Lumpur'), findsOneWidget);

      // The recipient's phone is needed.
      await _tap(tester, 'courier-recipient');
      await tester.tap(find.byKey(const ValueKey('freight-recipient-done')));
      await tester.pumpAndSettle();
      expect(find.text("Enter the recipient's phone number."), findsOneWidget);
      expect(find.textContaining('the confirmation code when the courier picks up'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('freight-recipient-name')), 'Mei');
      await tester.enterText(find.byKey(const ValueKey('freight-recipient-phone')), '+60 12 345 6789');
      await tester.tap(find.byKey(const ValueKey('freight-recipient-done')));
      await tester.pumpAndSettle();
      expect(find.text('Mei · +60 12 345 6789'), findsOneWidget);

      // S: every vehicle; M: only the car.
      expect(find.byKey(const ValueKey('courier-vehicle-c1')), findsOneWidget);
      expect(find.text('Walker'), findsOneWidget);
      expect(find.text('up to 5 kg · 30 x 30 x 30 cm'), findsOneWidget);
      await _tap(tester, 'courier-size-M');
      expect(find.byKey(const ValueKey('courier-vehicle-c1')), findsNothing);
      expect(find.byKey(const ValueKey('courier-vehicle-c3')), findsNothing);
      expect(find.byKey(const ValueKey('courier-vehicle-c4')), findsOneWidget);
      expect(find.textContaining('~ RM'), findsOneWidget, reason: 'the estimate for the trip');

      await _tap(tester, 'courier-item-Documents');
      await tester.enterText(find.byKey(const ValueKey('courier-note')), 'fragile');

      await _tap(tester, 'courier-declared');
      await tester.enterText(find.byKey(const ValueKey('freight-amount-field')), '400');
      await tester.tap(find.byKey(const ValueKey('freight-amount-done')));
      await tester.pumpAndSettle();
      expect(find.text('The value of your items can be at most RM300 here.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('freight-amount-field')), '200');
      await tester.tap(find.byKey(const ValueKey('freight-amount-done')));
      await tester.pumpAndSettle();
      await _tap(tester, 'courier-prohibited-ack');

      // The recipient pays in cash: no payment to choose.
      expect(find.byKey(const ValueKey('courier-payment-Cash')), findsOneWidget);
      await _tap(tester, 'courier-payer-recipient');
      expect(find.byKey(const ValueKey('courier-payment-Cash')), findsNothing);
      expect(find.text('Cash to the courier when the parcel arrives. You pay nothing now.'), findsOneWidget);

      await _tap(tester, 'courier-offer');
      expect(find.text('Offer your price'), findsWidgets);
      expect(find.text('Helpers and options are added to your offer.'), findsNothing);
      final hint = tester.widget<Text>(find.byKey(const ValueKey('freight-offer-hint'))).data!;
      final low = RegExp(r'RM(\d+)').firstMatch(hint)!.group(1)!;
      await tester.enterText(find.byKey(const ValueKey('freight-offer-field')), low);
      await tester.tap(find.byKey(const ValueKey('freight-offer-done')));
      await tester.pumpAndSettle();
      expect(unreadableTexts(tester, find.byKey(const ValueKey('courier-form'))), isEmpty);

      // Everything filled in: the button is ready and the hint is gone.
      expect(create().onPressed, isNotNull);
      final ready = find.descendant(of: find.byKey(const ValueKey('courier-create')), matching: find.byType(Material));
      expect(tester.widget<Material>(ready.first).color, accentFill, reason: 'the ride flow\'s request blue');
      expect(find.byKey(const ValueKey('courier-create-hint')), findsNothing);
      await _tap(tester, 'courier-create');
      final a = rides.call(#createRequest)!.namedArguments;
      expect(a[#service], 'Courier Car');
      expect(a[#parcelSize], ParcelSize.m);
      expect(a[#payer], CourierPayer.recipient);
      expect(a[#paymentMode], 'Cash', reason: 'cash, though GET.wallet is listed first');
      expect(a[#cargoDescription], 'Documents. fragile');
      expect(a[#declaredValue], 200);
      expect(a[#prohibitedAck], isTrue);
      expect(a[#recipient], (name: 'Mei', phone: '+60 12 345 6789'));
      expect(a[#offerMe], isTrue);
      expect(a[#fare], double.parse(low));
      expect(a[#note], 'Courier: Documents. fragile · Size M · Recipient pays cash · Pickup: Block B, unit 3');
      expect(find.text('My deliveries'), findsWidgets);
      expect(find.text('Request sent. Couriers will send you their offers.'), findsOneWidget);
    });

    testWidgets('My deliveries: the offer card, the code to pass on, who pays (${b.name})', (tester) async {
      final rides = _Rides();
      await _pump(tester, const CourierScreen(initialTab: 1), _overrides(rides, mine: [_delivery(offer: true)]), b);
      expect(find.text('Looking for couriers'), findsOneWidget);
      expect(find.byKey(const ValueKey('courier-request-offer-k1')), findsOneWidget);
      expect(find.textContaining('Motorcycle · your offer'), findsOneWidget);
      expect(find.text('Recipient pays RM12.00 in cash on delivery.'), findsOneWidget);
      expect(find.byKey(const ValueKey('courier-code-card')), findsOneWidget);
      for (final d in ['4', '8', '1', '7']) {
        expect(find.text(d), findsWidgets);
      }
      expect(unreadableTexts(tester, find.byKey(const ValueKey('courier-request-k1'))), isEmpty);
      await tester.tap(find.byKey(const ValueKey('courier-request-accept-k1')));
      await tester.pumpAndSettle();
      expect(rides.call(#acceptOffer)?.namedArguments[#partnerId], 'driver-1');
      await tester.tap(find.byKey(const ValueKey('courier-request-cancel-k1')));
      await tester.pumpAndSettle();
      expect(find.text('Couriers will no longer see it or send offers.'), findsOneWidget);
    });

    testWidgets('the courier: the parcel, the cash to collect, the code at drop-off (${b.name})', (tester) async {
      final rides = _Rides();
      final tries = <String>[];
      await _pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => Column(children: [
              FreightCargoView(request: _delivery(status: 'on_trip'), title: 'Parcel'),
              FilledButton(
                key: const ValueKey('open-code'),
                onPressed: () => showDialog<bool>(context: context, builder: (_) => const CourierCodeDialog(rideId: 'k1')),
                child: const Text('Code'),
              ),
            ]),
          ),
        ),
        _overrides(rides, vehicles: const [_moto], check: (id, c) async {
          tries.add(c);
          return c == '4817' ? 'ok' : (tries.length > 1 ? 'rate_limited:300' : 'wrong_code');
        }),
        b,
      );
      expect(find.text('Motorcycle · up to 10 kg'), findsOneWidget);
      expect(find.text('Parcel S · up to 5 kg'), findsOneWidget);
      expect(find.text('Collect RM12.00 in cash from the recipient.'), findsOneWidget);
      expect(unreadableTexts(tester, find.byKey(const ValueKey('freight-cargo-k1'))), isEmpty);
      await _tap(tester, 'open-code');
      expect(find.text('Enter the confirmation code'), findsOneWidget);
      final confirm = find.byKey(const ValueKey('courier-code-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull, reason: 'four digits first');
      await tester.enterText(find.byKey(const ValueKey('courier-code-field')), '1234');
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(find.text("That code isn't right. Ask the recipient again."), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('courier-code-field')), '4817');
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('courier-code-dialog')), findsNothing, reason: 'taken: the dialog closes');
      expect(tries, ['1234', '4817']);
    });

    testWidgets('the sender: the code while it is theirs, then "confirmed" (${b.name})', (tester) async {
      final rides = _Rides();
      await _pump(
        tester,
        Scaffold(body: Column(children: [CourierCodeCard(request: _delivery(status: 'on_trip'))])),
        _overrides(rides, config: const CourierConfig(codeChannels: {'sms'}), code: null),
        b,
      );
      expect(find.byKey(const ValueKey('courier-code-card')), findsNothing);
      expect(find.text('We send it to the recipient by SMS. The courier enters it to finish the delivery.'), findsOneWidget);
      await _pump(
        tester,
        Scaffold(body: Column(children: [CourierCodeCard(request: _delivery(status: 'completed', codeOk: '2026-10-22T10:00:00Z'))])),
        _overrides(rides),
        b,
      );
      expect(find.text('The courier confirmed the code. Delivered.'), findsOneWidget);
    });

    testWidgets('Admin: Courier settings, code channels and parcel sizes (${b.name})', (tester) async {
      final saved = <CourierConfig>[];
      final repo = _Repo(saved);
      await _pump(
        tester,
        const CourierSettingsScreen(),
        [
          freightRepositoryProvider.overrideWithValue(repo),
          courierConfigProvider.overrideWith((ref) async => saved.isEmpty ? const CourierConfig() : saved.last),
          pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
        ],
        b,
      );
      expect(find.text('Confirmation code'), findsOneWidget);
      expect(find.text('SMS to the recipient'), findsOneWidget);
      expect(find.text('up to 15 kg'), findsOneWidget);
      await _tap(tester, 'courier-channel-whatsapp');
      expect(saved.last.codeChannels, {'sms', 'sender', 'whatsapp'});
      await _tap(tester, 'courier-size-M');
      await tester.enterText(find.byKey(const ValueKey('courier-size-kg-field')), '12');
      await tester.tap(find.byKey(const ValueKey('courier-size-kg-save')));
      await tester.pumpAndSettle();
      expect(saved.last.kgOf(ParcelSize.m), 12);
      expect(unreadableTexts(tester, find.byKey(const ValueKey('courier-settings-code'))), isEmpty);
    });

    testWidgets('Admin: a home box links to the Freight page and says what it opens (${b.name})', (tester) async {
      final settings = <String, dynamic>{
        'serviceBoxes': [
          {}, {}, {},
          {'comingSoon': true},
          {'serviceId': 'svc-freight'},
        ],
      };
      await _pump(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: Column(children: [
              ServiceBoxCard(settings: settings, index: 3, canEdit: true),
              ServiceBoxCard(settings: settings, index: 4, canEdit: true),
            ]),
          ),
        ),
        [
          settingsEntriesProvider('service-settings').overrideWith(
            (ref) async => [
              {'id': 'svc-freight', 'values': {'name': 'Freight'}},
            ],
          ),
          settingsEntriesProvider('vehicle-services').overrideWith(
            (ref) async => [
              {'id': 'w', 'values': {'name': 'Courier Walker', 'serviceTypes': ['Courier'], 'status': true}},
              {'id': 'c', 'values': {'name': 'Courier Car', 'serviceTypes': ['Courier'], 'status': false}},
            ],
          ),
          pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
        ],
        b,
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('box-opens-3'))).data,
        'Courier page — opens once a Vehicle Service under Courier is active (1 active)',
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('box-opens-4'))).data,
        'Freight page — opens once a Vehicle Service under Freight is active (none yet)',
        reason: 'linked to the Freight service',
      );
      // "Link to page": searching /freight finds the Freight page.
      // The tile spins while the sheet is open: pumped, not settled.
      Future<void> settle() async {
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.tap(find.byKey(const ValueKey('box-opens-4')));
      await settle();
      await tester.enterText(find.widgetWithText(TextField, 'Search pages'), '/freight');
      await settle();
      expect(find.widgetWithText(ListTile, '/freight'), findsOneWidget);
      expect(find.descendant(of: find.widgetWithText(ListTile, '/freight'), matching: find.text('Freight')), findsOneWidget,
          reason: 'labelled Freight');
      expect(find.text('/courier'), findsNothing);
      await tester.enterText(find.widgetWithText(TextField, 'Search pages'), 'courier');
      await settle();
      expect(find.text('/courier'), findsOneWidget);
    });
  }
}

class _Repo implements FreightRepository {
  _Repo(this.saved);
  final List<CourierConfig> saved;

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #saveCourierConfig) {
      saved.add(i.positionalArguments.first as CourierConfig);
      return Future<CourierConfig>.value(saved.last);
    }
    return super.noSuchMethod(i);
  }
}
