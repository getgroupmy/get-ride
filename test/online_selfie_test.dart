// The partner selfie check when going online (migration 0290), light and
// dark: the words and parsing (unit), the go-online modal for a new phone
// and a random check, Not now, the time running out, the low match that
// still goes online, no provider, the web; the admin's settings, the watch
// list and its rule dialog, the alert's page with Go offline, Add to watch
// list and Looked at it, Documents › Sign-in checks with low matches first,
// and Edit Partner's card. Made-up people only.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/dispatch/selfie_checks_settings.dart';
import 'package:get_ride/src/admin/screens/online_selfie_check_screen.dart';
import 'package:get_ride/src/admin/screens/people_screens.dart' show adminDialerProvider;
import 'package:get_ride/src/admin/screens/selfie_watch_list.dart';
import 'package:get_ride/src/admin/screens/signin_checks_review.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/online_selfie.dart';
import 'package:get_ride/src/core/partner_remote_action.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/core/signin_checks.dart';
import 'package:get_ride/src/data/identity_repository.dart';
import 'package:get_ride/src/data/online_selfie_repository.dart';
import 'package:get_ride/src/data/partner_remote_repository.dart';
import 'package:get_ride/src/features/partner/online_selfie_check.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/live_selfie.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';
import 'text_contrast.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));
const _check = '00000000-0000-0000-0000-000000000290';
const _partner = '00000000-0000-0000-0000-0000000290b1';

class _Repo extends OnlineSelfieRepository {
  _Repo({
    this.due = const OnlineSelfieDue(due: true, id: _check, reason: 'new_device'),
    this.results = const [
      {'face_state': 'match', 'face_score': 92.4, 'low_match': false},
    ],
    this.submitError,
    this.rows = const [],
    this.watch = const [],
    this.one,
  }) : super(_db, IdentityRepository(_db));

  final OnlineSelfieDue due;
  final List<Map<String, dynamic>> results;
  final Object? submitError;
  OnlineSelfieConfig cfg = const OnlineSelfieConfig();
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> watch;
  final Map<String, dynamic>? one;
  final log = <String>[];
  String? platform;
  int _asked = 0;

  @override
  Future<OnlineSelfieDue> start({required String platform}) async {
    this.platform = platform;
    return due;
  }

  @override
  Future<void> skip(String id, String why) async => log.add('skip $why');

  @override
  Future<void> submit(String id, LiveSelfie selfie) async {
    if (submitError != null) throw submitError!;
    log.add('submit ${selfie.liveness}');
  }

  @override
  Future<Map<String, dynamic>> result(String id) async => results[(_asked++).clamp(0, results.length - 1)];

  @override
  Future<OnlineSelfieConfig> config() async => cfg;

  @override
  Future<OnlineSelfieConfig> setConfig(OnlineSelfieConfig c) async {
    log.add('config ${c.toJson()}');
    return cfg = c;
  }

  @override
  Future<List<({String id, String name})>> admins() async => const [
    (id: 'admin-1', name: 'Test Owner'),
    (id: 'admin-2', name: 'Test Ops'),
  ];

  @override
  Future<List<Map<String, dynamic>>> list(String filter) async => filter == 'closer'
      ? [
          for (final r in rows)
            if (r['closer'] == true) r,
        ]
      : rows;

  @override
  Future<int> closerCount() async => rows.where((r) => r['closer'] == true).length;

  @override
  Future<Map<String, dynamic>?> check(String id) async => one;

  @override
  Future<void> review(String id, {String? note}) async => log.add('review $id ${note ?? ''}'.trim());

  @override
  Future<Map<String, dynamic>> person(String userId) async => {
    'checks': rows,
    'watch': watch.isEmpty ? null : watch.first,
  };

  @override
  Future<List<Map<String, dynamic>>> watchList() async => watch;

  @override
  Future<void> watchSet(String userId, WatchEntry w, {String? fromCheck}) async =>
      log.add('watch $userId ${w.rule.value} ${w.pct} ${w.cap} ${w.until ?? '-'} ${w.reason} ${fromCheck ?? '-'}');

  @override
  Future<void> watchRemove(String userId) async => log.add('unwatch $userId');
}

class _Remote extends PartnerRemoteRepository {
  _Remote() : super(_db);
  final asked = <String>[];

  @override
  Future<RemoteActionRequest?> request(String profileId, RemoteAction action, {String? vehicleId}) async {
    asked.add('$profileId ${action.wire}');
    return null;
  }
}

