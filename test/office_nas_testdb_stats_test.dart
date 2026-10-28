// Office NAS › Test database and Visitor stats (migration 0321): the logic,
// and the two tabs in light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/office_nas/office_nas_screen.dart';
import 'package:get_ride/src/core/office_nas.dart' show officeNasPage, officeNasPath;
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart' show grantablePages;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/office_nas_stats.dart';
import 'package:get_ride/src/core/office_nas_testdb.dart';
import 'package:get_ride/src/data/office_nas_stats_repository.dart';
import 'package:get_ride/src/data/office_nas_testdb_repository.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

final _now = DateTime.now().toUtc();

Map<String, dynamic> _run(String id, String kind, String status,
        {int? pr, String? branch, int? ms, String? error, List<String> files = const [], Map? detail}) =>
    {
      'id': id,
      'kind': kind,
      'status': status,
      'pr_number': pr,
      'branch': branch,
      'ms': ms,
      'error': error,
      'files': files,
      'detail': detail ?? {},
      'head_sha': 'abc1234def',
      'created_at': _now.toIso8601String(),
      'finished_at': status == 'queued' ? null : _now.toIso8601String(),
    };

final _state = TestDbState.fromJson({
  'settings': {'refreshAt': '02:30', 'scramble': true},
  'runners': [
    {
      'id': 'r1',
      'label': 'DS224+',
      'model': 'Celeron J4125',
      'app_version': '1.0.0',
      'last_seen_at': _now.toIso8601String(),
      'online': true,
      'state': {'refreshed_at': _now.toIso8601String(), 'size_bytes': 1800000000, 'scrambled': true},
    },
  ],
  'last_refresh': _run('f1', 'refresh', 'passed', ms: 360000),
  'last_migration': _run('m1', 'migration', 'failed',
      pr: 554, ms: 4200, error: 'ERROR:  relation "x" does not exist', files: ['supabase/migrations/0321_x.sql']),
  'waiting': [_run('w1', 'migration', 'queued', pr: 555)],
  'recent': [
    _run('w1', 'migration', 'queued', pr: 555),
    _run('m1', 'migration', 'failed', pr: 554, ms: 4200, error: 'ERROR:  relation "x" does not exist'),
    _run('f1', 'refresh', 'passed', ms: 360000),
  ],
});

class _TestDbRepo extends OfficeNasTestDbRepository {
  _TestDbRepo(this.current) : super(_db);
  TestDbState current;
  final saves = <TestDbSettings>[];
  final tries = <String>[];
  final cancelled = <String>[];
  var refreshes = 0;

  @override
  Future<TestDbState> state() async => current;

  @override
  Future<TestDbSettings> save(TestDbSettings s) async {
    saves.add(s);
    return s;
  }

  @override
  Future<TestDbRun> tryMigration({int? pr, String? branch}) async {
    tries.add(pr != null ? 'pr:$pr' : 'branch:$branch');
    return TestDbRun.fromJson(_run('n1', 'migration', 'queued', pr: pr, branch: branch));
  }

  @override
  Future<void> refreshNow() async => refreshes++;

  @override
  Future<void> cancel(String id) async => cancelled.add(id);

  @override
  Future<({String code, DateTime? expiresAt})> pairingCode(String label) async => (code: 'ABCD-EFGH', expiresAt: null);
}

class _StatsRepo extends OfficeNasStatsRepository {
  _StatsRepo(this.stats) : super(_db);
  VisitorStats stats;
  NasStatsSettings cfg = const NasStatsSettings(websiteId: '3f2504e0-4f89-11d3-9a0c-0305e82c3301');
  final saves = <NasStatsSettings>[];

  @override
  Future<NasStatsSettings> config() async => cfg;

  @override
  Future<NasStatsSettings> save(NasStatsSettings s) async {
    saves.add(s);
    return cfg = s;
  }

  @override
  Future<VisitorStats> today() async => stats;
}

const _on = VisitorStats(
  state: StatsState.on,
  today: VisitorToday(visitors: 1284, pageviews: 2410, visits: 1400, installViews: 312, topPage: '/install/android', topSource: 'WhatsApp'),
);

Future<({_TestDbRepo db, _StatsRepo stats})> _pump(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  String? tab = 'test-db',
  bool fullAdmin = true,
  bool edit = true,
  TestDbState? state,
  VisitorStats stats = _on,
}) async {
  final db = _TestDbRepo(state ?? _state);
  final st = _StatsRepo(stats);
  await tester.binding.setSurfaceSize(const Size(1000, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      supabaseProvider.overrideWithValue(_db),
      ...quietLiveOverrides,
      adminAccessProvider.overrideWith((_) async => AdminAccess([
            AdminGrant(page: fullAdmin ? '*' : officeNasPage, edit: edit),
          ])),
      officeNasTestDbRepositoryProvider.overrideWithValue(db),
      officeNasStatsRepositoryProvider.overrideWithValue(st),
    ],
    child: MaterialApp(theme: appTheme(brightness), home: OfficeNasScreen(initialTab: tab)),
  ));
  await tester.pumpAndSettle();
  return (db: db, stats: st);
}

