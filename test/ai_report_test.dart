// Admin > Reports (migration 0280), the pure half: a plan and its plain
// words, the CSV and Excel files, the periods (Malaysia's days) and the
// email schedules' next run (weekdays, the last day of the month).
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ai_report.dart';
import 'package:get_ride/src/core/ai_report_xlsx.dart';

/// Malaysia's wall clock as a UTC instant.
DateTime myt(int y, int m, int d, [int h = 0, int min = 0]) => DateTime.utc(y, m, d, h, min).subtract(const Duration(hours: 8));

final _catalogue = ReportCatalogue.fromJson({
  'datasets': [
    {
      'id': 'rides',
      'label': 'Rides',
      'time': 'created_at',
      'list': ['created_at', 'status'],
      'fields': [
        {'id': 'status', 'label': 'Status', 'type': 'text'},
        {'id': 'service', 'label': 'Service', 'type': 'text'},
        {'id': 'city', 'label': 'City', 'type': 'text'},
        {'id': 'created_at', 'label': 'Booked', 'type': 'time'},
        {'id': 'fare', 'label': 'Fare (RM)', 'type': 'number'},
      ],
      'hidden': ['Rider name', 'Driver name'],
      'limited': true,
    },
  ],
  'limits': {'max_rows': 50000, 'max_group_by': 3, 'max_measures': 8},
  'scope': {'scoped': true, 'edit': false, 'region': {'country': 'Malaysia', 'state': 'Selangor'}},
});

final _result = ReportResult.fromJson({
  'dataset': 'rides',
  'dataset_label': 'Rides',
  'columns': [
    {'id': 'city', 'label': 'City', 'type': 'text', 'role': 'group', 'field': 'city'},
    {'id': 'count', 'label': 'Count', 'type': 'number', 'role': 'measure', 'field': '*', 'agg': 'count'},
    {'id': 'sum_fare', 'label': 'Total fare (RM)', 'type': 'number', 'role': 'measure', 'field': 'fare', 'agg': 'sum'},
  ],
  'rows': [
    ['Kajang', 212, 4812.4],
    ['Bangi, "Old" town', 98, 2210.5],
    ['=CMD()', 1, -3],
  ],
  'totals': [311, 7019.9],
  'row_count': 3,
  'truncated': false,
  'max_rows': 50000,
  'period': {'from': '2026-09-24', 'to': '2026-10-23', 'preset': 'last_30_days', 'field': 'created_at'},
  'hidden': ['Rider name'],
  'plan': {
    'dataset': 'rides',
    'group_by': ['city'],
    'measures': [
      {'field': '*', 'agg': 'count'},
      {'field': 'fare', 'agg': 'sum'},
    ],
    'sort': [
      {'field': 'sum_fare', 'dir': 'desc'},
    ],
    'filters': [
      {'field': 'status', 'op': 'in', 'value': ['completed']},
    ],
    'period': {'preset': 'last_30_days', 'field': 'created_at'},
  },
});

