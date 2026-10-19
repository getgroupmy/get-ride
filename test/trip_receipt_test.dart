import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/trip_receipt.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/trip_receipt_screen.dart';
import 'package:get_ride/src/widgets/pdf_actions.dart';
import 'package:get_ride/src/widgets/ride_map.dart' show PickupPin, openingView;
import 'package:get_ride/src/providers.dart';
import 'package:latlong2/latlong.dart';

const _rider = '11111111-1111-1111-1111-111111111111';
const _driver = '22222222-2222-2222-2222-222222222222';

RideRequest trip({
  String status = 'completed',
  double? tolls,
  double? other,
  String? reason,
  Map<String, dynamic> extra = const {},
}) => RideRequest({
  'id': 'a1b2c3d4-e5f6-7890-abcd-ef0123456789',
  'rider_id': _rider,
  'rider_name': 'Aina',
  'partner_id': _driver,
  'partner_name': 'Ali',
  'partner_vehicle': 'Proton Saga',
  'partner_plate': 'WXY 1234',
  'status': status,
  'fare': 20,
  'ride_fare': 22.5,
  'toll_charges': tolls,
  'other_charges': other,
  'currency': 'MYR',
  'payment_mode': 'Cash',
  'service': 'GET Car',
  'distance_km': 8.4,
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'created_at': '2026-10-05T01:00:00Z',
  'started_at': '2026-10-05T01:10:00Z',
  'completed_at': '2026-10-05T01:34:00Z',
  'cancelled_at': status == 'cancelled' ? '2026-10-05T01:05:00Z' : null,
  'cancel_reason': reason,
  ...extra,
});

