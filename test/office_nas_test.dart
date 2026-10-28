// Office NAS, part N1 (migration 0318): the backup and uptime settings as
// the server keeps them, the words on the Overview, Backups and Uptime
// tabs, and the tabs themselves in light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/office_nas/office_nas_screen.dart';
import 'package:get_ride/src/admin/screens/office_nas/office_nas_uptime.dart' show addressProblem;
import 'package:get_ride/src/admin/screens/security/api_keys_logic.dart';
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart' show grantablePages;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/office_nas.dart';
import 'package:get_ride/src/data/office_nas_repository.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

final _now = DateTime(2026, 10, 28, 10, 42);

String _iso(DateTime d) => d.toUtc().toIso8601String();

Map<String, dynamic> _sample() => {
      'now': _iso(_now),
      'services': [
        {
          'service': 'backup',
          'last_seen': _iso(_now.subtract(const Duration(seconds: 20))),
          'status': 'ok',
          'detail': {
            'keyReady': true,
            'buckets': ['avatars', 'ID_Image', 'ai-reports'],
            'offsite': {'at': '2026-10-28T03:40:00', 'ok': true},
          },
          'version': '1.0.0',
        },
        {
          'service': 'box',
          'last_seen': _iso(_now.subtract(const Duration(seconds: 20))),
          'status': 'ok',
          'detail': {'memUsedMb': 9318, 'memTotalMb': 18432, 'cpuPct': 31, 'diskFreeBytes': 4837851162214, 'diskTotalBytes': 7696581394432, 'tempC': 47},
        },
        {'service': 'maps', 'last_seen': _iso(_now.subtract(const Duration(minutes: 1))), 'status': 'ok', 'detail': {}},
      ],
      'agents': [
        {'id': 'a1', 'label': 'DS224+ office', 'model': 'DS224+ · J4125', 'app_version': '1.0.0', 'last_seen_at': _iso(_now.subtract(const Duration(seconds: 20))), 'online': true},
      ],
      'backup': {'at': '02:00', 'skipBuckets': ['ai-reports'], 'offsite': {'where': 'b2'}},
      'uptime': {
        'failAfter': 2,
        'channels': {'push': true, 'telegram': true},
        'telegramChats': ['-1001234'],
      },
      'runs': [
        {
          'id': 'r1',
          'kind': 'backup',
          'trigger': 'schedule',
          'status': 'ok',
          'started_at': _iso(DateTime(2026, 10, 28, 2, 8)),
          'finished_at': _iso(DateTime(2026, 10, 28, 2, 14)),
          'db_bytes': 1932735283,
          'files': 3104,
          'total_bytes': 1932735283,
        },
      ],
      'last_backup': {
        'id': 'r1',
        'kind': 'backup',
        'status': 'ok',
        'started_at': _iso(DateTime(2026, 10, 28, 2, 8)),
        'finished_at': _iso(DateTime(2026, 10, 28, 2, 14)),
        'total_bytes': 1932735283,
        'files': 3104,
      },
      'last_restore_test': {
        'id': 'r0',
        'kind': 'restore_test',
        'status': 'ok',
        'started_at': _iso(DateTime(2026, 10, 1, 2, 10)),
        'finished_at': _iso(DateTime(2026, 10, 1, 2, 20)),
        'detail': {'summary': '412 tables restored'},
      },
      'requests': [],
      'targets': [
        {'id': 'website', 'name': 'getride.my', 'kind': 'http', 'url': 'https://getride.my', 'on': true, 'position': 10, 'builtin': true},
        {'id': 'database', 'name': 'Database', 'kind': 'database', 'on': true, 'position': 40, 'builtin': true},
        {'id': 'gateways', 'name': 'SMS gateway phones', 'kind': 'gateways', 'on': true, 'from_nas': false, 'position': 50, 'builtin': true},
        {'id': 'payment', 'name': 'Payment gateway', 'kind': 'http', 'url': '{payment}', 'on': false, 'position': 60, 'builtin': true},
      ],
      'status': [
        {
          'id': 'website',
          'name': 'getride.my',
          'sources': {
            'nas': {'status': 'up', 'ms': 210, 'at': _iso(_now.subtract(const Duration(seconds: 30)))},
            'cloud': {'status': 'up', 'ms': 180, 'at': _iso(_now.subtract(const Duration(minutes: 3)))},
          },
          'checks30': 50000,
          'up30': 49990,
        },
        {
          'id': 'database',
          'name': 'Database',
          'sources': {'nas': {'status': 'up', 'ms': 35, 'at': _iso(_now)}},
          'checks30': 100,
          'up30': 100,
        },
        {
          'id': 'gateway:d1',
          'name': 'SMS gateway · Phone 1',
          'sources': {'cloud': {'status': 'up', 'detail': 'Last seen under a minute ago', 'at': _iso(_now)}},
          'checks30': 1000,
          'up30': 992,
        },
        {
          'id': 'gateway:d2',
          'name': 'SMS gateway · Phone 2',
          'sources': {'cloud': {'status': 'slow', 'detail': 'Last seen 6 min ago', 'at': _iso(_now)}},
          'checks30': 1000,
          'up30': 971,
        },
      ],
      'alerts': [
        {
          'id': 'al1',
          'kind': 'down',
          'title': 'SMS gateway · Phone 2 is down',
          'body': 'Last seen 12 min ago.',
          'created_at': _iso(_now.subtract(const Duration(days: 3))),
          'push': 2,
          'telegram': 'sent',
        },
      ],
    };

