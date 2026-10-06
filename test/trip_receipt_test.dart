import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/trip_receipt.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/trip_receipt_screen.dart';
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
  });

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
    expect(receiptRoute(trip(extra: {'pickup_lat': 3.15, 'pickup_lng': 101.71})), isEmpty);
    expect(receiptRoute(trip()), isEmpty);
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
}
