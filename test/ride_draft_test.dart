import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ride_draft.dart';
import 'package:get_ride/src/core/ride_rebook.dart';
import 'package:get_ride/src/core/saved_drafts.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/features/ride/welcome_back_sheet.dart';
import 'package:latlong2/latlong.dart';

const _a = Place(name: 'Jalan Ampang', address: 'Kuala Lumpur', point: LatLng(3.16, 101.72));
const _b = Place(name: 'KLCC', address: 'Kuala Lumpur', point: LatLng(3.158, 101.712));
const _stop = Place(name: 'Pavilion', address: 'Bukit Bintang', point: LatLng(3.149, 101.713));

void main() {
  final now = DateTime(2026, 10, 26, 12);

  group('saved booking', () {
    test('reads back what was saved', () {
      final d = rideDraftOf(
        pickup: _a,
        drop: _b,
        stops: const [_stop],
        now: now,
        service: 'Ride',
        fare: 18,
        payment: 'Cash',
        forName: ' Mum ',
        forPhone: '0123456789',
        currency: 'MYR',
      )!;
      final back = RideDraft.decode(d.encode())!;
      expect(back.savedAt, now);
      expect(back.trip.pickup.name, 'Jalan Ampang');
      expect(back.trip.drop.point, _b.point);
      expect(back.trip.stops.single.name, 'Pavilion');
      expect(back.trip.service, 'Ride');
      expect(back.trip.fare, 18);
      expect(back.trip.payment, 'Cash');
      expect(back.trip.forName, 'Mum');
      expect(back.trip.forPhone, '0123456789');
      expect(back.currency, 'MYR');
    });

    test('nothing to save without both ends, or while a place is still being looked up', () {
      expect(rideDraftOf(pickup: _a, drop: null, stops: const [], now: now), isNull);
      expect(rideDraftOf(pickup: null, drop: _b, stops: const [], now: now), isNull);
      const looking = Place.suggestion(name: 'KLCC', address: '', placeId: 'x');
      expect(rideDraftOf(pickup: _a, drop: looking, stops: const [], now: now), isNull);
      expect(rideDraftOf(pickup: _a, drop: _b, stops: const [looking], now: now)!.trip.stops, isEmpty);
    });

    test('a broken or foreign entry is dropped, never shown', () {
      for (final raw in [null, '', 'not json', '[]', '{}', '{"saved_at":"x","pickup":{},"drop":{}}']) {
        expect(RideDraft.decode(raw), isNull, reason: '$raw');
      }
    });

    test('offered for 30 minutes, not after, and not from the future', () {
      RideDraft at(Duration ago) => RideDraft(savedAt: now.subtract(ago), trip: const RideRebook(pickup: _a, drop: _b));
      expect(freshRideDraft(at(const Duration(minutes: 29)), now), isNotNull);
      expect(freshRideDraft(at(rideDraftKeep), now), isNotNull);
      expect(freshRideDraft(at(const Duration(minutes: 31)), now), isNull);
      expect(freshRideDraft(at(const Duration(minutes: -5)), now), isNull);
      expect(freshRideDraft(null, now), isNull);
    });

    test('the line says what and when', () {
      RideDraft d(Duration ago, {String? forName}) =>
          RideDraft(savedAt: now.subtract(ago), trip: RideRebook(pickup: _a, drop: _b, forName: forName));
      expect(rideDraftLine(d(const Duration(minutes: 6)), now), 'You were booking a ride 6 min ago.');
      expect(rideDraftLine(d(const Duration(seconds: 20)), now), 'You were booking a ride just now.');
      expect(rideDraftLine(d(const Duration(minutes: 2), forName: 'Mum'), now), 'You were booking a ride for Mum 2 min ago.');
    });
  });

  group('Welcome back sheet', () {
    for (final b in Brightness.values) {
      testWidgets('shows the trip and both choices (${b.name})', (tester) async {
        bool? result;
        final draft = RideDraft(
          savedAt: now.subtract(const Duration(minutes: 6)),
          currency: 'MYR',
          trip: const RideRebook(pickup: _a, drop: _b, stops: [_stop], service: 'Ride', fare: 18),
        );
        await tester.pumpWidget(MaterialApp(
          theme: appTheme(b),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async => result = await showWelcomeBackSheet(context, draft, now: now),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('Welcome back'), findsOneWidget);
        expect(find.text('You were booking a ride 6 min ago.'), findsOneWidget);
        expect(find.text('Jalan Ampang'), findsOneWidget);
        expect(find.text('KLCC'), findsOneWidget);
        expect(find.text('1 stop on the way'), findsOneWidget);
        expect(find.text('Ride'), findsOneWidget);
        expect(find.textContaining('18.00'), findsOneWidget);
        expect(tester.getSize(find.byKey(const ValueKey('welcome-back-continue'))).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(find.byKey(const ValueKey('welcome-back-start-over'))).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const ValueKey('welcome-back-continue')));
        await tester.pumpAndSettle();
        expect(result, isTrue);

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('welcome-back-start-over')));
        await tester.pumpAndSettle();
        expect(result, isFalse);
      });
    }
  });

  group('Freight, Courier and vehicle drafts', () {
    SavedDraft at(SavedDraftKind k, Map<String, Object?> data, {Duration ago = const Duration(minutes: 20)}) =>
        SavedDraft(kind: k, savedAt: now.subtract(ago), data: data);

    test('read back, and offered for 30 minutes', () {
      final d = at(SavedDraftKind.freight, {'pickup': draftAddressToJson(_a, '12, Jalan Ampang'), 'offer': 180});
      final back = SavedDraft.decode(SavedDraftKind.freight, d.encode())!;
      expect(back.data['offer'], 180);
      expect(draftAddressFromJson(back.data['pickup'])!.details, '12, Jalan Ampang');
      expect(draftAddressFromJson(back.data['pickup'])!.place.name, 'Jalan Ampang');
      expect(back.freshAt(now), isTrue);
      expect(at(SavedDraftKind.courier, const {}, ago: const Duration(minutes: 31)).freshAt(now), isFalse);
      expect(SavedDraft.decode(SavedDraftKind.courier, 'broken'), isNull);
      expect(SavedDraftKind.vehicle.key('me'), 'vehicle_draft_me');
    });

    test('what the sheet says for each', () {
      final freight = draftSummary(
        at(SavedDraftKind.freight, {
          'pickup': draftAddressToJson(_a, ''),
          'drop': draftAddressToJson(_b, ''),
          'vehicle_name': '1-tonne lorry',
        }),
        now,
      );
      expect(freight.line, 'You were booking a Freight move 20 min ago.');
      expect(freight.detail, '1-tonne lorry · Jalan Ampang to KLCC');
      expect((freight.go, freight.other), ('Continue booking', 'Start over'));

      final courier = draftSummary(at(SavedDraftKind.courier, {'size': 'm', 'drop': draftAddressToJson(_b, '')}), now);
      expect(courier.line, 'You were sending a parcel 20 min ago.');
      expect(courier.detail, 'Size M · to KLCC');

      final vehicle = draftSummary(at(SavedDraftKind.vehicle, {'id': 'v1', 'plate': 'WXY 1234', 'next': 'Documents'}), now);
      expect(vehicle.line, 'You were adding a vehicle 20 min ago.');
      expect(vehicle.detail, 'WXY 1234 · Documents next');
      expect((vehicle.go, vehicle.other), ('Continue adding', 'Not now'));
    });

    for (final b in Brightness.values) {
      testWidgets('the sheet for a vehicle being added (${b.name})', (tester) async {
        bool? result;
        final d = at(SavedDraftKind.vehicle, {'id': 'v1', 'plate': 'WXY 1234', 'next': 'Documents'});
        await tester.pumpWidget(MaterialApp(
          theme: appTheme(b),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => result = await showWelcomeBackSaved(context, d, now: now),
                child: const Text('open'),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('You were adding a vehicle 20 min ago.'), findsOneWidget);
        expect(find.text('WXY 1234 · Documents next'), findsOneWidget);
        expect(find.text('It stays in My vehicles either way.'), findsOneWidget);
        expect(find.text('Pickup'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Not now'));
        await tester.pumpAndSettle();
        expect(result, isFalse);
      });
    }
  });
}
