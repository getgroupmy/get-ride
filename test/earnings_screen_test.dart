import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/driver_earnings.dart';
import 'package:get_ride/src/core/partner_statement.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_statement_repository.dart';
import 'package:get_ride/src/features/partner/earnings_chart.dart';
import 'package:get_ride/src/features/partner/earnings_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'notice.dart';

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

List<Override> overrides({required List<RideRequest> trips, List<(String, String)>? shared, DateTime? now}) {
  // One instant for the whole test, the screen's clock included.
  final at = now ?? DateTime.now();
  return [
  currentUserIdProvider.overrideWithValue('me'),
  earningsClockProvider.overrideWithValue(() => at),
  statementSettingsProvider.overrideWith((_) async => const StatementSettings()),
  earningsTotalsProvider.overrideWith(
    (ref, period) async => period == EarningsPeriod.today
        ? (totals: _today, days: [EarningsBucket(malaysiaDate(at), _today)])
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
}

/// The server's totals and series, recording the ranges asked for.
class _Statements implements PartnerStatementRepository {
  final earningsAsked = <({DateTime from, DateTime to})>[];

  @override
  Future<StatementTotals> earnings(DateTime from, DateTime to) async {
    earningsAsked.add((from: from, to: to));
    return _today;
  }

  @override
  Future<List<EarningsBucket>> series(DateTime from, DateTime to, String bucket) async => bucket == 'day'
      // The day the server buckets the range's first moment into: Malaysia's.
      ? [EarningsBucket(malaysiaDate(from), _today)]
      : [
          for (var i = 0; i < 8; i++)
            EarningsBucket(malaysiaDate(from).add(Duration(days: 7 * i)), StatementTotals({'net': 1, 'trips': 1})),
        ];

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// An instant given as Malaysia's wall clock.
DateTime _myt(int y, int m, int d, int h, int min) => DateTime.utc(y, m, d, h, min).subtract(const Duration(hours: 8));

void main() {
  // Run under any TZ (CI checks UTC and America/Los_Angeles): the export's
  // "Today" is the totals card's day, Malaysia's, either side of midnight
  // there, whatever the device's own day is.
  for (final now in [_myt(2026, 10, 18, 23, 59), _myt(2026, 10, 19, 0, 1)]) {
    testWidgets('the export\'s Today is the totals card\'s day (${malaysiaWallClock(now)} in Malaysia, '
        'TZ ${DateTime.now().timeZoneName})', (tester) async {
      tester.view.physicalSize = const Size(420, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final statements = _Statements();
      final shared = <(String, String)>[];
      // One trip just before Malaysia's midnight, one just after.
      final trips = [
        ride('late', _myt(2026, 10, 18, 23, 50), 20, commission: 3),
        ride('early', _myt(2026, 10, 19, 0, 0), 30, commission: 4.5),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWithValue('me'),
            earningsClockProvider.overrideWithValue(() => now),
            statementSettingsProvider.overrideWith((_) async => const StatementSettings()),
            partnerStatementRepositoryProvider.overrideWithValue(statements),
            driverMonthTripsProvider.overrideWith((_) async => trips),
            earningsCsvSharerProvider.overrideWithValue((csv, name, _) async {
              shared.add((csv, name));
              return CsvShareOutcome.shared;
            }),
          ],
          child: const MaterialApp(home: EarningsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      // The totals card's day: the start of the range the server was asked
      // for, in Malaysia, and the day row it shows as "Today".
      final cardDay = malaysiaDate(statements.earningsAsked.first.from);
      expect(cardDay, malaysiaDate(now));
      expect(find.text('Today'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('earnings-export')));
      await tester.pumpAndSettle();
      String two(int n) => n.toString().padLeft(2, '0');
      final day = '${cardDay.year}-${two(cardDay.month)}-${two(cardDay.day)}';
      expect(shared.single.$2, 'earnings-today-$day.csv');
      final rows = shared.single.$1.split('\r\n').where((l) => l.isNotEmpty).skip(1).toList();
      expect(rows, hasLength(1), reason: 'only the trip of that Malaysian day');
      expect(rows.single, startsWith('$day,'));
      expect(rows.single, contains(cardDay.day == 18 ? ',20.00,3.00,17.00,MYR' : ',30.00,4.50,25.50,MYR'));
      expect(tester.takeException(), isNull);
    });
  }

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

  for (final scale in [1.0, 1.3]) {
    for (final b in Brightness.values) {
      testWidgets('the 8-week chart keeps month names under its bars at ${scale}x (${b.name})', (tester) async {
        tester.view.physicalSize = const Size(412, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final weeks = [
          for (var i = 0; i < 8; i++)
            EarningsBucket(DateTime.utc(2026, 8, 24 + 7 * i), StatementTotals({'net': 10.0 + i, 'trips': 1})),
        ];
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: b),
          home: Scaffold(body: WeeklyEarningsChart(weeks: weeks, money: (v) => 'RM$v')),
        ));
        final labels = find.byWidgetPredicate(
          (w) => w is Text && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('earnings-week-label-'),
        );
        expect(labels, findsWidgets);
        // The newest week always, with its month.
        expect(tester.widget<Text>(find.byKey(const ValueKey('earnings-week-label-7'))).data, '12 Oct');
        final card = tester.getRect(find.byKey(const ValueKey('earnings-weekly-chart')));
        for (final e in labels.evaluate()) {
          final text = (e.widget as Text).data!;
          expect(text, matches(RegExp(r'^\d{1,2} [A-Z][a-z]{2}$')), reason: 'a day with its month, never a bare day');
          final p = tester.renderObject<RenderParagraph>(find.descendant(of: find.byWidget(e.widget), matching: find.byType(RichText)));
          expect(p.didExceedMaxLines, isFalse);
          expect(p.size.width, greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity) - 0.5), reason: '"$text" is whole');
          final r = tester.getRect(find.byWidget(e.widget));
          expect(r.left, greaterThanOrEqualTo(card.left));
          expect(r.right, lessThanOrEqualTo(card.right));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  // The clock is pinned: the trips are placed against it, so the test means
  // the same at any hour. Before, "today's trip" was put at 00:05 by the
  // wall clock, and from midnight to 00:05 it lay in the future, so the
  // export (rightly) left it out and the test failed for five minutes a day.
  for (final now in [
    _myt(2026, 10, 15, 14, 30), // an ordinary afternoon (all in Malaysia's time)
    _myt(2026, 10, 19, 0, 3), // just after midnight, the old failing window; a Monday
    _myt(2026, 11, 1, 0, 3), // the 1st of a month, and a Sunday
    _myt(2026, 10, 18, 23, 58), // a Sunday night
    _myt(2026, 12, 31, 23, 59), // the last minute of the year
  ]) {
    testWidgets('weekly chart reads out the tapped week; export hands over the CSV (${malaysiaWallClock(now)} in Malaysia)', (tester) async {
      tester.view.physicalSize = const Size(420, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Today's trip a minute before the pinned now, last week's a week before.
      final today = now.subtract(const Duration(minutes: 1));
      final lastWeek = today.subtract(const Duration(days: 7));
      final shared = <(String, String)>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(
            trips: [ride('aa', today, 20, commission: 3), ride('bb', lastWeek, 50, commission: 7.5)],
            shared: shared,
            now: now,
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
      String two(int n) => n.toString().padLeft(2, '0');
      final d = malaysiaDate(now);
      expect(shared.single.$2, 'earnings-today-${d.year}-${two(d.month)}-${two(d.day)}.csv');
      expect(shared.single.$1, contains('KLCC,"Bangsar, KL"'));
      expect(shared.single.$1, contains(',20.00,3.00,17.00,MYR'));
      expect(shared.single.$1, isNot(contains(',50.00,')), reason: "last week's trip is not today's");
    });
  }

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
    await pumpNotice(tester);
    expect(find.text('No completed trips today to export.'), findsOneWidget);
  });

  // Web round 34.
  for (final b in Brightness.values) {
    testWidgets('140 addendum: at 360 wide and 1.0x every date keeps its month, none overlap (${b.name})',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final weeks = [
        for (var i = 0; i < 8; i++)
          EarningsBucket(DateTime.utc(2026, 8, 31 + 7 * i), StatementTotals({'net': 10.0 + i, 'trips': 1})),
      ];
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: b),
        home: Scaffold(body: WeeklyEarningsChart(weeks: weeks, money: (v) => 'RM$v')),
      ));
      Future<void> check() async {
        final labels = find.byWidgetPredicate(
          (w) => w is Text && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('earnings-week-label-'),
        );
        final rects = <Rect>[];
        for (final e in labels.evaluate()) {
          expect((e.widget as Text).data, matches(RegExp(r'^\d{1,2} [A-Z][a-z]{2}$')), reason: 'one format: day and month');
          final p = tester.renderObject<RenderParagraph>(find.descendant(of: find.byWidget(e.widget), matching: find.byType(RichText)));
          expect(p.size.width, greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity) - 0.5));
          rects.add(tester.getRect(find.byWidget(e.widget)));
        }
        expect(rects, isNotEmpty);
        expect(find.byKey(const ValueKey('earnings-week-label-7')), findsOneWidget, reason: 'the newest always');
        rects.sort((a, b) => a.left.compareTo(b.left));
        for (var k = 1; k < rects.length; k++) {
          expect(rects[k].left, greaterThanOrEqualTo(rects[k - 1].right), reason: 'no two dates run together');
        }
      }

      await check();
      // Tapping an older bar (bold) never changes the format or overlaps.
      await tester.tap(find.byKey(const ValueKey('earnings-week-1')));
      await tester.pump();
      await check();
      expect(tester.takeException(), isNull);
    });

    testWidgets('167: eight weeks of nothing is a header and a line, no empty chart (${b.name})', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final weeks = [
        for (var i = 0; i < 8; i++) EarningsBucket(DateTime.utc(2026, 8, 31 + 7 * i), StatementTotals.zero),
      ];
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: b),
        home: Scaffold(body: Align(alignment: Alignment.topCenter, child: WeeklyEarningsChart(weeks: weeks, money: (v) => 'RM$v'))),
      ));
      final card = find.byKey(const ValueKey('earnings-weekly-chart'));
      expect(find.text('Last 8 weeks'), findsOneWidget);
      expect(find.text('No earnings in the last 8 weeks'), findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.byWidgetPredicate((w) => w is CustomPaint && w.painter != null)),
        findsNothing,
        reason: 'no bars drawn',
      );
      expect(find.byKey(const ValueKey('earnings-week-readout')), findsNothing);
      expect(find.byKey(const ValueKey('earnings-week-0')), findsNothing);
      expect(tester.getSize(card).height, lessThan(100), reason: 'normal height, not 330');
      expect(tester.takeException(), isNull);
    });

    testWidgets('168: Trip history and receipts is a row with a chevron (${b.name})', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(trips: const []),
          child: MaterialApp(theme: ThemeData(brightness: b), home: const EarningsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('earnings-trip-history'));
      await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
      final tile = tester.widget<ListTile>(row);
      expect(tile.onTap, isNotNull);
      expect(find.descendant(of: row, matching: find.text('Trip history and receipts')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.byIcon(Icons.chevron_right)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.byIcon(Icons.receipt_long_outlined)), findsOneWidget);
      expect(find.ancestor(of: row, matching: find.byType(Card)), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Trip history and receipts'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  // Web round 43 (191, 192) at 317 wide (412 at 1.3x), light and dark.
  for (final b in Brightness.values) {
    for (final width in const [317.0, 412.0]) {
      testWidgets('191: the period picker at ${width.toInt()}: short labels only where the full ones would wrap (${b.name})',
          (tester) async {
        tester.view.physicalSize = Size(width, 704);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          ProviderScope(
            overrides: overrides(trips: const []),
            child: MaterialApp(theme: ThemeData(brightness: b), home: const EarningsScreen()),
          ),
        );
        await tester.pumpAndSettle();
        final picker = find.byKey(const ValueKey('earnings-period'));
        final short = earningsPeriodsShort(tester.element(picker), tester.getSize(picker).width);
        for (final p in EarningsPeriod.values) {
          final shown = find.descendant(of: picker, matching: find.text(short ? p.shortLabel : p.label));
          expect(shown, findsOneWidget, reason: p.name);
          final para = tester.renderObject<RenderParagraph>(find.descendant(of: shown, matching: find.byType(RichText)));
          expect(para.didExceedMaxLines, isFalse);
          expect(para.size.height, lessThan(para.getMaxIntrinsicHeight(double.infinity) * 1.5), reason: 'one line');
          // Read out in full whichever is drawn.
          expect(find.bySemanticsLabel(p.label), findsWidgets);
        }
        semantics.dispose();
      });
    }

    testWidgets('192: at 317 wide and 1.0x every chart date keeps its month, none run together (${b.name})',
        (tester) async {
      tester.view.physicalSize = const Size(317, 704);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final weeks = [
        for (var i = 0; i < 8; i++)
          EarningsBucket(DateTime.utc(2026, 8, 31 + 7 * i), StatementTotals({'net': 10.0 + i, 'trips': 1})),
      ];
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: b),
        home: Scaffold(body: WeeklyEarningsChart(weeks: weeks, money: (v) => 'RM$v')),
      ));
      final labels = find.byWidgetPredicate(
        (w) => w is Text && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('earnings-week-label-'),
      );
      final rects = <Rect>[];
      for (final e in labels.evaluate()) {
        expect((e.widget as Text).data, matches(RegExp(r'^\d{1,2} [A-Z][a-z]{2}$')), reason: 'never "21" alone');
        rects.add(tester.getRect(find.byWidget(e.widget)));
      }
      expect(rects, isNotEmpty);
      rects.sort((a, c) => a.left.compareTo(c.left));
      for (var k = 1; k < rects.length; k++) {
        expect(rects[k].left, greaterThanOrEqualTo(rects[k - 1].right));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