class _Repo extends OfficeNasRepository {
  _Repo(this.state) : super(_db);
  OfficeNasState state;
  final backups = <NasBackupSettings>[];
  final uptimes = <NasUptimeSettings>[];
  final requests = <RunKind>[];
  final targets = <Map<String, dynamic>>[];
  int tests = 0;

  @override
  Future<OfficeNasState> load() async => state;

  @override
  Future<NasBackupSettings> saveBackup(NasBackupSettings s) async {
    backups.add(s);
    return NasBackupSettings.fromJson(s.toJson());
  }

  @override
  Future<NasUptimeSettings> saveUptime(NasUptimeSettings s) async {
    uptimes.add(s);
    return NasUptimeSettings.fromJson(s.toJson());
  }

  @override
  Future<void> request(RunKind kind) async => requests.add(kind);

  @override
  Future<void> saveTarget(Map<String, dynamic> target) async => targets.add(target);

  @override
  Future<void> testAlert() async => tests++;

  @override
  Future<List<UptimeCheckRow>> history(String target) async =>
      [(at: _now, source: 'nas', status: UptimeStatus.up, ms: 210, detail: 'HTTP 200 in 210 ms')];

  @override
  Future<({String code, DateTime? expiresAt})> pairingCode(String label) async => (code: 'ABCD-EFGH', expiresAt: null);
}

