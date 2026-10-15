import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/driver_earnings.dart';
import 'package:get_ride/src/core/partner_statement.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_statement_repository.dart';
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

/// The server's totals for today: fare 20 with SST 1.20 and a toll of 3
/// (collected for others), commission 3, an incentive of 5.
const _today = StatementTotals({
  'trips': 1,
  'fare': 20,
  'surcharges': 0,
  'platformCollected': 0,
  'incentives': 5,
  'handoverIn': 0,
  'totalEarnings': 25,
  'commission': 3,
  'platformFees': 0,
  'handoverOut': 0,
  'totalDeductions': 3,
  'adjustments': 0,
  'net': 22,
  'taxes': 1.2,
  'tolls': 3,
  'passThrough': 4.2,
  'onlineHours': 6.5,
  'distanceKm': 12.4,
});

List<Override> overrides({required List<RideRequest> trips, List<(String, String)>? shared}) => [
  currentUserIdProvider.overrideWithValue('me'),
  statementSettingsProvider.overrideWith((_) async => const StatementSettings()),
  earningsTotalsProvider.overrideWith(
    (ref, period) async => period == EarningsPeriod.today
        ? (totals: _today, days: [EarningsBucket(malaysiaDate(DateTime.now()), _today)])
        : (totals: StatementTotals.zero, days: const <EarningsBucket>[]),
  ),
  earningsWeeksProvider.overrideWith(
    (_) async => [
      for (var i = 0; i < 8; i++)
        EarningsBucket(
          DateTime.utc(2026, 8, 24 + 7 * i),
          StatementTotals({'net': i == 7 ? 22 : (i == 6 ? 42.5 : 0), 'trips': i >= 6 ? 1 : 0}),
        ),
    ],
  ),
  driverMonthTripsProvider.overrideWith((_) async => trips),
  earningsCsvSharerProvider.overrideWithValue((csv, name, _) async {
    shared?.add((csv, name));
    return CsvShareOutcome.shared;
  }),
];

void main() {
  for (final dark in [false, true]) {
    testWidgets('server totals: taxes and tolls apart from what was earned (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(trips: const []),
          child: MaterialApp(theme: dark ? ThemeData.dark() : ThemeData.light(), home: const EarningsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(find.byKey(const ValueKey('earnings-net'))).data, contains('22.00'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('earnings-fares'))).data, contains('20.00'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('earnings-incentives'))).data, contains('5.00'));
      expect(find.byKey(const ValueKey('earnings-statements')), findsOneWidget);
      // Taxes sit under "Collected for others", folded until opened.
      expect(find.textContaining('Collected for others'), findsOneWidget);
      expect(find.byKey(const ValueKey('earnings-taxes')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('earnings-pass-through')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('earnings-taxes'))).data, contains('1.20'));
      expect(find.text('Today'), findsNWidgets(2), reason: 'the period button and the day');
    });
  }

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
        overrides: overrides(
          trips: [ride('aa', today, 20, commission: 3), ride('bb', lastWeek, 50, commission: 7.5)],
          shared: shared,
        ),
        child: const MaterialApp(home: EarningsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('earnings-weekly-chart')), findsOneWidget);
    expect(find.text('Last 8 weeks'), findsOneWidget);
    final readout = find.byKey(const ValueKey('earnings-week-readout'));
    expect(tester.widget<Text>(readout).data, contains('RM'));
    expect(tester.widget<Text>(readout).data, contains('1 trip'));
    expect(tester.widget<Text>(readout).data, contains('22.00'));

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
    final shared = <(String, String)>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(trips: const [], shared: shared),
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