void main() {
  test('booking numbers are stable and derived from the id', () {
    expect(tripBookingNo('a1b2c3d4-e5f6-7890-abcd-ef0123456789'), 'GR-A1B2C3D4');
    expect(tripBookingNo('abc'), 'GR-ABC');
  });

  test('a completed trip bills the trip fare plus recorded charges', () {
    final rc = TripReceipt.fromRide(trip(tolls: 3.1, other: 2));
    expect(rc.lines.map((l) => l.label), ['Trip fare', 'Tolls', 'Other charges']);
    expect(rc.total, closeTo(27.6, 1e-9));
    expect(rc.tripMinutes, 24);
    expect(rc.details, contains(('Driver', 'Ali')));
    expect(rc.details, contains(('Vehicle', 'Proton Saga · WXY 1234')));
    expect(rc.text, contains('Total: RM27.60'));
  });

  test('the driver copy names the passenger; a cancelled trip charges nothing', () {
    final driver = TripReceipt.fromRide(trip(), asDriver: true);
    expect(driver.details, contains(('Passenger', 'Aina')));
    expect(driver.details.any((d) => d.$1 == 'Vehicle'), isFalse);

    final cancelled = TripReceipt.fromRide(trip(status: 'cancelled', reason: 'Changed plans'));
    expect(cancelled.charged, isFalse);
    expect(cancelled.total, 0);
    expect(cancelled.details, contains(('Reason', 'Changed plans')));
    expect(cancelled.text, contains('No charge'));
  });

  test('the PDF renders', () async {
    final bytes = await buildTripReceiptPdf(TripReceipt.fromRide(trip(tolls: 1)));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  testWidgets('the receipt screen shows the total and the driver', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue(_rider),
          tripProvider.overrideWith((ref, id) async => trip(tolls: 2.5)),
        ],
        child: const MaterialApp(home: TripReceiptScreen(requestId: 'x')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('RM25.00'), findsWidgets);
    expect(find.text('GR-A1B2C3D4'), findsWidgets);
    expect(find.text('Ali'), findsOneWidget);
    expect(find.byKey(const ValueKey('receipt-print')), findsOneWidget);
    // One PDF button, which asks whether to share or download.
    expect(find.text('Share PDF'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('receipt-pdf')));
    // The button spins while the sheet is open, so it never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('pdf-actions')), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-share')), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-download')), findsOneWidget);
    // Dismissed: nothing is built or sent.
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('pdf-actions')), findsNothing);
  });

  testWidgets('the booking ID at the top copies on a tap; no Copy button', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue(_rider),
          tripProvider.overrideWith((ref, id) async => trip()),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: const TripReceiptScreen(requestId: 'x'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsNothing);
    expect(find.byKey(const ValueKey('receipt-print')), findsOneWidget);
    expect(find.byKey(const ValueKey('receipt-pdf')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('receipt-copy-booking-id')));
    await tester.pump();
    expect(copied, 'GR-A1B2C3D4');
    expect(find.text('Booking ID copied'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('the share-or-download sheet answers the choice (${dark ? 'dark' : 'light'})', (tester) async {
      PdfAction? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () async => picked = await askPdfAction(c, title: 'Receipt GR-1'),
              child: const Text('PDF'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('PDF'));
      await tester.pumpAndSettle();
      expect(find.text('Receipt GR-1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pdf-download')));
      await tester.pumpAndSettle();
      expect(picked, PdfAction.download);
      await tester.tap(find.text('PDF'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pdf-share')));
      await tester.pumpAndSettle();
      expect(picked, PdfAction.share);
    });
  }

  test("the driver's copy shows the commission and what they keep", () {
    final charged = TripReceipt.fromRide(
      trip(tolls: 3, extra: {'commission_rate': 0.15, 'commission_amount': 3.38, 'fare_coins_value': 5}),
      asDriver: true,
    );
    expect(charged.gross, 25.5, reason: 'fare and tolls; coins still reach the driver');
    expect(charged.commissionLabel, 'Commission (15%)');
    expect(charged.earnings, closeTo(22.12, 1e-9));
    expect(charged.text, contains('You earn: RM22.12'));

    final pending = TripReceipt.fromRide(trip(), asDriver: true);
    expect(pending.commission, isNull);
    expect(pending.earnings, 22.5);
    expect(TripReceipt.fromRide(trip(extra: {'commission_rate': 0.125}), asDriver: true).commissionLabel,
        'Commission (12.5%)');

    final rider = TripReceipt.fromRide(trip(extra: {'commission_amount': 3.38}));
    expect(rider.commission, isNull, reason: "the passenger's copy never shows it");
    expect(rider.text, isNot(contains('You earn')));
  });

  testWidgets("the driver's receipt screen shows their earnings", (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue(_driver),
          tripProvider.overrideWith(
            (ref, id) async => trip(extra: {'commission_rate': 0.2, 'commission_amount': 4.5}),
          ),
        ],
        child: const MaterialApp(home: TripReceiptScreen(requestId: 'x')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Commission (20%)'), findsOneWidget);
    expect(find.text('−RM4.50'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('receipt-earnings')), matching: find.text('RM18.00')),
        findsOneWidget);
  });

  test('the receipt map runs pickup, stops, drop-off, and needs both ends', () {
    final ends = {'pickup_lat': 3.15, 'pickup_lng': 101.71, 'drop_lat': 3.13, 'drop_lng': 101.68};
    expect(receiptRoute(trip(extra: ends)), const [LatLng(3.15, 101.71), LatLng(3.13, 101.68)]);
    expect(
      receiptRoute(trip(extra: {
        ...ends,
        'stops': [
          {'name': 'Bangsar', 'lat': 3.14, 'lng': 101.67},
        ],
      })),
      const [LatLng(3.15, 101.71), LatLng(3.14, 101.67), LatLng(3.13, 101.68)],
    );
    // No drop-off (cancelled before one was set): the pickup alone.
    expect(receiptRoute(trip(extra: {'pickup_lat': 3.15, 'pickup_lng': 101.71})), const [LatLng(3.15, 101.71)]);
    expect(receiptRoute(trip()), isEmpty);
  });

  test('the receipt map frames a city trip at street level, not the whole valley', () {
    const route = [LatLng(3.1579, 101.7123), LatLng(3.1340, 101.6860)];
    // As the card lays it out: 360 wide, 200 high, the slim margins.
    final view = openingView(
      route,
      route,
      const Size(360, receiptMapHeight),
      top: receiptMapMargin,
      bottom: receiptMapMargin - 64,
    );
    // With the map's usual 64 all round it was about 11.6 (the valley).
    final before = openingView(route, route, const Size(360, receiptMapHeight));
    expect(view.zoom, greaterThan(before.zoom + 0.5));
    expect(view.zoom, greaterThanOrEqualTo(12.5));
  });

  testWidgets("a cancelled trip's receipt has no time under its ends; a completed one says what it is", (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<void> open(RideRequest r) async {
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            currentUserIdProvider.overrideWithValue(_rider),
            tripProvider.overrideWith((ref, id) async => r),
          ],
          child: const MaterialApp(home: TripReceiptScreen(requestId: 'x')),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    await open(trip(status: 'cancelled', extra: {'pickup_lat': 3.15, 'pickup_lng': 101.71}));
    expect(find.byKey(const ValueKey('receipt-picked-up')), findsNothing);
    expect(find.textContaining(RegExp(r'^\d{1,2}:\d{2} [AP]M$')), findsNothing);
    expect(find.byKey(const ValueKey('receipt-map')), findsOneWidget, reason: 'the pickup at street level');
    await open(trip());
    expect(tester.widget<Text>(find.byKey(const ValueKey('receipt-picked-up'))).data, startsWith('Picked up '));
  });

  testWidgets('the receipt shows the trip on a map when both ends are known', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<void> open(RideRequest r) async {
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            currentUserIdProvider.overrideWithValue(_rider),
            tripProvider.overrideWith((ref, id) async => r),
          ],
          child: const MaterialApp(home: TripReceiptScreen(requestId: 'x')),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    await open(trip(extra: {'pickup_lat': 3.15, 'pickup_lng': 101.71, 'drop_lat': 3.13, 'drop_lng': 101.68}));
    expect(find.byKey(const ValueKey('receipt-map')), findsOneWidget);
    await open(trip());
    expect(find.byKey(const ValueKey('receipt-map')), findsNothing);
  });

  // Desktop 138: the pickup pin stands whole inside the map card at 390 px.
  for (final b in Brightness.values) {
    testWidgets('138: at 390 wide the pickup pin is wholly inside the receipt map (${b.name})', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Pickup north of the drop-off: its pin stands at the top edge.
      for (final ends in [
        {'pickup_lat': 3.158, 'pickup_lng': 101.712, 'drop_lat': 3.134, 'drop_lng': 101.686},
        {'pickup_lat': 3.20, 'pickup_lng': 101.60, 'drop_lat': 3.05, 'drop_lng': 101.75},
      ]) {
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: [
              currentUserIdProvider.overrideWithValue(_rider),
              tripProvider.overrideWith((ref, id) async => trip(extra: ends)),
            ],
            child: MaterialApp(theme: ThemeData(brightness: b), home: const TripReceiptScreen(requestId: 'x')),
          ),
        );
        await tester.pump();
        await tester.pump();
        final card = tester.getRect(find.byKey(const ValueKey('receipt-map')));
        final pin = tester.getRect(find.byType(PickupPin));
        expect(pin.top, greaterThanOrEqualTo(card.top), reason: 'the head, not only its base');
        expect(pin.bottom, lessThanOrEqualTo(card.bottom));
        expect(pin.left, greaterThanOrEqualTo(card.left));
        expect(pin.right, lessThanOrEqualTo(card.right));
        expect(tester.takeException(), isNull);
      }
    });
  }

  test('a trip the driver ended early says so, at the fare it was stored at', () {
    final early = TripReceipt.fromRide(trip(extra: {'ride_fare': 9.4, 'ended_early_at': '2026-10-05T01:20:00Z'}));
    expect(early.statusLabel, 'Ended early');
    expect(early.total, 9.4);
    expect(TripReceipt.fromRide(trip()).statusLabel, 'Completed');
  });

  test('platform fees come off the driver\'s earnings as on the statement', () {
    expect(platformFeesOf([
      {'charge': 'fixed', 'value': 2.5, 'platform': true},
      {'charge': 'fixed', 'value': 1, 'platform': false},
      {'charge': 'percent', 'value': 10, 'platform': true},
    ]), 2.5);
    expect(platformFeesOf(null), 0);
  });
}
