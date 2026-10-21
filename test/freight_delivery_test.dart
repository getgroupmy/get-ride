// Freight after booking (migration 0267): the waiting time and its fee by
// place, the proof of delivery (the driver's photos, the sender's
// signature), the driver's cancel after pickup that the sender answers, the
// Freight settings (cancel time, the recipient's link channels, prohibited
// items), the goods-vehicle permit on a freight size -- light and dark.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/catalogue/catalogue_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/freight_settings_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/freight.dart';
import 'package:get_ride/src/core/option_charge.dart';
import 'package:get_ride/src/core/partner_type_rules.dart' show RegionScope;
import 'package:get_ride/src/core/ride_option_places.dart';
import 'package:get_ride/src/data/freight_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/photo_picker.dart';
import 'package:get_ride/src/data/ride_option_places_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/ride/freight_parts.dart';
import 'package:get_ride/src/providers.dart';

import 'text_contrast.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

const _my = RegionScope(country: 'Malaysia');

OptionPlaces _places() => const OptionPlaces([
  OptionPlaceSettings(
    scope: _my,
    charges: {
      FreightPlaceKey.waitFreeMin: PlaceCharge(OptionCharge(value: 15)),
      FreightPlaceKey.waitPerMin: PlaceCharge(OptionCharge(value: 1)),
      FreightPlaceKey.cancelArrived: PlaceCharge(OptionCharge(value: 20)),
    },
  ),
]);

/// Every call the screens make to the freight repository, kept.
class _Freight implements FreightRepository {
  final calls = <Invocation>[];
  FreightConfig saved = const FreightConfig();

  @override
  dynamic noSuchMethod(Invocation i) {
    calls.add(i);
    switch (i.memberName) {
      case #setProof:
      case #notifyRecipient:
        return Future<void>.value();
      case #saveConfig:
        saved = i.positionalArguments.first as FreightConfig;
        return Future<FreightConfig>.value(saved);
      case #config:
        return Future<FreightConfig>.value(saved);
      case #notices:
        return Future<List<Map<String, dynamic>>>.value(const []);
    }
    return super.noSuchMethod(i);
  }
}

class _Rides implements RideRepository {
  final calls = <Invocation>[];

