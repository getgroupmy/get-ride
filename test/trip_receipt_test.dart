import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/trip_receipt.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/trip_receipt_screen.dart';
import 'package:get_ride/src/providers.dart';

const _rider = '11111111-1111-1111-1111-111111111111';
const _driver = '22222222-2222-2222-2222-222222222222';

RideRequest trip({String status = 'completed', double? tolls, double? other, String? reason}) => RideRequest({
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
}