Future<_Repo> _pump(
  WidgetTester tester, {
  String tab = 'overview',
  bool fullAdmin = true,
  bool edit = true,
  Brightness brightness = Brightness.light,
  Map<String, dynamic>? json,
}) async {
  final repo = _Repo(OfficeNasState.fromJson(json ?? _sample(), now: _now));
  await tester.binding.setSurfaceSize(const Size(1100, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      supabaseProvider.overrideWithValue(_db),
      ...quietLiveOverrides,
      adminAccessProvider.overrideWith((_) async => AdminAccess([
            AdminGrant(page: fullAdmin ? '*' : officeNasPage, edit: edit),
          ])),
      officeNasRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp(theme: appTheme(brightness), home: OfficeNasScreen(initialTab: tab)),
  ));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  group('settings, as the server keeps them', () {
    test('backup: read leniently and clamped', () {
      final s = NasBackupSettings.fromJson({
        'at': '25:00',
        'timezone': 'x; drop',
        'keepNightly': 9999,
        'keepMonthly': '3',
        'skipBuckets': ['a', ' a ', '', 'b', 7],
        'restoreTest': {'day': 31, 'on': false},
        'offsite': {'where': 'b2', 'lastCopyOn': '2026-10-27'},
      });
      expect(s.at, '02:00');
      expect(s.timezone, 'Asia/Kuala_Lumpur');
      expect(s.keepNightly, 365);
      expect(s.keepMonthly, 3);
      expect(s.skipBuckets, ['a', 'b']);
      expect(s.restoreTestDay, 28);
      expect(s.restoreTestOn, isFalse);
      expect(s.offsite, OffsiteTarget.b2);
      expect(s.lastCopyOn, '2026-10-27');
      expect(NasBackupSettings.fromJson(s.toJson()).toJson(), s.toJson());
      expect(NasBackupSettings.fromJson(null).toJson(), NasBackupSettings.defaults.toJson());
      expect(s.withBucket('a', true).skipBuckets, ['b']);
      expect(s.withBucket('c', false).skipBuckets, ['a', 'b', 'c']);
      expect(s.copyWith(keepNightly: 0).keepNightly, 1);
      expect(s.copyWith(lastCopyOn: () => null).lastCopyOn, isNull);
    });

    test('uptime: read leniently and clamped; down after late', () {
      final u = NasUptimeSettings.fromJson({
        'failAfter': 0,
        'gatewayLateMinutes': 30,
        'gatewayDownMinutes': 5,
        'channels': {'telegram': true, 'push': 'false'},
        'smsNumbers': ['+60120000318', '+60120000318'],
      });
      expect(u.failAfter, 1);
      expect(u.gatewayDownMinutes, 31);
      expect(u.isOn(AlertChannel.telegram), isTrue);
      expect(u.isOn(AlertChannel.push), isFalse);
      expect(u.smsNumbers, ['+60120000318']);
      expect(u.addresses(AlertChannel.push), isNull);
      expect(NasUptimeSettings.fromJson(u.toJson()).toJson(), u.toJson());
      expect(NasUptimeSettings.fromJson(null).toJson(), NasUptimeSettings.defaults.toJson());
      expect(u.copyWith(gatewayLateMinutes: 50).gatewayDownMinutes, 51);
      expect(u.withChannel(AlertChannel.email, true).isOn(AlertChannel.email), isTrue);
    });
  });

  group('words', () {
    test('sizes, times and uptime', () {
      expect(formatBytes(1932735283), '1.8 GB');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(340 * 1024 * 1024), '340 MB');
      expect(formatBytes(null), '–');
      expect(agoText(_now.subtract(const Duration(seconds: 20)), _now), '20 s ago');
      expect(agoText(_now.subtract(const Duration(minutes: 6)), _now), '6 min ago');
      expect(agoText(_now.subtract(const Duration(days: 1)), _now), '1 day ago');
      expect(agoText(null, _now), 'never');
      expect(durationText(const Duration(minutes: 65)), '1 h 5 min');
      expect(whenText(DateTime(2026, 10, 28, 2, 14), _now), 'Tonight 02:14');
      expect(whenText(DateTime(2026, 10, 27, 2, 14), _now), 'Yesterday 02:14');
      expect(whenText(DateTime(2026, 10, 1, 2, 0), _now), '1 Oct 02:00');
      expect(uptimePercent(49990, 50000), '99.98%');
      expect(uptimePercent(99999, 100000), '99.99%', reason: 'never rounded up to 100%');
      expect(uptimePercent(5, 5), '100%');
      expect(uptimePercent(0, 0), '–');
      expect(uptimePercent(971, 1000), '97.1%');
    });

    test('the next restore test', () {
      final today = DateTime(2026, 10, 28);
      expect(nextRestoreTest(today, 1, DateTime(2026, 10, 1)), DateTime(2026, 11, 1));
      expect(nextRestoreTest(today, 1, DateTime(2026, 9, 1)), today, reason: "October's was missed: tonight");
      expect(nextRestoreTest(DateTime(2026, 10, 3), 5, null), DateTime(2026, 10, 5));
      expect(nextRestoreTest(DateTime(2026, 12, 28), 1, DateTime(2026, 12, 1)), DateTime(2027, 1, 1));
    });

    test('the overview cards', () {
      final s = OfficeNasState.fromJson(_sample(), now: _now);
      expect(s.online, isTrue);
      expect(backupCard(s), (status: 'Tonight 02:14 · OK', tone: Tone.ok, note: 'Off-site copy Tonight 03:40 · OK'));
      final up = uptimeCard(s);
      expect(up.status, '4 of 4 up');
      expect(up.tone, Tone.warn, reason: 'a phone is late');
      expect(up.note, 'Last alert 3 days ago');
      expect(restoreCard(s), (status: 'Due in 4 days', tone: Tone.ok, note: 'Last: 1 Oct · passed'));
      expect(boxLine(s), 'Box: memory 9.1 of 18 GB used · CPU 31% · disk 4.4 TB free of 7 TB · temperature 47 °C');
      expect(s.bucketsSeen, ['ID_Image', 'ai-reports', 'avatars']);

      final empty = OfficeNasState.fromJson({'now': _iso(_now)}, now: _now);
      expect(backupCard(empty).status, 'Not connected');
      expect(uptimeCard(empty).status, 'Not checked yet');
      expect(boxLine(empty), isNull);
      expect(offsiteText(empty), 'No off-site copy yet');
      final manual = OfficeNasState.fromJson({
        'backup': {'offsite': {'where': 'c2', 'lastCopyOn': '2026-10-26'}},
      }, now: _now);
      expect(offsiteText(manual), 'Off-site copy 26 Oct (set by hand)');
    });

    test('a failed backup, and one too old', () {
      final j = _sample();
      j['last_backup'] = {...j['last_backup'] as Map, 'status': 'failed', 'error': 'pg_dump failed: timeout'};
      expect(backupCard(OfficeNasState.fromJson(j, now: _now)).tone, Tone.bad);
      final late = OfficeNasState.fromJson(_sample(), now: _now.add(const Duration(days: 2)));
      expect(backupCard(late).tone, Tone.warn);
    });

    test('uptime rows: gateway phones where the gateways target is; off last', () {
      final s = OfficeNasState.fromJson(_sample(), now: _now);
      expect([for (final r in s.uptimeRows()) r.status?.id ?? r.target.id],
          ['website', 'database', 'gateway:d1', 'gateway:d2', 'payment']);
      expect(s.status.firstWhere((x) => x.id == 'gateway:d2').status, UptimeStatus.slow);
      final down = TargetStatus.fromJson({'id': 'x', 'down_since': _iso(_now), 'sources': {'nas': {'status': 'up'}}});
      expect(down.status, UptimeStatus.down, reason: 'an open incident wins');
      expect(const UptimeTarget(id: 'p', name: 'P', kind: 'http', url: '{payment}').where, 'The payment gateway in use');
    });

    test('addresses and web addresses', () {
      expect(addressProblem(AlertChannel.telegram, '-1001234567890'), isNull);
      expect(addressProblem(AlertChannel.telegram, '@getride_ops'), isNull);
      expect(addressProblem(AlertChannel.telegram, 'hello'), isNotNull);
      expect(addressProblem(AlertChannel.sms, '+60 12-345 6789'), isNull);
      expect(addressProblem(AlertChannel.sms, '12'), isNotNull);
      expect(addressProblem(AlertChannel.email, 'ops@example.com'), isNull);
      expect(addressProblem(AlertChannel.email, 'ops@'), isNotNull);
      expect(uptimeUrlOk('https://qr.getride.my'), isTrue);
      expect(uptimeUrlOk('{project}/functions/v1/uptime-check?ping=1'), isTrue);
      expect(uptimeUrlOk('ftp://x'), isFalse);
      expect(uptimeUrlOk('https://'), isFalse);
    });

    test('registered once, grantable, and the Telegram key has a place', () {
      expect(allAdminEntries.where((e) => e.path == officeNasPath).length, 1);
      expect(allAdminEntries.firstWhere((e) => e.path == officeNasPath).pages, [officeNasPage]);
      expect(grantablePages, contains(officeNasPage));
      final tg = defaultApiProviders.firstWhere((p) => p.id == 'telegram');
      expect(tg.services.map((s) => s.id), ['bot']);
    });
  });

  group('the page', () {
    for (final b in Brightness.values) {
      testWidgets('overview: status, cards and the box (${b.name})', (tester) async {
        await _pump(tester, brightness: b);
        expect(find.text('Online · seen 20 s ago'), findsOneWidget);
        expect(find.text('Tonight 02:14 · OK'), findsOneWidget);
        expect(find.text('4 of 4 up'), findsOneWidget);
        expect(find.text('Due in 4 days'), findsOneWidget);
        expect(find.byKey(const ValueKey('office-nas-card-maps')), findsOneWidget, reason: 'other NAS services too');
        expect(find.byKey(const ValueKey('office-nas-box')), findsOneWidget);
        expect(find.byKey(const ValueKey('office-nas-disconnect-a1')), findsOneWidget);
      });

      testWidgets('uptime: rows, history and channels (${b.name})', (tester) async {
        final repo = await _pump(tester, tab: 'uptime', brightness: b);
        expect(find.byKey(const ValueKey('office-nas-target-uptime-website')), findsOneWidget);
        expect(find.text('99.98%'), findsOneWidget);
        expect(find.text('SMS gateway · Phone 2'), findsOneWidget);
        expect(find.text('seen 6 min ago'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('office-nas-target-website')));
        await tester.pumpAndSettle();
        expect(find.textContaining('From the office'), findsOneWidget);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('office-nas-channel-email')));
        await tester.pumpAndSettle();
        expect(repo.uptimes.last.isOn(AlertChannel.email), isTrue);
        expect(find.text('None yet: nothing is sent.'), findsOneWidget);
      });
    }

    testWidgets('backups: back up now, steppers, buckets', (tester) async {
      final repo = await _pump(tester, tab: 'backups');
      expect(find.text('Tonight 02:14 · 1.8 GB · 3,104 files · 6 min'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('office-nas-backup-now')));
      await tester.pumpAndSettle();
      expect(repo.requests, [RunKind.backup]);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byTooltip('Raise Nightly copies kept'));
      await tester.tap(find.byTooltip('Raise Nightly copies kept'));
      await tester.pumpAndSettle();
      expect(repo.backups.last.keepNightly, 35, reason: 'past a month, five at a time');

      await tester.ensureVisible(find.byKey(const ValueKey('office-nas-bucket-ai-reports')));
      await tester.tap(find.byKey(const ValueKey('office-nas-bucket-ai-reports')));
      await tester.pumpAndSettle();
      expect(repo.backups.last.skipBuckets, isEmpty, reason: 'ai-reports copied again');

      await tester.ensureVisible(find.byKey(const ValueKey('office-nas-restore-day')));
      await tester.tap(find.byTooltip('Raise Day of the month'));
      await tester.pumpAndSettle();
      expect(repo.backups.last.restoreTestDay, 2);
    });

    testWidgets('a waiting backup can\'t be asked for twice', (tester) async {
      final j = _sample();
      j['requests'] = [
        {'kind': 'backup', 'requested_at': _iso(_now)},
      ];
      await _pump(tester, tab: 'backups', json: j);
      expect(find.text('Backing up…'), findsOneWidget);
      final b = tester.widget<FilledButton>(find.byKey(const ValueKey('office-nas-backup-now')));
      expect(b.onPressed, isNull);
    });

    testWidgets('uptime: add a Telegram chat, a target, a test alert', (tester) async {
      final repo = await _pump(tester, tab: 'uptime');
      await tester.ensureVisible(find.byKey(const ValueKey('office-nas-add-address-telegram')));
      await tester.tap(find.byKey(const ValueKey('office-nas-add-address-telegram')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('office-nas-address')), 'nope');
      await tester.tap(find.byKey(const ValueKey('office-nas-address-save')));
      await tester.pumpAndSettle();
      expect(repo.uptimes, isEmpty, reason: 'not a chat id');
      await tester.enterText(find.byKey(const ValueKey('office-nas-address')), '-100777');
      await tester.tap(find.byKey(const ValueKey('office-nas-address-save')));
      await tester.pumpAndSettle();
      expect(repo.uptimes.last.telegramChats, ['-1001234', '-100777']);

      await tester.ensureVisible(find.byKey(const ValueKey('office-nas-add-target')));
      await tester.tap(find.byKey(const ValueKey('office-nas-add-target')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('office-nas-target-name')), 'QR site');
      await tester.enterText(find.byKey(const ValueKey('office-nas-target-url')), 'https://qr.getride.my');
      await tester.tap(find.byKey(const ValueKey('office-nas-target-save')));
      await tester.pumpAndSettle();
      expect(repo.targets.single['url'], 'https://qr.getride.my');
      expect(repo.targets.single.containsKey('id'), isFalse);

      await tester.ensureVisible(find.byKey(const ValueKey('office-nas-test-alert')));
      await tester.tap(find.byKey(const ValueKey('office-nas-test-alert')));
      await tester.pumpAndSettle();
      expect(repo.tests, 1);
    });

    testWidgets('read-only: nothing to change; only a full admin connects', (tester) async {
      await _pump(tester, fullAdmin: false, edit: false, tab: 'overview');
      expect(find.byKey(const ValueKey('office-nas-connect')), findsNothing);
      expect(find.byKey(const ValueKey('office-nas-disconnect-a1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('office-nas-tab-uptime')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('office-nas-add-target')), findsNothing);
      expect(find.byKey(const ValueKey('office-nas-edit-website')), findsNothing);
      final chip = tester.widget<FilterChip>(find.byKey(const ValueKey('office-nas-channel-email')));
      expect(chip.onSelected, isNull);
    });

    testWidgets('connecting gives a one-time code', (tester) async {
      await _pump(tester, json: {..._sample(), 'agents': []});
      await tester.tap(find.byKey(const ValueKey('office-nas-connect')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Get code'));
      await tester.pumpAndSettle();
      expect(find.text('ABCD-EFGH'), findsOneWidget);
    });
  });
}