class _Identity extends IdentityRepository {
  _Identity() : super(_db);

  @override
  Future<List<Map<String, dynamic>>> list(String filter) async => [
    {
      'id': 'upload-1',
      'kind': 'selfie',
      'purpose': 'first',
      'status': 'Pending Review',
      'name': 'Test Staff',
      'liveness': 'passed',
      'created_at': '2026-10-24T08:00:00Z',
    },
  ];

  @override
  Future<int> waitingCount() async => 1;

  @override
  Future<IdentityConfig> config() async => const IdentityConfig();
}

final _selfie = LiveSelfie(bytes: Uint8List.fromList([1, 2, 3]), liveness: 'passed', detail: 'blink');

Map<String, dynamic> _row({
  String id = _check,
  String name = 'Test Partner',
  String reason = 'new_device',
  num? score = 41,
  bool closer = true,
  String createdAt = '2026-10-24T09:00:00Z',
}) => {
  'id': id,
  'user_id': _partner,
  'partner_id': 'partner-1',
  'name': name,
  'phone': '+60110000290',
  'reason': reason,
  'state': 'answered',
  'device_model': 'Test Phone B',
  'face_state': closer ? 'no_match' : 'match',
  'face_score': score,
  'face_provider': 'aws',
  'photo_score': score,
  'id_score': 30,
  'liveness': 'passed',
  'liveness_detail': 'blink',
  'low_match': closer,
  'closer': closer,
  'created_at': createdAt,
  'answered_at': createdAt,
  'low_below': 60,
};

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness b = Brightness.light,
  List<Override> overrides = const [],
  List<AdminGrant> grants = const [AdminGrant(page: '*', edit: true)],
  Size size = const Size(500, 1100),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router = GoRouter(
    initialLocation: '/test',
    routes: [
      GoRoute(
        path: '/test',
        builder: (_, _) => Scaffold(body: child),
      ),
      GoRoute(
        path: '/admin/m/online-selfie-check',
        builder: (_, s) => Text('check page ${s.uri.queryParameters['id']}'),
      ),
      GoRoute(path: '/admin/m/selfie-watch-list', builder: (_, _) => const Text('watch list page')),
      GoRoute(path: '/admin/m/partner-edit', builder: (_, _) => const Text('edit partner page')),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        ...quietLiveOverrides,
        adminAccessProvider.overrideWith((_) async => AdminAccess(grants)),
        currentUserIdProvider.overrideWithValue('me'),
        ...overrides,
      ],
      child: MaterialApp.router(theme: appTheme(b), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// A Go online button that runs the check and keeps what it said.
class _GoOnline extends ConsumerStatefulWidget {
  const _GoOnline();

  @override
  ConsumerState<_GoOnline> createState() => _GoOnlineState();
}

class _GoOnlineState extends ConsumerState<_GoOnline> {
  bool? online;
  String? refusal;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      FilledButton(
        key: const ValueKey('go'),
        onPressed: () async {
          final ok = await ensureOnlineSelfie(context, ref, onRefusal: (r) => refusal = r, pollEvery: Duration.zero);
          setState(() => online = ok);
        },
        child: const Text('Go online'),
      ),
      Text(online == null ? 'not yet' : (online! ? 'ONLINE' : 'OFFLINE'), key: const ValueKey('state')),
    ],
  );
}

List<Override> _phone(_Repo repo, {String platform = 'android', OnlineSelfieTaker? taker}) => [
  onlineSelfieRepositoryProvider.overrideWithValue(repo),
  onlineSelfiePlatformProvider.overrideWithValue(platform),
  onlineSelfieTakerProvider.overrideWithValue(taker ?? (_, _) async => _selfie),
];

String _state(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('state'))).data!;

