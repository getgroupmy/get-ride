// Admin > Reports (migration 0280), the page: ask in plain words, what the
// AI understood, the chart and the table with its total, the downloads,
// saved reports with their email schedules, and the states when the AI or
// the email isn't set up, in light and dark.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel, adminModules, reportsPage;
import 'package:get_ride/src/admin/admin_providers.dart' show moduleAccessProvider;
import 'package:get_ride/src/admin/screens/reports/report_export.dart';
import 'package:get_ride/src/admin/screens/reports/report_schedule_page.dart';
import 'package:get_ride/src/admin/screens/reports/reports_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ai_report.dart';
import 'package:get_ride/src/data/ai_report_repository.dart';

final _now = DateTime.utc(2026, 10, 23, 2);

final _catalogue = ReportCatalogue.fromJson({
  'datasets': [
    {
      'id': 'rides',
      'label': 'Rides',
      'about': 'Every ride request',
      'time': 'created_at',
      'list': ['created_at', 'status'],
      'fields': [
        {'id': 'status', 'label': 'Status', 'type': 'text'},
        {'id': 'city', 'label': 'City', 'type': 'text'},
        {'id': 'created_at', 'label': 'Booked', 'type': 'time'},
        {'id': 'fare', 'label': 'Fare (RM)', 'type': 'number'},
      ],
      'hidden': ['Rider name'],
    },
  ],
  'scope': {'scoped': false, 'edit': true},
});

const _plan = ReportPlan(
  dataset: 'rides',
  groupBy: ['city'],
  measures: [ReportMeasure.count, ReportMeasure('fare', 'sum')],
  sort: [ReportSort('sum_fare', descending: true)],
  period: ReportPeriod.preset('last_30_days', field: 'created_at'),
);

ReportResult _resultFor(ReportPlan p) => ReportResult.fromJson({
  'dataset': 'rides',
  'dataset_label': 'Rides',
  'columns': [
    {'id': 'city', 'label': 'City', 'type': 'text', 'role': 'group', 'field': 'city'},
    {'id': 'count', 'label': 'Count', 'type': 'number', 'role': 'measure', 'field': '*', 'agg': 'count'},
    {'id': 'sum_fare', 'label': 'Total fare (RM)', 'type': 'number', 'role': 'measure', 'field': 'fare', 'agg': 'sum'},
  ],
  'rows': [
    ['Kajang', 212, 4812.4],
    ['Semenyih', 160, 3420],
  ],
  'totals': [372, 8232.4],
  'row_count': 2,
  'max_rows': 50000,
  'period': {'from': '2026-09-24', 'to': '2026-10-23', 'preset': 'last_30_days'},
  'hidden': ['Rider name'],
  'plan': p.toJson(),
});

class _FakeRepo extends AiReportRepository {
  _FakeRepo() : super(null);
  final asked = <String>[];
  final ran = <ReportPlan>[];
  final savedSchedules = <ReportSchedule>[];
  String? askReason;

  @override
  Future<AskAnswer> ask(String request) async {
    asked.add(request);
    return askReason == null ? (plan: _plan, reason: null) : (plan: null, reason: askReason);
  }

  @override
  Future<ReportResult> run(ReportPlan plan) async {
    ran.add(plan);
    return _resultFor(plan);
  }

  @override
  Future<List<ReportAdmin>> admins() async => const [(id: 'a1', name: 'Aina', email: 'aina@example.com')];

  @override
  Future<void> saveSchedule(ReportSchedule s, {bool isNew = false}) async => savedSchedules.add(s);
}

final _saved = SavedReport(id: 'r1', name: 'Weekly commission by service', plan: _plan);
final _schedule = ReportSchedule.fromJson({
  'id': 's1',
  'saved_id': 'r1',
  'frequency': 'weekly',
  'at_time': '08:00:00',
  'weekdays': [1],
  'period': {'preset': 'previous_week'},
  'emails': ['boss@example.com'],
  'formats': ['csv', 'xlsx'],
  'next_run_at': '2026-10-26T00:00:00Z',
  'last_status': 'failed',
  'last_error': "Email isn't set up yet: add the email key in API Keys.",
});