void main() {
  group('a plan', () {
    test('reads and writes the server\'s JSON', () {
      final p = _result.plan;
      expect(p.groupBy, ['city']);
      expect(p.measures, [ReportMeasure.count, const ReportMeasure('fare', 'sum')]);
      expect(p.sort.single.descending, isTrue);
      expect(p.period?.preset, 'last_30_days');
      final again = ReportPlan.fromJson(jsonDecode(jsonEncode(p.toJson())));
      expect(again.toJson(), p.toJson());
      expect(p.isList, isFalse);
    });

    test('changing columns without the AI drops a sort on a column that went', () {
      final p = _result.plan.toggleMeasure(const ReportMeasure('fare', 'sum'));
      expect(p.measures, [ReportMeasure.count]);
      expect(p.sort, isEmpty);
      final q = p.toggleGroup('created_at:month');
      expect(q.groupBy, ['city', 'created_at:month']);
      expect(q.toggleGroup('city').groupBy, ['created_at:month']);
      expect(ReportPlan.groupColumn('created_at:month'), 'created_at_month');
      expect(const ReportMeasure('fare', 'avg').column, 'avg_fare');
    });

    test('in plain words: what the AI understood', () {
      final lines = Map.fromEntries([
        for (final (k, v) in describeReportPlan(_result.plan, _catalogue, resolved: _result.period, columns: _result.columns))
          MapEntry(k, v),
      ]);
      expect(lines['Data'], 'Rides');
      expect(lines['Period'], 'The last 30 days (24 Sep 2026 to 23 Oct 2026), by booked (Malaysia time)');
      expect(lines['Only'], 'Status is one of completed');
      expect(lines['Group by'], 'City');
      expect(lines['Columns'], 'Count, Total fare (RM)');
      expect(lines['Sort'], 'Total fare (RM), highest first');
      expect(lines['Hidden'], 'Not in this report: Rider name, Driver name');
      final list = describeReportPlan(
        ReportPlan(dataset: 'rides', columns: const ['created_at', 'fare'], period: ReportPeriod.dates(DateTime(2026, 10, 1), DateTime(2026, 10, 1))),
        _catalogue,
      );
      expect(list[1].$2, '1 Oct 2026, by booked (Malaysia time)');
      expect(list[2], ('Columns', 'Booked, Fare (RM)'));
      expect(periodWords(null), 'All time');
      expect(periodWords(const ReportPeriod.preset('last_n_days', days: 14)), 'The last 14 whole days');
    });

    test('the catalogue: a sub-admin\'s region, the dataset\'s fields', () {
      expect(_catalogue.regionLabel, 'Selangor, Malaysia');
      expect(_catalogue.dataset('rides')?.field('fare')?.isNumber, isTrue);
      expect(_catalogue.dataset('nope'), isNull);
      expect(ReportCatalogue.fromJson({'datasets': [], 'scope': {'scoped': false}}).regionLabel, isNull);
      expect(ReportCatalogue.fromJson({'datasets': [], 'scope': {'scoped': true}}).regionLabel, '');
    });
  });

  group('a result', () {
    test('the total row and the chart', () {
      expect(_result.totalRow, ['Total', 311, 7019.9]);
      expect(_result.chartBars()?.map((b) => b.value), [212, 98, 1]);
      expect(_result.chartBars()?.first.label, 'Kajang');
      expect(reportCellText(4812.4, 'number'), '4,812.40');
      expect(reportCellText(1234567, 'number'), '1,234,567');
      expect(reportCellText(-3, 'number'), '-3');
      expect(reportCellText(true, 'bool'), 'Yes');
    });

    test('CSV: a BOM, quotes doubled, formulas defused, the total row', () {
      expect(csvCell('Bangi, "Old" town'), '"Bangi, ""Old"" town"');
      expect(csvCell('two\nlines'), '"two\nlines"');
      expect(csvCell(' edge'), '" edge"');
      expect(csvCell('=SUM(A1)'), "'=SUM(A1)");
      expect(csvCell('-x'), "'-x");
      expect(csvCell(-3), '-3');
      expect(csvCell(null), '');
      final csv = reportCsv(_result);
      expect(csv.codeUnitAt(0), 0xFEFF);
      expect(csv.substring(1).split('\r\n'), [
        'City,Count,Total fare (RM)',
        'Kajang,212,4812.4',
        '"Bangi, ""Old"" town",98,2210.5',
        "'=CMD(),1,-3",
        'Total,311,7019.9',
        '',
      ]);
      expect(reportFileBase('Weekly commission!', _result.period), 'weekly-commission-2026-09-24-to-2026-10-23');
      expect(reportFileBase('???', null), 'report-all-time');
    });

    test('Excel: two sheets, numbers as numbers, text escaped', () {
      final bytes = reportXlsx(_result, [('Only', 'Status is <completed> & paid')]);
      final zip = ZipDecoder().decodeBytes(bytes);
      String part(String name) => utf8.decode(zip.findFile(name)!.content);
      expect(zip.files.map((f) => f.name), containsAll(['[Content_Types].xml', 'xl/workbook.xml', 'xl/worksheets/sheet2.xml']));
      expect(part('xl/workbook.xml'), contains('<sheet name="What the AI understood" sheetId="2" r:id="rId2"/>'));
      final sheet = part('xl/worksheets/sheet1.xml');
      expect(sheet, contains('<c r="B2"><v>212</v></c>'));
      expect(sheet, contains('Bangi, &quot;Old&quot; town'));
      expect(sheet, contains('<c r="A5" s="1" t="inlineStr"><is><t xml:space="preserve">Total</t></is></c>'));
      expect(part('xl/worksheets/sheet2.xml'), contains('Status is &lt;completed&gt; &amp; paid'));
    });
  });

  group('periods, Malaysia\'s days', () {
    test('presets', () {
      final wed = myt(2026, 10, 21, 9);
      String days(ReportPeriod p, DateTime at) {
        final d = periodDays(p, at)!;
        return '${isoDay(d.from)}..${isoDay(d.to)}';
      }

      expect(days(const ReportPeriod.preset('previous_week'), wed), '2026-10-12..2026-10-18');
      expect(days(const ReportPeriod.preset('last_week'), wed), '2026-10-12..2026-10-18');
      expect(days(const ReportPeriod.preset('this_week'), wed), '2026-10-19..2026-10-21');
      expect(days(const ReportPeriod.preset('last_n_days', days: 7), wed), '2026-10-14..2026-10-20');
      expect(days(const ReportPeriod.preset('last_7_days'), wed), '2026-10-15..2026-10-21');
      expect(days(const ReportPeriod.preset('month_to_date'), wed), '2026-10-01..2026-10-21');
      expect(days(const ReportPeriod.preset('previous_day'), wed), '2026-10-20..2026-10-20');
      expect(days(const ReportPeriod.preset('last_year'), wed), '2025-01-01..2025-12-31');
      // Half past midnight on the 1st in Malaysia is still the 30th in UTC.
      expect(days(const ReportPeriod.preset('previous_month'), myt(2026, 10, 1, 0, 30)), '2026-09-01..2026-09-30');
      expect(days(const ReportPeriod.preset('previous_month'), myt(2026, 3, 15)), '2026-02-01..2026-02-28');
      expect(days(const ReportPeriod.preset('previous_month'), myt(2026, 1, 3)), '2025-12-01..2025-12-31');
      expect(periodDays(const ReportPeriod.preset('nope'), wed), isNull);
      expect(periodDays(const ReportPeriod.preset('last_n_days'), wed), isNull);
    });
  });

  group('when a schedule sends', () {
    ScheduleTiming at(ScheduleFrequency f, {int h = 8, int m = 0, Set<int> days = const {1}, int day = 1}) =>
        ScheduleTiming(frequency: f, hour: h, minute: m, weekdays: days, monthDay: day);

    test('every day: later today, else tomorrow', () {
      expect(nextScheduleRun(at(ScheduleFrequency.daily, h: 7), myt(2026, 10, 23, 6, 59)), myt(2026, 10, 23, 7));
      expect(nextScheduleRun(at(ScheduleFrequency.daily, h: 7), myt(2026, 10, 23, 7)), myt(2026, 10, 24, 7));
    });

    test('weekdays', () {
      // Wednesday 21 October after 08:00: the next Monday.
      expect(nextScheduleRun(at(ScheduleFrequency.weekly, days: {1, 3}), myt(2026, 10, 21, 9)), myt(2026, 10, 26, 8));
      expect(nextScheduleRun(at(ScheduleFrequency.weekly, days: {1, 3}), myt(2026, 10, 21, 7)), myt(2026, 10, 21, 8));
      expect(nextScheduleRun(at(ScheduleFrequency.weekly, days: {7}, h: 23, m: 30), myt(2026, 10, 25, 23, 31)), myt(2026, 11, 1, 23, 30));
      expect(nextScheduleRun(at(ScheduleFrequency.weekly, days: {}), myt(2026, 10, 21)), isNull);
    });

    test('a day of the month, and the last day', () {
      const last = ScheduleTiming.lastDay;
      expect(nextScheduleRun(at(ScheduleFrequency.monthly, day: last), myt(2026, 2, 10, 12)), myt(2026, 2, 28, 8));
      expect(nextScheduleRun(at(ScheduleFrequency.monthly, day: last), myt(2026, 2, 28, 8)), myt(2026, 3, 31, 8));
      expect(nextScheduleRun(at(ScheduleFrequency.monthly, day: last), myt(2028, 2, 1)), myt(2028, 2, 29, 8));
      expect(nextScheduleRun(at(ScheduleFrequency.monthly, day: 1, h: 23, m: 30), myt(2026, 10, 31, 23, 45)), myt(2026, 11, 1, 23, 30));
      expect(nextScheduleRun(at(ScheduleFrequency.monthly, day: 15), myt(2026, 12, 20)), myt(2027, 1, 15, 8));
    });

    test('in words', () {
      expect(scheduleWords(at(ScheduleFrequency.daily, h: 7, m: 5)), 'Every day at 07:05');
      expect(scheduleWords(at(ScheduleFrequency.weekly, days: {3, 1, 5})), 'Every Monday, Wednesday and Friday at 08:00');
      expect(scheduleWords(at(ScheduleFrequency.monthly, day: ScheduleTiming.lastDay)), 'Every month on the last day at 08:00');
      expect(at(ScheduleFrequency.daily, h: 7, m: 5).atTime, '07:05:00');
    });

    test('addresses and placeholders', () {
      final r = parseEmails('Boss@Example.com, ops@example.com\nboss@example.com; not-an-email  x@y');
      expect(r.ok, ['boss@example.com', 'ops@example.com']);
      expect(r.bad, ['not-an-email', 'x@y']);
      expect(
        fillReportPlaceholders('{report} for {period}: {rows} rows', report: 'Weekly', period: 'Last week', rows: 12345),
        'Weekly for Last week: 12,345 rows',
      );
    });

    test('a schedule row: read and written', () {
      final s = ReportSchedule.fromJson({
        'id': 's1',
        'saved_id': 'r1',
        'frequency': 'monthly',
        'at_time': '07:30:00',
        'weekdays': [1],
        'month_day': -1,
        'period': {'preset': 'last_n_days', 'days': 14},
        'emails': ['a@example.com'],
        'formats': ['csv', 'pdf'],
        'link_only': true,
        'next_run_at': '2026-10-30T23:30:00+00:00',
      });
      expect(s.timing.monthDay, ScheduleTiming.lastDay);
      expect(s.timing.hour, 7);
      expect(s.period.days, 14);
      expect(s.toRow()['at_time'], '07:30:00');
      expect(s.toRow()['period'], {'preset': 'last_n_days', 'days': 14});
      expect(s.nextRunAt, DateTime.utc(2026, 10, 30, 23, 30));
    });
  });
}