void main() {
  group('words and parsing:', () {
    test('only phones are checked', () {
      expect(onlineSelfiePlatform(web: true, platform: TargetPlatform.android), 'web');
      expect(onlineSelfiePlatform(web: false, platform: TargetPlatform.android), 'android');
      expect(onlineSelfiePlatform(web: false, platform: TargetPlatform.iOS), 'ios');
      expect(onlineSelfiePlatform(web: false, platform: TargetPlatform.macOS), 'desktop');
      expect(onlineSelfiePlatform(web: false, platform: TargetPlatform.windows), 'desktop');
      expect(onlineSelfieOnPhone('ios'), isTrue);
      expect(onlineSelfieOnPhone('web'), isFalse);
      expect(onlineSelfieOnPhone('desktop'), isFalse);
    });

    test("the server's answer", () {
      final d = OnlineSelfieDue.fromJson({'due': true, 'id': _check, 'reason': 'new_device', 'answer_seconds': 120});
      expect([d.due, d.newPhone, d.answerSeconds], [true, true, 120]);
      expect(
        OnlineSelfieDue.fromJson({'due': true, 'id': _check, 'reason': 'watch_list'}).reason,
        'random',
        reason: 'a watched partner is told it is a random check',
      );
      expect(OnlineSelfieDue.fromJson({'due': true}).due, isFalse, reason: 'no id, nothing to answer');
      expect(OnlineSelfieDue.fromJson({'due': false, 'blocked': true, 'message': 'On your phone'}).blocked, isTrue);
      expect(OnlineSelfieDue.fromJson(null).due, isFalse);
      expect(OnlineSelfieDue.fromJson({'due': true, 'id': _check}).answerSeconds, 180);
    });

    test('the modal says why', () {
      expect(onlineSelfiePrompt('new_device'), startsWith('You are using a new phone.'));
      expect(onlineSelfiePrompt('random'), startsWith('Random safety check.'));
      expect(answerClock(const Duration(minutes: 3)), '3:00');
      expect(answerClock(const Duration(seconds: 65)), '1:05');
      expect(answerClock(const Duration(seconds: -4)), '0:00');
      expect(answerTimeText(180), '3 minutes');
      expect(answerTimeText(60), '1 minute');
      expect(answerTimeText(90), '90 seconds');
    });

    test('the result is online every time', () {
      expect(onlineSelfieOutcome({'face_state': 'pending'}), isNull);
      expect(
        onlineSelfieOutcome({'face_state': 'match', 'face_score': 92, 'low_match': false}),
        OnlineSelfieOutcome.match,
      );
      expect(
        onlineSelfieOutcome({'face_state': 'no_match', 'face_score': 41, 'low_match': true}),
        OnlineSelfieOutcome.low,
      );
      expect(
        onlineSelfieOutcome({'face_state': 'no_match', 'face_score': 72, 'low_match': false}),
        OnlineSelfieOutcome.match,
        reason: 'above the admin threshold is not low',
      );
      expect(
        onlineSelfieOutcome({'face_state': 'not_checked', 'face_reason': 'no_aws_key'}),
        OnlineSelfieOutcome.notChecked,
      );
      for (final o in OnlineSelfieOutcome.values) {
        expect(onlineSelfieOutcomeText(o), endsWith('You are online.'));
      }
    });

    test("the admin's settings", () {
      final c = OnlineSelfieConfig.fromJson({
        'randomOn': false,
        'randomPct': 35,
        'alertTo': 'support',
        'answerSeconds': 300,
      });
      expect(
        [c.randomOn, c.randomPct, c.randomCap, c.lowBelow, c.alertTo, c.answerSeconds],
        [false, 35, 1, 60, AlertTo.support, 300],
      );
      expect(OnlineSelfieConfig.fromJson(c.toJson()), c);
      expect(const OnlineSelfieConfig().problem, isNull);
      expect(const OnlineSelfieConfig(randomPct: 150).problem, 'Give a chance from 0 to 100%.');
      expect(const OnlineSelfieConfig(lowBelow: 0).problem, 'Give a match from 1 to 99%.');
      expect(const OnlineSelfieConfig(alertTo: AlertTo.selected).problem, 'Pick at least one admin for the alert.');
      expect(perDayText(1), 'once a day');
      expect(perDayText(3), 'up to 3 a day');
    });

    test('watch-list rules in a few words', () {
      expect(watchRuleText(const WatchEntry(rule: WatchRule.every)), 'Every go-online');
      expect(watchRuleText(const WatchEntry(rule: WatchRule.percent, pct: 50, cap: 3)), '50% · up to 3 a day');
      expect(
        watchRuleText(const WatchEntry(rule: WatchRule.hours, hours: 8), untilText: '30 Nov 2026'),
        'Every 8 hours online · until 30 Nov 2026',
      );
      expect(watchRuleText(const WatchEntry(rule: WatchRule.every, active: false)), 'Every go-online · ended');
      expect(const WatchEntry(rule: WatchRule.every).problem, 'Say why they are on the watch list.');
      expect(const WatchEntry(rule: WatchRule.percent, pct: 0, reason: 'x').problem, 'Give a chance from 1 to 100%.');
      expect(const WatchEntry(rule: WatchRule.hours, hours: 200, reason: 'x').problem, 'Give 1 to 168 hours.');
      expect(
        WatchEntry.fromJson({'rule': 'percent', 'pct': 40, 'cap': 2, 'until': '2026-11-30', 'reason': 'r'}).until,
        '2026-11-30',
      );
    });

    test('what the admin reads', () {
      expect(onlineCheckReasonText('new_device'), 'New phone');
      expect(onlineCheckReasonText('random'), 'Random');
      expect(onlineCheckReasonText('watch_list'), 'Watch list');
      final s = onlineCheckSubtitle(_row());
      expect(s, contains('Going online: New phone'));
      expect(s, contains('Test Phone B'));
      expect(s, contains('41% match'));
      expect(s, contains('AWS'));
      expect(s, contains('Live: blinked'));
      expect(onlineCheckStateText({'state': 'due', 'last_skip': 'timeout'}), 'Not answered: time ran out');
      expect(onlineCheckStateText(_row()), 'Needs a closer look');
      expect(faceReasonText('not_sent'), "The face match couldn't be asked");
    });

    test('the low-match push opens the check', () {
      expect(
        pushRouteFor({'type': 'online_selfie_check', 'check_id': _check, 'for': 'admin'}),
        '/admin/m/online-selfie-check?id=$_check',
      );
      expect(pushRouteFor({'type': 'online_selfie_check'}), '/admin/documents?kind=signin');
    });

    test('no arrows in what people read', () {
      for (final s in [
        onlineSelfiePrompt('new_device'),
        onlineSelfiePrompt('random'),
        for (final o in OnlineSelfieOutcome.values) onlineSelfieOutcomeText(o),
        for (final a in AlertTo.values) a.help,
      ]) {
        expect(s.contains('→'), isFalse, reason: s);
      }
    });
  });

  for (final b in Brightness.values) {
    group('${b.name}:', () {
      testWidgets('a new phone: the modal says why; the selfie goes in and they go online', (tester) async {
        final repo = _Repo();
        await _pump(tester, const _GoOnline(), b: b, overrides: _phone(repo));
        await _tap(tester, find.byKey(const ValueKey('go')));
        expect(find.byKey(const ValueKey('online-selfie-ask')), findsOneWidget);
        expect(find.text('You are using a new phone. Take a quick selfie so we know it is you.'), findsOneWidget);
        expect(find.textContaining('3:00 left to answer'), findsOneWidget);
        expect(find.byIcon(Icons.phonelink_lock), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(AlertDialog)), isEmpty);
        await tester.pump(const Duration(seconds: 2));
        expect(find.textContaining('2:58 left to answer'), findsOneWidget, reason: 'the time counts down');

        await _tap(tester, find.byKey(const ValueKey('online-selfie-take')));
        expect(find.byKey(const ValueKey('online-selfie-result-match')), findsOneWidget);
        expect(find.text('92% match'), findsOneWidget);
        expect(find.text('Thanks, it is you. You are online.'), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(AlertDialog)), isEmpty);
        await _tap(tester, find.byKey(const ValueKey('online-selfie-start')));
        expect(_state(tester), 'ONLINE');
        expect(repo.log, ['submit passed']);
        expect(repo.platform, 'android');
      });

      testWidgets('a random check says so', (tester) async {
        final repo = _Repo(
          due: const OnlineSelfieDue(due: true, id: _check, reason: 'random', answerSeconds: 120),
        );
        await _pump(
          tester,
          const _GoOnline(),
          b: b,
          overrides: _phone(repo, platform: 'ios'),
        );
        await _tap(tester, find.byKey(const ValueKey('go')));
        expect(find.text('Random safety check. Take a quick selfie before you go online.'), findsOneWidget);
        expect(find.textContaining('2:00 left to answer'), findsOneWidget, reason: "the admin's time to answer");
        expect(find.byIcon(Icons.verified_user_outlined), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('online-selfie-take')));
        await _tap(tester, find.byKey(const ValueKey('online-selfie-start')));
        expect(_state(tester), 'ONLINE');
      });

      testWidgets('Not now keeps them offline', (tester) async {
        final repo = _Repo();
        await _pump(tester, const _GoOnline(), b: b, overrides: _phone(repo));
        await _tap(tester, find.byKey(const ValueKey('go')));
        await _tap(tester, find.byKey(const ValueKey('online-selfie-later')));
        expect(find.byType(AlertDialog), findsNothing);
        expect(_state(tester), 'OFFLINE');
        expect(repo.log, ['skip not_now']);
      });

      testWidgets('the time runs out: offline, and a modal says so', (tester) async {
        final repo = _Repo();
        await _pump(tester, const _GoOnline(), b: b, overrides: _phone(repo));
        await _tap(tester, find.byKey(const ValueKey('go')));
        await tester.pump(const Duration(minutes: 3, seconds: 1));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('online-selfie-ask')), findsNothing);
        expect(find.text('Time is up'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('notice-ok')));
        expect(_state(tester), 'OFFLINE');
        expect(repo.log, ['skip timeout']);
      });

      testWidgets('a low match still goes online', (tester) async {
        final repo = _Repo(
          results: const [
            {'face_state': 'pending'},
            {'face_state': 'no_match', 'face_score': 41, 'low_match': true},
          ],
        );
        await _pump(tester, const _GoOnline(), b: b, overrides: _phone(repo));
        await _tap(tester, find.byKey(const ValueKey('go')));
        await _tap(tester, find.byKey(const ValueKey('online-selfie-take')));
        expect(find.byKey(const ValueKey('online-selfie-result-low')), findsOneWidget);
        expect(find.text('Low match'), findsOneWidget);
        expect(find.text('Saved for the admin to check. You are online.'), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(AlertDialog)), isEmpty);
        await _tap(tester, find.byKey(const ValueKey('online-selfie-start')));
        expect(_state(tester), 'ONLINE', reason: 'never held');
      });

      testWidgets('no face provider: not checked, online', (tester) async {
        final repo = _Repo(
          results: const [
            {'face_state': 'not_checked', 'face_reason': 'no_aws_key'},
          ],
        );
        await _pump(tester, const _GoOnline(), b: b, overrides: _phone(repo));
        await _tap(tester, find.byKey(const ValueKey('go')));
        await _tap(tester, find.byKey(const ValueKey('online-selfie-take')));
        expect(find.text('Not checked'), findsOneWidget);
        expect(find.text('Saved for the admin to compare. You are online.'), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(AlertDialog)), isEmpty);
        await _tap(tester, find.byKey(const ValueKey('online-selfie-start')));
        expect(_state(tester), 'ONLINE');
      });

      testWidgets("a selfie that can't be sent keeps them offline, in a modal", (tester) async {
        final repo = _Repo(submitError: StateError('The time to answer ran out. Tap Go online to try again.'));
        await _pump(tester, const _GoOnline(), b: b, overrides: _phone(repo));
        await _tap(tester, find.byKey(const ValueKey('go')));
        await _tap(tester, find.byKey(const ValueKey('online-selfie-take')));
        expect(find.text("Couldn't send the selfie"), findsOneWidget);
        expect(find.text('The time to answer ran out. Tap Go online to try again.'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('notice-ok')));
        expect(_state(tester), 'OFFLINE');
      });

      testWidgets('the camera closed without a selfie: offline', (tester) async {
        final repo = _Repo();
        await _pump(
          tester,
          const _GoOnline(),
          b: b,
          overrides: _phone(repo, taker: (_, _) async => null),
        );
        await _tap(tester, find.byKey(const ValueKey('go')));
        await _tap(tester, find.byKey(const ValueKey('online-selfie-take')));
        expect(_state(tester), 'OFFLINE');
        expect(repo.log, ['skip not_now']);
      });

      testWidgets('the web: nothing asked, or told to finish on the phone', (tester) async {
        final none = _Repo(due: OnlineSelfieDue.none);
        await _pump(
          tester,
          const _GoOnline(),
          b: b,
          overrides: _phone(none, platform: 'web'),
        );
        await _tap(tester, find.byKey(const ValueKey('go')));
        expect(find.byType(AlertDialog), findsNothing);
        expect(_state(tester), 'ONLINE');
        expect(none.platform, 'web');

        final held = _Repo(
          due: const OnlineSelfieDue(due: false, blocked: true, message: 'A selfie check is waiting on your phone.'),
        );
        await _pump(
          tester,
          const _GoOnline(),
          b: b,
          overrides: _phone(held, platform: 'web'),
        );
        await _tap(tester, find.byKey(const ValueKey('go')));
        expect(find.text('Selfie check on your phone'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('notice-ok')));
        expect(_state(tester), 'OFFLINE');
      });

      testWidgets("the admin's settings: random, the threshold, selected admins, time to answer", (tester) async {
        final repo = _Repo();
        await _pump(
          tester,
          const SelfieChecksSettingsTab(),
          b: b,
          overrides: [onlineSelfieRepositoryProvider.overrideWithValue(repo)],
        );
        expect(find.text('On a new phone (mobile only)'), findsOneWidget);
        expect(find.text('Always'), findsOneWidget);
        expect(find.text('Goes online · push alert sent'), findsOneWidget);
        expect(find.text('3 minutes, then stays offline'), findsOneWidget);
        expect(unreadableTexts(tester, find.byKey(const ValueKey('selfie-settings'))), isEmpty);

        await tester.enterText(find.byKey(const ValueKey('selfie-random-pct')), '150');
        await _tap(tester, find.byKey(const ValueKey('selfie-save')));
        expect(find.text('Give a chance from 0 to 100%.'), findsOneWidget, reason: 'a modal, not a bar');
        await _tap(tester, find.byKey(const ValueKey('notice-ok')));

        await tester.enterText(find.byKey(const ValueKey('selfie-random-pct')), '30');
        await tester.enterText(find.byKey(const ValueKey('selfie-low-below')), '55');
        await _tap(tester, find.byKey(const ValueKey('selfie-alert-selected')));
        expect(find.text('Only the admins you pick.'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('selfie-admin-add')));
        await _tap(tester, find.text('Test Ops'));
        expect(find.byKey(const ValueKey('selfie-admin-admin-2')), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('selfie-answer')));
        await _tap(tester, find.text('5 minutes, then stays offline').last);
        await _tap(tester, find.byKey(const ValueKey('selfie-save')));
        expect(find.text('Saved'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('notice-ok')));
        expect(
          repo.cfg,
          const OnlineSelfieConfig(
            randomPct: 30,
            lowBelow: 55,
            alertTo: AlertTo.selected,
            alertAdmins: ['admin-2'],
            answerSeconds: 300,
          ),
        );

        await _tap(tester, find.byKey(const ValueKey('selfie-random')));
        expect(
          tester.widget<TextFormField>(find.byKey(const ValueKey('selfie-random-pct'))).enabled,
          isFalse,
          reason: 'the chance waits for random to be on',
        );
        await _tap(tester, find.byKey(const ValueKey('selfie-watch-list')));
        expect(find.text('watch list page'), findsOneWidget);
      });

      testWidgets('read-only: the settings show, nothing changes', (tester) async {
        await _pump(
          tester,
          const SelfieChecksSettingsTab(),
          b: b,
          overrides: [onlineSelfieRepositoryProvider.overrideWithValue(_Repo())],
          grants: const [AdminGrant(page: dispatchSelfiePage, edit: false)],
        );
        expect(find.byKey(const ValueKey('selfie-save')), findsNothing);
        expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('selfie-random'))).onChanged, isNull);
      });

      testWidgets('the watch-list rule dialog: a reason, the rule, an end date', (tester) async {
        WatchDialogResult? got;
        await _pump(
          tester,
          Builder(
            builder: (context) => FilledButton(
              key: const ValueKey('open'),
              onPressed: () async => got = await showWatchRuleDialog(context, name: 'Test Partner'),
              child: const Text('open'),
            ),
          ),
          b: b,
        );
        await _tap(tester, find.byKey(const ValueKey('open')));
        expect(find.text('Add to the watch list'), findsOneWidget);
        expect(find.byKey(const ValueKey('watch-remove')), findsNothing);
        expect(unreadableTexts(tester, find.byType(AlertDialog)), isEmpty);
        await _tap(tester, find.byKey(const ValueKey('watch-save')));
        expect(find.text('Say why they are on the watch list.'), findsOneWidget);

        await _tap(tester, find.byKey(const ValueKey('watch-rule-percent')));
        await tester.enterText(find.byKey(const ValueKey('watch-pct')), '40');
        await tester.enterText(find.byKey(const ValueKey('watch-cap')), '2');
        final year = DateTime.now().year + 1;
        await tester.enterText(find.byKey(const ValueKey('date-box-day')), '30');
        await tester.enterText(find.byKey(const ValueKey('date-box-month')), '11');
        await tester.enterText(find.byKey(const ValueKey('date-box-year')), '$year');
        await tester.enterText(find.byKey(const ValueKey('watch-reason')), 'Two low matches this week');
        await tester.pumpAndSettle();
        await _tap(tester, find.byKey(const ValueKey('watch-save')));
        expect(got?.remove, isFalse);
        expect(got?.entry?.rule, WatchRule.percent);
        expect([got?.entry?.pct, got?.entry?.cap], [40, 2]);
        expect(got?.entry?.until, '$year-11-30');
        expect(got?.entry?.reason, 'Two low matches this week');
      });

      testWidgets('the watch list: each with its rule; change or remove', (tester) async {
        final repo = _Repo(
          watch: [
            {
              'profile_id': _partner,
              'partner_id': 'partner-1',
              'name': 'Test Partner',
              'phone': '+60110000290',
              'rule': 'every',
              'until': '2026-11-30',
              'reason': 'Reported by a rider: different driver at pickup',
              'active': true,
              'added_by_name': 'Test Owner',
              'added_at': '2026-10-20T08:00:00Z',
            },
          ],
        );
        await _pump(
          tester,
          const SelfieWatchListScreen(),
          b: b,
          overrides: [onlineSelfieRepositoryProvider.overrideWithValue(repo)],
        );
        expect(find.text('Test Partner'), findsOneWidget);
        expect(find.textContaining('Every go-online · until'), findsOneWidget);
        expect(find.textContaining('Reported by a rider'), findsOneWidget);
        expect(find.byKey(const ValueKey('watch-add')), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(Scaffold).last), isEmpty);
        await _tap(tester, find.byKey(const ValueKey('watch-row-$_partner')));
        expect(find.byKey(const ValueKey('watch-remove')), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('watch-remove')));
        expect(find.text('Test Partner is back on the normal rule.'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('notice-ok')));
        expect(repo.log, ['unwatch $_partner']);
      });

      testWidgets("the alert's page: the match, Call, Go offline, Add to watch list, Looked at it", (tester) async {
        final repo = _Repo(one: _row());
        final remote = _Remote();
        final dialled = <Uri>[];
        await _pump(
          tester,
          const OnlineSelfieCheckScreen(id: _check),
          b: b,
          size: const Size(500, 1600),
          overrides: [
            onlineSelfieRepositoryProvider.overrideWithValue(repo),
            partnerRemoteRepositoryProvider.overrideWithValue(remote),
            adminDialerProvider.overrideWithValue((u) async {
              dialled.add(u);
              return true;
            }),
          ],
        );
        expect(find.text('Test Partner'), findsOneWidget);
        expect(find.byKey(const ValueKey('online-selfie-closer')), findsOneWidget);
        expect(find.textContaining('Low selfie match: 41%, below 60%'), findsOneWidget);
        expect(find.text('New phone'), findsOneWidget);
        expect(find.text('Test Phone B'), findsOneWidget);
        expect(find.text('Faces differ: 41% match · AWS'), findsOneWidget);
        expect(find.text('Live: blinked'), findsOneWidget);
        expect(find.text('None on record'), findsNWidgets(3));
        expect(unreadableTexts(tester, find.byKey(const ValueKey('online-selfie-check'))), isEmpty);

        await _tap(tester, find.byKey(const ValueKey('selfie-call')));
        expect(dialled.single.toString(), 'tel:+60110000290');

        await _tap(tester, find.byKey(const ValueKey('selfie-go-offline')));
        await _tap(tester, find.byKey(const ValueKey('selfie-go-offline-yes')));
        expect(remote.asked, ['$_partner go_offline']);
        expect(find.text("Asked Test Partner's phone to go offline."), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('notice-ok')));

        await _tap(tester, find.byKey(const ValueKey('selfie-watch')));
        await tester.enterText(find.byKey(const ValueKey('watch-reason')), 'Low match on a new phone');
        await _tap(tester, find.byKey(const ValueKey('watch-save')));
        await _tap(tester, find.byKey(const ValueKey('notice-ok')));
        expect(repo.log.last, 'watch $_partner every 50 3 - Low match on a new phone $_check');

        await _tap(tester, find.byKey(const ValueKey('selfie-looked')));
        await tester.enterText(find.byKey(const ValueKey('selfie-looked-note')), 'Called them');
        await _tap(tester, find.byKey(const ValueKey('selfie-looked-save')));
        expect(repo.log.last, 'review $_check Called them');
      });

      testWidgets('an admin who only reads sees the check, without the buttons that change things', (tester) async {
        await _pump(
          tester,
          const OnlineSelfieCheckScreen(id: _check),
          b: b,
          size: const Size(500, 1600),
          overrides: [onlineSelfieRepositoryProvider.overrideWithValue(_Repo(one: _row()))],
          grants: const [AdminGrant(page: 'admin-documents', edit: false)],
        );
        expect(find.byKey(const ValueKey('selfie-call')), findsOneWidget);
        expect(find.byKey(const ValueKey('selfie-go-offline')), findsNothing);
        expect(find.byKey(const ValueKey('selfie-watch')), findsNothing);
        expect(find.byKey(const ValueKey('selfie-looked')), findsNothing);
      });

      testWidgets('Sign-in checks: low matches first, as "Needs a closer look"', (tester) async {
        final repo = _Repo(
          rows: [
            _row(id: 'calm-1', name: 'Calm Partner', score: 93, closer: false, createdAt: '2026-10-24T10:00:00Z'),
            _row(),
          ],
        );
        await _pump(
          tester,
          const SignInChecksReview(),
          b: b,
          overrides: [
            onlineSelfieRepositoryProvider.overrideWithValue(repo),
            identityRepositoryProvider.overrideWithValue(_Identity()),
          ],
        );
        // Waiting: the low match above the uploads waiting for approval.
        final tiles = find.byType(ListTile);
        expect(tester.widget<ListTile>(tiles.at(0)).key, const ValueKey('online-check-$_check'));
        expect(tester.widget<ListTile>(tiles.at(1)).key, const ValueKey('signin-check-upload-1'));
        expect(find.text('Calm Partner'), findsNothing);
        expect(find.text('Needs a closer look'), findsOneWidget);
        expect(find.text('Going online (1 to look at)'), findsOneWidget);

        await _tap(tester, find.text('Going online (1 to look at)'));
        expect(find.text('Calm Partner'), findsOneWidget);
        expect(find.text('Test Staff'), findsNothing, reason: 'only the going-online checks');
        expect(unreadableTexts(tester, find.byType(ListView)), isEmpty);

        await _tap(tester, find.text('All'));
        expect(tester.widget<ListTile>(find.byType(ListTile).at(0)).key, const ValueKey('online-check-$_check'));
        await _tap(tester, find.text('Test Partner'));
        expect(find.text('check page $_check'), findsOneWidget);
      });

      testWidgets("Edit Partner: the partner's recent checks and the watch list", (tester) async {
        final repo = _Repo(
          rows: [_row()],
          watch: [
            {
              'profile_id': _partner,
              'rule': 'hours',
              'hours': 8,
              'reason': 'New phone twice in a month',
              'active': true,
            },
          ],
        );
        await _pump(
          tester,
          const SingleChildScrollView(
            child: PartnerSelfieChecksCard(userId: _partner, name: 'Test Partner'),
          ),
          b: b,
          overrides: [onlineSelfieRepositoryProvider.overrideWithValue(repo)],
        );
        expect(find.text('Selfie checks when going online'), findsOneWidget);
        expect(find.text('On the watch list: Every 8 hours online. New phone twice in a month'), findsOneWidget);
        expect(find.text('New phone'), findsOneWidget);
        expect(find.text('Needs a closer look'), findsOneWidget);
        expect(unreadableTexts(tester, find.byKey(const ValueKey('partner-selfie-checks'))), isEmpty);
        await _tap(tester, find.byKey(const ValueKey('partner-selfie-watch')));
        expect(find.text('Watch list: Test Partner'), findsOneWidget);
        await _tap(tester, find.text('Cancel'));
      });
    });
  }

  test('the selfie camera is opened only by the go-online check (no file)', () {
    // The taker the app uses by default is the live camera.
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(onlineSelfieTakerProvider), same(takeLiveSelfieBefore));
  });

  testWidgets('the camera is closed when the time runs out', (tester) async {
    var done = false;
    LiveSelfie? got;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            key: const ValueKey('open'),
            onPressed: () async {
              got = await takeLiveSelfieBefore(context, DateTime.now().add(const Duration(seconds: 5)));
              done = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LiveSelfieScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(LiveSelfieScreen), findsNothing);
    expect(done, isTrue);
    expect(got, isNull);
  });
}