Future<_FakeRepo> _pump(
  WidgetTester tester,
  Brightness b, {
  ReportServices services = const ReportServices(aiReady: true, emailReady: true, emailKeySet: true, senderOk: true),
  List<(String, Uint8List)>? files,
  AccessLevel level = AccessLevel.edit,
}) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repo = _FakeRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        moduleAccessProvider.overrideWith((ref, module) => level),
        aiReportRepositoryProvider.overrideWithValue(repo),
        reportCatalogueProvider.overrideWith((ref) async => _catalogue),
        reportServicesProvider.overrideWith((ref) async => services),
        savedReportsProvider.overrideWith((ref) async => [_saved]),
        reportSchedulesProvider.overrideWith((ref) async => [_schedule]),
        reportClockProvider.overrideWithValue(() => _now),
        reportFileSaverProvider.overrideWithValue((bytes, name, mime, _) async {
          files?.add((name, bytes));
          return ReportFileOutcome.downloaded;
        }),
      ],
      child: MaterialApp(theme: appTheme(b), home: const AdminReportsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  test('the PDF: made from the table, with more rows than it lists said so', () async {
    final big = ReportResult.fromJson({
      'dataset_label': 'Rides',
      'columns': [
        {'id': 'city', 'label': 'City', 'type': 'text', 'role': 'group'},
        {'id': 'count', 'label': 'Count', 'type': 'number', 'role': 'measure'},
      ],
      'rows': [for (var i = 0; i < 2100; i++) ['Kota $i 新', i]],
      'totals': [42],
      'row_count': 2100,
      'plan': {'dataset': 'rides'},
    });
    final pdf = await buildReportPdf(big, title: 'Rides by city', period: 'Last week', madeAt: '2026-10-23 10:00');
    expect(String.fromCharCodes(pdf.sublist(0, 5)), '%PDF-');
    expect(pdf.length, greaterThan(10000));
  });

  test('Reports is an admin module of its own page', () {
    expect(adminModules['reports']?.pages, [reportsPage]);
    expect(reportsPage, 'admin-reports');
  });

  for (final b in Brightness.values) {
    group('in ${b.name} mode', () {
      testWidgets('an example, Make report, what the AI understood, the chart, the table and its total', (tester) async {
        final files = <(String, Uint8List)>[];
        final repo = await _pump(tester, b, files: files);
        expect(find.text('What report do you need?'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('reports-example-1')));
        await tester.pump();
        expect(find.text('Cancelled rides by reason, last 7 days'), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('reports-make')));
        await tester.pumpAndSettle();
        expect(repo.asked, ['Cancelled rides by reason, last 7 days']);
        expect(repo.ran.single.groupBy, ['city']);
        expect(find.text('What the AI understood'), findsOneWidget);
        expect(find.text('Checked by the server'), findsOneWidget);
        expect(find.text('The last 30 days (24 Sep 2026 to 23 Oct 2026), by booked (Malaysia time)'), findsOneWidget);
        expect(find.text('Not in this report: Rider name'), findsOneWidget);
        expect(find.byKey(const ValueKey('reports-chart')), findsOneWidget);
        expect(find.byKey(const ValueKey('reports-bar-0')), findsOneWidget);
        expect(find.text('Total'), findsOneWidget);
        expect(find.text('8,232.40'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.ensureVisible(find.byKey(const ValueKey('reports-download-csv')));
        await tester.tap(find.byKey(const ValueKey('reports-download-csv')));
        await tester.pumpAndSettle();
        expect(files.single.$1, 'rides-report-2026-09-24-to-2026-10-23.csv');
        expect(files.single.$2.sublist(0, 3), [0xef, 0xbb, 0xbf], reason: 'UTF-8 with a BOM');
        final csv = utf8.decode(files.single.$2);
        expect(csv, contains('Total,372,8232.4'));
        await tester.tap(find.byKey(const ValueKey('reports-download-xlsx')));
        await tester.pumpAndSettle();
        expect(files.last.$1, endsWith('.xlsx'));
        expect(files.last.$2.sublist(0, 2), [0x50, 0x4b]);
      });

      testWidgets('change columns without the AI', (tester) async {
        final repo = await _pump(tester, b);
        await tester.tap(find.byKey(const ValueKey('reports-make')));
        await tester.pump();
        expect(find.byKey(const ValueKey('reports-problem')), findsOneWidget, reason: 'nothing typed');
        await tester.enterText(find.byKey(const ValueKey('reports-ask')), 'Fares per city');
        await tester.tap(find.byKey(const ValueKey('reports-make')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reports-change-columns')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reports-measure-sum_fare')));
        await tester.tap(find.byKey(const ValueKey('reports-group-created_at:month')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('reports-columns-apply')));
        await tester.pumpAndSettle();
        expect(repo.asked, ['Fares per city'], reason: 'the AI is not asked again');
        expect(repo.ran.last.measures, [ReportMeasure.count]);
        expect(repo.ran.last.groupBy, ['city', 'created_at:month']);
        expect(repo.ran.last.sort, isEmpty);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the AI not set up, a refusal in words, and email not set up', (tester) async {
        final repo = await _pump(tester, b, services: const ReportServices());
        expect(find.byKey(const ValueKey('reports-no-ai')), findsOneWidget);
        expect(find.byKey(const ValueKey('reports-no-email')), findsOneWidget);
        expect(find.textContaining("Email isn't set up yet: add the email key in API Keys"), findsWidgets);
        repo.askReason = "The AI's answer didn't fit the data: Rides has no field \"pin\".";
        await tester.enterText(find.byKey(const ValueKey('reports-ask')), 'Everyone\'s PIN');
        await tester.tap(find.byKey(const ValueKey('reports-make')));
        await tester.pumpAndSettle();
        expect(find.textContaining('Rides has no field "pin"'), findsOneWidget);
        expect(repo.ran, isEmpty);
        expect(tester.takeException(), isNull);
      });

      testWidgets('saved reports: run again, and their email schedules', (tester) async {
        final repo = await _pump(tester, b);
        expect(find.text('Weekly commission by service'), findsOneWidget);
        expect(find.text('Every Monday at 08:00 (Malaysia time)'), findsOneWidget);
        expect(find.textContaining('Next: Mon 26 Oct 2026, 08:00'), findsOneWidget);
        expect(find.textContaining('Last run failed'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('reports-run-again-r1')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Last week').last);
        await tester.pumpAndSettle();
        expect(repo.ran.single.period?.preset, 'last_week');
        expect(find.text('What the AI understood'), findsNothing, reason: 'a saved report run by hand');
        expect(find.text('The report'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('read only: no saving, no schedules to change', (tester) async {
        await _pump(tester, b, level: AccessLevel.read);
        await tester.enterText(find.byKey(const ValueKey('reports-ask')), 'Fares per city');
        await tester.tap(find.byKey(const ValueKey('reports-make')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('reports-save')), findsNothing);
        expect(find.byKey(const ValueKey('reports-schedule-add-r1')), findsNothing);
        expect(find.byKey(const ValueKey('reports-schedule-on-s1')), findsNothing);
      });

      testWidgets('the schedule editor: next run, the period it covers, bad addresses refused', (tester) async {
        final repo = await _pump(tester, b);
        await tester.tap(find.byKey(const ValueKey('reports-schedule-add-r1')));
        await tester.pumpAndSettle();
        expect(find.byType(ReportSchedulePage), findsOneWidget);
        // Friday 23 October, 10:00 in Malaysia: every Monday at 08:00 next sends on the 26th.
        expect(find.text('Next: Mon 26 Oct 2026, 08:00'), findsOneWidget);
        expect(find.text('The next one: 19 Oct 2026 to 25 Oct 2026'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('schedule-day-3')));
        await tester.pump();
        expect(find.text('Next: Mon 26 Oct 2026, 08:00'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('schedule-day-1')));
        await tester.pump();
        expect(find.text('Next: Wed 28 Oct 2026, 08:00'), findsOneWidget);
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('schedule-frequency')), matching: find.text('Every month')));
        await tester.pump();
        expect(find.text('Next: Sun 1 Nov 2026, 08:00'), findsOneWidget);

        await tester.enterText(find.byKey(const ValueKey('schedule-emails')), 'boss@example.com, nope');
        await tester.ensureVisible(find.byKey(const ValueKey('schedule-save')));
        await tester.tap(find.byKey(const ValueKey('schedule-save')));
        await tester.pump();
        expect(find.text('Not an email address: nope'), findsOneWidget);
        expect(repo.savedSchedules, isEmpty);

        await tester.enterText(find.byKey(const ValueKey('schedule-emails')), 'Boss@Example.com');
        await tester.ensureVisible(find.byKey(const ValueKey('schedule-link-only')));
        await tester.tap(find.byKey(const ValueKey('schedule-link-only')));
        await tester.pump();
        expect(find.textContaining('For example: Weekly commission by service for 19 Oct 2026 to 25 Oct 2026'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('schedule-save')));
        await tester.tap(find.byKey(const ValueKey('schedule-save')));
        await tester.pumpAndSettle();
        final s = repo.savedSchedules.single;
        expect(s.timing.frequency, ScheduleFrequency.monthly);
        expect(s.emails, ['boss@example.com']);
        expect(s.linkOnly, isTrue);
        expect(s.formats, ['csv', 'xlsx']);
        expect(s.toRow()['period'], {'preset': 'previous_week'});
        expect(find.byType(ReportSchedulePage), findsNothing);
        expect(tester.takeException(), isNull);
      });
    });
  }
}