String _text(WidgetTester tester, String key) => tester
    .widget<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text), matchRoot: true).first)
    .data!;

void main() {
  test('the page is listed under Settings and grantable to sub-admins', () {
    final e = allAdminEntries.singleWhere((e) => e.path == officeNasPath);
    expect(e.pages, [officeNasPage]);
    expect(grantablePages, contains(officeNasPage));
    expect(officeNasTabs.map((t) => t.label), containsAll(['Test database', 'Visitor stats']));
  });

  group('test database logic', () {
    test('settings read like the server writes them', () {
      expect(TestDbSettings.fromJson({'refreshAt': '7:05', 'scramble': false}).toJson(),
          {'refreshAt': '07:05', 'scramble': false});
      expect(TestDbSettings.fromJson({'refreshAt': '25:00', 'scramble': 'no'}).toJson(),
          {'refreshAt': '02:30', 'scramble': true});
      expect(TestDbSettings.fromJson(null).hour, 2);
    });

    test('the "Try migration from PR #" box', () {
      expect(parseTryTarget('554'), (pr: 554, branch: null));
      expect(parseTryTarget(' #554 '), (pr: 554, branch: null));
      expect(parseTryTarget('PR 554'), (pr: 554, branch: null));
      expect(parseTryTarget('https://github.com/getgroupmy/get-ride/pull/554/files'), (pr: 554, branch: null));
      expect(parseTryTarget('claude/nas-n4'), (pr: null, branch: 'claude/nas-n4'));
      expect(parseTryTarget(''), isNull);
      expect(parseTryTarget('a/../b'), isNull);
      expect(parseTryTarget('-x'), isNull);
      expect(parseTryTarget('x; drop table'), isNull);
      expect(parseTryTarget('0'), isNull);
    });

    test('runs read in a line', () {
      expect(formatRunTime(4200), '4.2 s');
      expect(formatRunTime(360000), '6 min');
      expect(formatRunTime(3900000), '1 h 5 min');
      expect(formatRunTime(null), '');
      expect(formatBytes(1800000000), '1.8 GB');
      expect(formatBytes(640000000), '640 MB');
      expect(runSummary(TestDbRun.fromJson(_run('a', 'migration', 'passed', ms: 4200,
          files: ['supabase/migrations/0311_a.sql', 'supabase/migrations/0312_b.sql']))), '0311, 0312 · passed in 4.2 s');
      expect(runSummary(TestDbRun.fromJson(_run('a', 'migration', 'queued', pr: 555))), 'PR #555 · waiting');
      expect(runSummary(TestDbRun.fromJson(_run('a', 'refresh', 'failed'))), 'Refresh · failed');
      expect(TestDbRun.fromJson(_run('a', 'migration', 'passed', detail: {'rerun': 'failed: x'})).rerunProblem, 'failed: x');
      final now = DateTime(2026, 10, 28, 9);
      expect(whenText(DateTime(2026, 10, 28, 2, 41), now), 'Today 02:41');
      expect(whenText(DateTime(2026, 10, 27, 2, 41), now), 'Yesterday 02:41');
      expect(whenText(DateTime(2026, 10, 20, 2, 41), now), '20 Oct 02:41');
    });
  });

  group('visitor stats logic', () {
    test('the function\'s answers', () {
      final on = VisitorStats.fromJson({
        'state': 'on',
        'today': {'visitors': 1284, 'installViews': 312, 'topPage': '/', 'topSource': ' '},
        'at': '2026-10-28T03:00:00Z',
      });
      expect(on.state, StatsState.on);
      expect(on.today!.visitors, 1284);
      expect(on.today!.topSource, isNull);
      expect(VisitorStats.fromJson({'state': 'not_set', 'reason': 'key'}).state, StatsState.notSet);
      expect(VisitorStats.fromJson({'state': 'weird'}).state, StatsState.nasOff);
      expect(VisitorStats.fromJson(null).state, StatsState.nasOff);
      expect(groupedNumber(1284), '1,284');
      expect(statsStateText(const VisitorStats(state: StatsState.notSet, reason: 'key')), contains('API Keys'));
    });

    test('website ID', () {
      expect(NasStatsSettings.fromJson({'websiteId': ' 3F2504E0-4F89-11D3-9A0C-0305E82C3301'}).websiteId,
          '3f2504e0-4f89-11d3-9a0c-0305e82c3301');
      expect(NasStatsSettings.fromJson({'websiteId': 'nope', 'on': false}).toJson(), {'on': false, 'websiteId': null});
    });
  });

  for (final b in Brightness.values) {
    group('test database tab (${b.name})', () {
      testWidgets('shows the copy, the last migration with its error, and what waits', (tester) async {
        await _pump(tester, brightness: b);
        expect(_text(tester, 'testdb-runner-status'), 'DS224+ · Online');
        expect(find.text('02:30'), findsOneWidget);
        expect(_text(tester, 'testdb-last-migration'), '0321 · failed in 4.2 s');
        expect(find.byKey(const ValueKey('testdb-error')), findsOneWidget);
        expect(_text(tester, 'testdb-last-refresh'), contains('1.8 GB'));
        expect(_text(tester, 'testdb-next'), 'PR #555 · waiting');
        expect(tester.takeException(), isNull);
      });

      testWidgets('try a PR, refresh now, cancel a waiting run', (tester) async {
        final r = await _pump(tester, brightness: b);
        await tester.enterText(find.byKey(const ValueKey('testdb-target')), 'nonsense ..');
        await tester.tap(find.byKey(const ValueKey('testdb-try-button')));
        await tester.pumpAndSettle();
        expect(find.text('A PR number (e.g. 554) or a branch name'), findsOneWidget);
        expect(r.db.tries, isEmpty);
        await tester.enterText(find.byKey(const ValueKey('testdb-target')), '#556');
        await tester.tap(find.byKey(const ValueKey('testdb-try-button')));
        await tester.pumpAndSettle();
        expect(r.db.tries, ['pr:556']);
        await tester.tap(find.byKey(const ValueKey('testdb-refresh-now')));
        await tester.pumpAndSettle();
        expect(r.db.refreshes, 1);
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('testdb-waiting-w1')), matching: find.text('Cancel')));
        await tester.pumpAndSettle();
        expect(r.db.cancelled, ['w1']);
      });

      testWidgets('scrambling off asks first', (tester) async {
        final r = await _pump(tester, brightness: b);
        await tester.tap(find.byKey(const ValueKey('testdb-scramble')));
        await tester.pumpAndSettle();
        expect(find.text('Keep personal data in the copy?'), findsOneWidget);
        await tester.tap(find.text('Turn off'));
        await tester.pumpAndSettle();
        expect(r.db.saves.single.scramble, isFalse);
        expect(find.byKey(const ValueKey('testdb-scramble-off')), findsOneWidget);
      });
    });
  }

  testWidgets('a sub-admin may try migrations but not turn scrambling off or connect the NAS', (tester) async {
    await _pump(tester, fullAdmin: false);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('testdb-scramble'))).onChanged, isNull);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('testdb-try-button'))).onPressed, isNotNull);
    expect(find.byKey(const ValueKey('testdb-disconnect')), findsNothing);
  });

  testWidgets('read only: nothing to change', (tester) async {
    await _pump(tester, fullAdmin: false, edit: false);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('testdb-try-button'))).onPressed, isNull);
    expect(find.byKey(const ValueKey('testdb-refresh-now')), findsNothing);
  });

  testWidgets('no runner yet: a full admin connects one with a code', (tester) async {
    await _pump(tester, state: const TestDbState());
    expect(_text(tester, 'testdb-runner-status'), 'Not connected');
    expect(_text(tester, 'testdb-last-migration'), 'None yet');
    await tester.tap(find.byKey(const ValueKey('testdb-connect')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Get code'));
    await tester.pumpAndSettle();
    expect(find.text('ABCD-EFGH'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  });

  for (final b in Brightness.values) {
    group('visitor stats tab (${b.name})', () {
      testWidgets("today's numbers", (tester) async {
        await _pump(tester, brightness: b, tab: 'stats');
        expect(find.text('1,284'), findsOneWidget);
        expect(find.text('312'), findsOneWidget);
        expect(find.text('/install/android'), findsOneWidget);
        expect(find.text('WhatsApp'), findsOneWidget);
        expect(_text(tester, 'stats-state'), contains('2,410 page views'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('NAS off: dashes and a plain line', (tester) async {
        await _pump(tester, brightness: b, tab: 'stats', stats: const VisitorStats.unreachable());
        expect(find.text('1,284'), findsNothing);
        expect(find.text('–'), findsNWidgets(4));
        expect(_text(tester, 'stats-state'), startsWith('NAS off'));
      });
    });
  }

  testWidgets('the website ID is checked, then saved', (tester) async {
    final r = await _pump(tester, tab: 'stats');
    await tester.enterText(find.byKey(const ValueKey('stats-website')), 'abc');
    await tester.tap(find.byKey(const ValueKey('stats-website-save')));
    await tester.pumpAndSettle();
    expect(r.stats.saves, isEmpty);
    expect(find.textContaining('8-4-4-4-12'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('stats-website')), '3F2504E0-4F89-11D3-9A0C-0305E82C3302');
    await tester.tap(find.byKey(const ValueKey('stats-website-save')));
    await tester.pumpAndSettle();
    expect(r.stats.saves.single.websiteId, '3f2504e0-4f89-11d3-9a0c-0305e82c3302');
    await tester.tap(find.byKey(const ValueKey('stats-on')));
    await tester.pumpAndSettle();
    expect(r.stats.saves.last.on, isFalse);
  });

  testWidgets('switching tabs', (tester) async {
    await _pump(tester);
    expect(find.byKey(const ValueKey('testdb-copy')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('office-nas-tab-stats')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stats-visitors')), findsOneWidget);
  });
}