  @override
  dynamic noSuchMethod(Invocation i) {
    calls.add(i);
    if (i.memberName == #cancel) return Future<void>.value();
    return super.noSuchMethod(i);
  }
}

final _arrived = DateTime.utc(2026, 10, 21, 9);

RideRequest _ride(String status, {Map<String, Object?> extra = const {}}) => RideRequest({
  'id': 'f1',
  'rider_id': 'rider',
  'partner_id': 'driver',
  'status': status,
  'service': 'Van (S)',
  'fare': 180,
  'currency': 'MYR',
  'country': 'Malaysia',
  'cargo_description': 'Sofa',
  'arrived_at': _arrived.toIso8601String(),
  ...extra,
});

List<Override> _overrides(_Freight freight, _Rides rides) => [
  freightRepositoryProvider.overrideWithValue(freight),
  rideRepositoryProvider.overrideWithValue(rides),
  rideOptionPlacesProvider.overrideWith((ref) async => _places()),
  freightVehiclesProvider.overrideWith((ref) async => const []),
  freightConfigProvider.overrideWith((ref) async => freight.saved),
  photoCameraAvailableProvider.overrideWithValue(false),
  photoPickerProvider.overrideWithValue((_) async => (bytes: _png, name: 'proof.png')),
  freightProofUploadProvider.overrideWithValue((bytes, name, kind) async => 'driver/$kind-1.png'),
  pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
];

Future<void> _pump(WidgetTester tester, Widget body, List<Override> overrides, Brightness b) async {
  tester.view.physicalSize = const Size(420, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: overrides,
      child: MaterialApp(theme: appTheme(b), home: Scaffold(body: SingleChildScrollView(child: body))),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('pure', () {
    test('waiting: free minutes, then a fee a minute, by place', () {
      final v = freightPlaceValues(_places(), const RegionScope(country: 'Malaysia', state: 'Selangor'));
      expect(v, (waitFreeMin: 15.0, waitPerMin: 1.0, cancelFee: 20.0, declaredCap: 500.0));
      final none = freightPlaceValues(OptionPlaces.none, RegionScope.all);
      expect(none, (waitFreeMin: 20.0, waitPerMin: 0.0, cancelFee: 0.0, declaredCap: 500.0), reason: 'nothing set');
      expect(freightWaitingFee(const Duration(minutes: 14, seconds: 59), v), 0);
      expect(freightWaitingFee(const Duration(minutes: 27, seconds: 30), v), 12);
      expect(freightTimerText(const Duration(minutes: 3, seconds: 7)), '03:07');
      expect(freightWaitingRule(v, (x) => 'RM${trimNumber(x)}'), '15 min free, then RM1 a minute');
      expect(freightWaitingRule(none, (x) => 'RM$x'), '20 min free');
    });

    test('the declared value cap can be over an option charge\'s most', () {
      final row = OptionPlaceSettings.fromRow({
        'level': 'country',
        'country': 'Malaysia',
        'charges': {
          FreightPlaceKey.declaredCap: {'kind': 'fixed', 'value': 50000},
          'helper-1': {'kind': 'fixed', 'value': 50000},
        },
      });
      expect(row.charges[FreightPlaceKey.declaredCap]!.charge.value, 50000);
      expect(row.charges['helper-1']!.charge.value, OptionCharge.maxAmount);
      String m(double v) => 'RM${trimNumber(v)}';
      expect(declaredValueProblem(null, 500, m), 'Enter the value of your items.');
      expect(declaredValueProblem(600, 500, m), 'The value of your items can be at most RM500 here.');
      expect(declaredValueProblem(500, 500, m), isNull);
      expect(recipientPhoneOk('+60 12-345 6789'), isTrue);
      expect(recipientPhoneOk('call me'), isFalse);
      expect(freightProofPath('u', 'proof-pickup', 'x', ''), 'u/proof-pickup-x.jpg');
    });

    test('the Freight settings, as stored', () {
      expect(FreightConfig.fromJson(null).cancelApproveMinutes, 5);
      expect(FreightConfig.fromJson(null).recipientChannels, {'sms'});
      expect(FreightConfig.fromJson(null).prohibitedItems, FreightConfig.defaultProhibitedItems);
      final c = FreightConfig.fromJson({
        'cancelApproveMinutes': 99,
        'recipientChannels': ['whatsapp', 'fax'],
        'prohibitedItems': ['Explosives', ' '],
      });
      expect([c.cancelApproveMinutes, c.recipientChannels, c.prohibitedItems], [60, {'whatsapp'}, ['Explosives']]);
      expect(c.toJson(), {
        'cancelApproveMinutes': 60,
        'recipientChannels': ['whatsapp'],
        'prohibitedItems': ['Explosives'],
      });
      expect(withProhibitedItem(['Explosives'], ' explosives '), ['Explosives'], reason: 'once, whatever the case');
      expect(withProhibitedItem(['Explosives'], 'Live animals'), ['Explosives', 'Live animals']);
    });

    test('Vehicle Services: the goods-vehicle permit a freight size asks for', () {
      ValuesResult build(String? permit, {Map<String, dynamic>? existing}) => buildVehicleServiceValues(
        text: const {'name': 'Van (S)'},
        numbers: const {'costPerKm': '2', 'costPerMin': '0.3', 'minFareAmount': '20'},
        serviceTypes: const ['Freight'],
        fuel: const [],
        status: true,
        goodsPermit: permit,
        existing: existing,
      );
      final r = build(' goods-vehicle ');
      expect(r.values[goodsPermitKey], 'goods-vehicle');
      expect(build('', existing: r.values).values.containsKey(goodsPermitKey), isFalse);
      expect(build(null, existing: r.values).values[goodsPermitKey], 'goods-vehicle', reason: 'not on the form: kept');
    });
  });

  for (final b in Brightness.values) {
    testWidgets('the driver: waiting timer, the pickup photo, then asking to cancel (${b.name})', (tester) async {
      final freight = _Freight(), rides = _Rides();
      await _pump(
        tester,
        FreightDriverPanel(request: _ride('arrived'), clock: () => _arrived.add(const Duration(minutes: 18, seconds: 5))),
        _overrides(freight, rides),
        b,
      );
      expect(find.text('Waiting 18:05'), findsOneWidget);
      expect(find.text('15 min free, then RM1 a minute · RM3 so far'), findsOneWidget);
      expect(find.byKey(const ValueKey('freight-proof-pickup-state')), findsOneWidget);
      expect(unreadableTexts(tester, find.byType(FreightDriverPanel)), isEmpty);
      await tester.tap(find.byKey(const ValueKey('freight-proof-pickup-take')));
      await tester.pumpAndSettle();
      final set = freight.calls.firstWhere((c) => c.memberName == #setProof);
      expect(set.positionalArguments, ['f1', 'pickup_proof_path', 'driver/proof-pickup-1.png']);

      // On the way: the drop-off photo, and the sender is asked to cancel.
      await _pump(
        tester,
        FreightDriverPanel(request: _ride('on_trip', extra: {'freight_waiting_fee': 3, 'freight_waiting_minutes': 18})),
        _overrides(freight, rides),
        b,
      );
      expect(find.byKey(const ValueKey('freight-proof-dropoff-take')), findsOneWidget);
      expect(find.text('Waiting 18 min: + RM3 on the fare'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('freight-driver-cancel')));
      await tester.pumpAndSettle();
      expect(find.textContaining("If they don't answer in 5 min"), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('freight-driver-cancel-confirm')));
      await tester.pumpAndSettle();
      final cancel = rides.calls.firstWhere((c) => c.memberName == #cancel);
      expect(cancel.namedArguments[#by], 'partner');
    });

    testWidgets('the sender: the proof, and signing at drop-off (${b.name})', (tester) async {
      final freight = _Freight(), rides = _Rides();
      await _pump(
        tester,
        FreightSenderPanel(request: _ride('on_trip')),
        _overrides(freight, rides),
        b,
      );
      expect(find.text('Proof of delivery'), findsOneWidget);
      expect(find.text('Not yet'), findsNWidgets(3));
      expect(unreadableTexts(tester, find.byType(FreightSenderPanel)), isEmpty);
      await tester.tap(find.byKey(const ValueKey('freight-sign')));
      await tester.pumpAndSettle();
      expect(find.text('Sign for the delivery'), findsWidgets);
      FilledButton save() => tester.widget<FilledButton>(find.byKey(const ValueKey('signature-save')));
      expect(save().onPressed, isNull, reason: 'nothing drawn yet');
      await tester.drag(find.byKey(const ValueKey('signature-pad')), const Offset(120, 30));
      await tester.pumpAndSettle();
      expect(save().onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('signature-clear')));
      await tester.pumpAndSettle();
      expect(save().onPressed, isNull);
    });
  }

  testWidgets('the signature pad gives a PNG', (tester) async {
    final key = GlobalKey<SignaturePadState>();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SignaturePad(key: key, onChanged: (_) {}))),
    );
    expect(await tester.runAsync(() => key.currentState!.png()), isNull, reason: 'nothing drawn');
    await tester.drag(find.byKey(const ValueKey('signature-pad')), const Offset(100, 20));
    await tester.pump();
    final png = await tester.runAsync(() => key.currentState!.png());
    expect(png, isNotNull);
    expect(png!.sublist(1, 4), utf8.encode('PNG'));
  });

  testWidgets('a sender with the proofs in: no sign button', (tester) async {
    final freight = _Freight(), rides = _Rides();
    await _pump(
      tester,
      FreightSenderPanel(
        request: _ride('completed', extra: {
          'pickup_proof_path': 'driver/proof-pickup-1.png',
          'dropoff_proof_path': 'driver/proof-dropoff-1.png',
          'delivery_signature_path': 'rider/signature-1.png',
        }),
      ),
      [..._overrides(freight, rides), freightCargoPhotoUrlProvider.overrideWith((ref, path) => Completer<String>().future)],
      Brightness.light,
    );
    expect(find.text('Added'), findsNWidgets(3));
    expect(find.byKey(const ValueKey('freight-sign')), findsNothing);
  });

  for (final b in Brightness.values) {
    testWidgets('admin Freight settings: cancel time, the link\'s channels, prohibited items (${b.name})', (tester) async {
      final freight = _Freight(), rides = _Rides();
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: _overrides(freight, rides),
          child: MaterialApp(theme: appTheme(b), home: const FreightSettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('5 min'), findsOneWidget);
      expect(find.text('Explosives and fireworks'), findsOneWidget);
      expect(unreadableTexts(tester, find.byType(FreightSettingsScreen)), isEmpty);
      await tester.tap(find.byKey(const ValueKey('freight-cancel-minutes-up')));
      await tester.pumpAndSettle();
      expect(freight.saved.cancelApproveMinutes, 6);
      await tester.tap(find.byKey(const ValueKey('freight-channel-whatsapp')));
      await tester.pumpAndSettle();
      expect(freight.saved.recipientChannels, {'sms', 'whatsapp'});
      await tester.enterText(find.byKey(const ValueKey('freight-prohibited-new')), 'Batteries');
      await tester.tap(find.byKey(const ValueKey('freight-prohibited-add')));
      await tester.pumpAndSettle();
      expect(freight.saved.prohibitedItems.last, 'Batteries');
    });
  }
}
