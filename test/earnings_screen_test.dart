import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/partner/earnings_screen.dart';
import 'package:get_ride/src/providers.dart';

RideRequest ride(String id, DateTime completed, double fare, {double? commission}) => RideRequest({
  'id': id,
  'rider_id': 'r1',
  'partner_id': 'me',
  'status': 'completed',
  'fare': fare,
  'ride_fare': fare,
  'commission_amount': ?commission,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'Bangsar, KL',
  'created_at': completed.subtract(const Duration(minutes: 20)).toUtc().toIso8601String(),
  'completed_at': completed.toUtc().toIso8601String(),
});

void main() {
  testWidgets('weekly chart reads out the tapped week; export hands over the CSV', (tester) async {
    tester.view.physicalSize = const Size(420, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 0, 5);
    final lastWeek = today.subtract(const Duration(days: 7));
    final shared = <(String, String)>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue('me'),
          driverMonthTripsProvider.overrideWith(
            (_) async => [ride('aa', today, 20, commission: 3), ride('bb', lastWeek, 50, commission: 7.5)],
          ),
          earningsCsvSharerProvider.overrideWithValue((csv, name, _) async {
            shared.add((csv, name));
            return CsvShareOutcome.shared;
          }),
        ],
        child: const MaterialApp(home: EarningsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('earnings-weekly-chart')), findsOneWidget);
    expect(find.text('Last 8 weeks'), findsOneWidget);
    final readout = find.byKey(const ValueKey('earnings-week-readout'));
    expect(tester.widget<Text>(readout).data, contains('RM'));
    expect(tester.widget<Text>(readout).data, contains('1 trip'));
    expect(tester.widget<Text>(readout).data, contains('17.00'));

    await tester.tap(find.byKey(const ValueKey('earnings-week-6')));
    await tester.pump();
    expect(tester.widget<Text>(readout).data, contains('42.50'));

    await tester.tap(find.byKey(const ValueKey('earnings-export')));
    await tester.pumpAndSettle();
    expect(shared, hasLength(1));
    expect(shared.single.$2, startsWith('earnings-today-'));
    expect(shared.single.$1, contains('KLCC,"Bangsar, KL"'));
    expect(shared.single.$1, contains(',20.00,3.00,17.00,MYR'));
  });

  testWidgets('nothing to export says so', (tester) async {
    final shared = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue('me'),
          driverMonthTripsProvider.overrideWith((_) async => const []),
          earningsCsvSharerProvider.overrideWithValue((csv, name, _) async {
            shared.add(csv);
            return CsvShareOutcome.shared;
          }),
        ],
        child: const MaterialApp(home: EarningsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('earnings-export')));
    await tester.pump();
    expect(shared, isEmpty);
    expect(find.text('No completed trips today to export.'), findsOneWidget);
  });
}
