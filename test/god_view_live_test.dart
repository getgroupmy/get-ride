// God View 0282 (lib/src/core/god_view_live.dart, lib/src/admin/screens/
// god_view_screen.dart): the live share's countdown and stage from its rows,
// the points as they come, the details' freshness and a number change's
// line; and the page with a fake repository in light and dark: Update and
// its answer (or none), greyed out for a phone already live; the pencil by
// Phone and the "waiting for SMS confirm" line; Live now off, starting,
// live with its countdown, badge and pulse, no answer, and Stop. Also the
// person's "Shared live with support" notice and the SMS link's page.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/phone_details_data.dart';
import 'package:get_ride/src/admin/screens/god_view_screen.dart';
import 'package:get_ride/src/admin/screens/people/partner_live.dart';
import 'package:get_ride/src/admin/screens/people/partner_screens.dart' show partnerLiveProvider;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/god_view.dart';
import 'package:get_ride/src/core/god_view_live.dart';
import 'package:get_ride/src/core/god_view_trail.dart';
import 'package:get_ride/src/data/app_version_repository.dart';
import 'package:get_ride/src/data/god_view_repository.dart';
import 'package:get_ride/src/data/live_share.dart';
import 'package:get_ride/src/features/settings/confirm_number_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));
final _t0 = DateTime.utc(2026, 10, 24, 4);

/// A share of d9 started [started] after the test's time, for [length].
GodViewLiveSession _s({Duration started = Duration.zero, Duration length = const Duration(minutes: 15), DateTime? first}) =>
    GodViewLiveSession(
      id: 'live-1',
      profileId: 'd9',
      startedAt: _t0.add(started),
      endsAt: _t0.add(started).add(length),
      firstPointAt: first,
      lastPointAt: first,
    );

GodViewPerson _p(String id, GodViewStatus s, String name) =>
    GodViewPerson(kind: GodViewKind.partner, id: id, status: s, lat: 3.1, lng: 101.6, name: name, updatedAt: _t0,
        partnerRowId: 'row-$id');

final _people = [
  _p('d9', GodViewStatus.alwaysOn, 'Chong W.'),
  _p('d1', GodViewStatus.free, 'Hafiz R.'),
];

class _FakeRepo extends GodViewRepository {
  _FakeRepo() : super(null);
  DateTime Function() clock = () => _t0;

  final pinged = <String>[];
  GodViewPingResult pingResult = GodViewPingResult(phones: 1, sent: 1, posted: true, sentAt: _t0);
  final detailAnswers = <bool>[];
  int detailAsks = 0;

  GodViewLiveSession? session;
  final started = <(String, int)>[];
  final stopped = <String>[];
  final points = StreamController<GodViewLivePoint>.broadcast();

  final phoneChanges = <(String, String)>[];
  PhoneChangeStatus? change;

  @override
  Future<GodViewSnapshot> snapshot({
    ({double minLat, double minLng, double maxLat, double maxLng})? box,
    bool showOffline = true,
    String query = '',
    int limit = 1500,
  }) async =>
      GodViewSnapshot(at: _t0, people: _people, counts: const GodViewCounts(), total: _people.length, query: query);

  @override
  Future<List<GodViewUnlocated>> unlocated({String query = '', int limit = 500}) async => const [];

  @override
  Future<GodViewPingResult> ping(String profileId) async {
    pinged.add(profileId);
    return pingResult;
  }

  @override
  Future<({bool details, DateTime? at})> detailsAnswer(String profileId, DateTime since) async {
    detailAsks++;
    final yes = detailAnswers.isNotEmpty && detailAnswers.removeAt(0);
    return (details: yes, at: yes ? clock() : null);
  }

  @override
  Future<GodViewLiveStart> liveStart(String profileId, int minutes) async {
    started.add((profileId, minutes));
    session = GodViewLiveSession(
      id: 'live-1',
      profileId: profileId,
      startedAt: clock(),
      endsAt: clock().add(Duration(minutes: minutes)),
    );
    return GodViewLiveStart(session: session, phones: 1, posted: true);
  }

  @override
  Future<GodViewLiveSession?> liveStop(String sessionId) async {
    stopped.add(sessionId);
    final s = session!;
    session = GodViewLiveSession(
        id: s.id, profileId: s.profileId, startedAt: s.startedAt, endsAt: s.endsAt, stoppedAt: clock());
    return session;
  }

  @override
  Future<({GodViewLiveSession? session, List<GodViewLivePoint> points, DateTime? serverNow})> liveStatus(
    String profileId, {
    int after = 0,
  }) async => (session: session, points: const <GodViewLivePoint>[], serverNow: clock());

  @override
  Stream<GodViewLivePoint> livePoints(String sessionId) => points.stream;

  @override
  Future<PhoneChangeStatus?> phoneChange(String profileId, String phone) async {
    phoneChanges.add((profileId, phone));
    return change = const PhoneChangeStatus(status: 'waiting', phoneTail: '6789');
  }

  @override
  Future<PhoneChangeStatus?> phoneChangeStatus(String profileId) async => change;
}

class _FakePhones extends PhoneDetailsRepository {
  _FakePhones() : super(null);
  int loads = 0;

  @override
  Future<({List<Map<String, dynamic>> sessions, List<Map<String, dynamic>> tokens})> load(String profileId) async {
    loads++;
    return (
      sessions: [
        {
          'captured_at': _t0.subtract(const Duration(hours: 2)).toIso8601String(),
          'device_id': 'dev-1',
          'os_name': 'android',
          'device_model_name': 'SM-A546E',
          'raw': {'battery_pct': loads > 1 ? 41 : 80},
        },
      ],
      tokens: const <Map<String, dynamic>>[],
    );
  }
}

Future<({_FakeRepo repo, _FakePhones phones})> _pump(
  WidgetTester tester, {
  Brightness b = Brightness.light,
  List<AdminGrant> grants = const [AdminGrant(page: '*', edit: true)],
  bool still = false,
  DateTime Function()? clock,
}) async {
  final repo = _FakeRepo();
  final phones = _FakePhones();
  if (clock != null) repo.clock = clock;
  await tester.binding.setSurfaceSize(const Size(1400, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        ...quietLiveOverrides,
        adminAccessProvider.overrideWith((_) async => AdminAccess(grants)),
        godViewRepositoryProvider.overrideWithValue(repo),
        godViewPollProvider.overrideWithValue(null),
        godViewPingPollProvider.overrideWithValue(const Duration(seconds: 5)),
        godViewLivePollProvider.overrideWithValue(const Duration(seconds: 5)),
        godViewClockProvider.overrideWithValue(() => repo.clock()),
        partnerLiveProvider.overrideWith((ref, k) async => (status: PartnerLive.trip, detail: 'Ongoing', ride: null)),
        appVersionRulesProvider.overrideWith((_) async => const []),
        phoneDetailsRepositoryProvider.overrideWithValue(phones),
      ],
      child: MaterialApp(
        theme: appTheme(b),
        builder: (c, child) =>
            still ? MediaQuery(data: MediaQuery.of(c).copyWith(disableAnimations: true), child: child!) : child!,
        home: const GodViewScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return (repo: repo, phones: phones);
}

Future<void> _open(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('god-view-row-$id')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

String _text(WidgetTester tester, String key) {
  final f = find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text));
  return tester.widgetList<Text>(f.evaluate().isEmpty ? find.byKey(ValueKey(key)) : f).map((t) => t.data).join(' ');
}

void main() {
  group('live logic', () {
    test('the countdown: minutes and seconds, rounded up, never below 0', () {
      final end = _t0.add(const Duration(minutes: 15));
      expect(godViewLiveLeft(end, _t0), '15:00');
      expect(godViewLiveLeft(end, _t0.add(const Duration(seconds: 5))), '14:55');
      expect(godViewLiveLeft(end, _t0.add(const Duration(minutes: 14, seconds: 53, milliseconds: 400))), '0:07');
      expect(godViewLiveLeft(_t0.add(const Duration(hours: 1)), _t0), '60:00');
      expect(godViewLiveLeft(end, end.add(const Duration(seconds: 3))), '0:00');
      expect(godViewLiveStopLabel(end, _t0.add(const Duration(seconds: 5))), 'Stop live · 14:55 left');
      expect(liveShareNoticeText(end, _t0), 'Shared live with support · 15:00 left');
      expect([for (final m in godViewLiveChoices) godViewLiveChoiceLabel(m)], ['5 min', '15 min', '1 hour']);
    });

    test('the stage from the rows: off, starting, live, no answer, over', () {
      expect(godViewLiveStageOf(null, _t0), GodViewLiveStage.off);
      final s = _s();
      expect(godViewLiveStageOf(s, _t0.add(const Duration(seconds: 10))), GodViewLiveStage.starting);
      expect(godViewLiveStageOf(s, _t0.add(const Duration(seconds: 20))), GodViewLiveStage.noAnswer);
      final live = _s(first: _t0.add(const Duration(seconds: 3)));
      expect(godViewLiveStageOf(live, _t0.add(const Duration(minutes: 5))), GodViewLiveStage.live);
      expect(godViewLiveStageOf(live, _t0.add(const Duration(minutes: 15))), GodViewLiveStage.off, reason: 'over');
      final stopped = GodViewLiveSession.fromJson({
        'id': 'x', 'profile_id': 'p', 'started_at': '2026-10-24T04:00:00Z', 'ends_at': '2026-10-24T04:15:00Z',
        'stopped_at': '2026-10-24T04:02:00Z', 'first_point_at': '2026-10-24T04:00:04Z', 'points': 20,
      })!;
      expect((stopped.points, stopped.firstPointAt), (20, DateTime.utc(2026, 10, 24, 4, 0, 4)));
      expect(godViewLiveStageOf(stopped, _t0.add(const Duration(minutes: 1))), GodViewLiveStage.off);
      expect(GodViewLiveSession.fromJson(null), isNull);
      expect(GodViewLiveSession.fromJson(const {'id': 'x'}), isNull);
    });

    test('the points: from the status and from realtime, each once, in order; the first starts it', () {
      final a = GodViewLivePoint.fromJson([7, 3.1, 101.6, 1792900800, 4.5])!;
      expect((a.id, a.point.lat, a.point.speed), (7, 3.1, 4.5));
      final b = GodViewLivePoint.fromRow({'id': 9, 'lat': 3.2, 'lng': 101.7, 'captured_at': '2026-10-24T04:00:10Z'})!;
      expect(b.point.at, DateTime.utc(2026, 10, 24, 4, 0, 10));
      expect(GodViewLivePoint.fromJson([1, 2]), isNull);
      expect(GodViewLivePoint.fromRow(const {'id': 1}), isNull);
      final v = GodViewLiveView(personId: 'd9', session: _s()).withPoints([b, a, b]);
      expect([for (final p in v.points) p.id], [7, 9]);
      expect(v.lastId, 9);
      expect(v.latest!.lat, 3.2);
      expect(v.stageAt(_t0.add(const Duration(seconds: 30))), GodViewLiveStage.live, reason: 'a point came');
      // The admin's clock 10 s behind the server's.
      final skewed = GodViewLiveView(personId: 'd9', session: _s(), skew: const Duration(seconds: 10));
      expect(skewed.stageAt(_t0.add(const Duration(seconds: 12))), GodViewLiveStage.noAnswer);
    });

    test('a start that did not start says why', () {
      expect(GodViewLiveStart.fromJson(const {'phones': 0, 'session': null}).problem, contains('No phone to go live'));
      expect(GodViewLiveStart.fromJson(const {}).problem, 'Live could not be started. Try again later.');
      final ok = GodViewLiveStart.fromJson({
        'phones': 1, 'posted': true,
        'session': {'id': 'x', 'started_at': '2026-10-24T04:00:00Z', 'ends_at': '2026-10-24T04:05:00Z'},
      });
      expect((ok.problem, ok.session?.id), (null, 'x'));
      final already = GodViewLiveStart.fromJson({
        'already': true,
        'session': {'id': 'y', 'started_at': '2026-10-24T04:00:00Z', 'ends_at': '2026-10-24T04:05:00Z'},
      });
      expect((already.already, already.problem), (true, null));
    });

    test('details freshness: just now for a minute, then the age', () {
      expect(godViewUpdatedLabel(_t0, _t0.add(const Duration(seconds: 40))), 'Updated just now');
      expect(godViewUpdatedLabel(_t0, _t0.add(const Duration(minutes: 3))), 'Updated 3 min ago');
      expect(godViewUpdateLine(GodViewUpdateStage.updated, at: _t0, now: _t0), 'Updated just now');
      expect(godViewUpdateLine(GodViewUpdateStage.noAnswer), startsWith('No answer.'));
      expect(godViewUpdateLine(GodViewUpdateStage.waiting), 'Asking the phone…');
    });

    test('a number change: waiting, confirmed for a day, expired', () {
      final w = PhoneChangeStatus.fromJson(const {'status': 'waiting', 'phone_tail': '6789'});
      expect(phoneChangeLine(w, _t0), 'New number ending 6789: waiting for SMS confirm');
      final c = PhoneChangeStatus.fromJson({'status': 'confirmed', 'phone_tail': '6789', 'confirmed_at': _t0.toIso8601String()});
      expect(phoneChangeLine(c, _t0.add(const Duration(hours: 2))), 'Changed to the number ending 6789. The old number no longer signs in.');
      expect(phoneChangeLine(c, _t0.add(const Duration(days: 2))), isNull);
      expect(phoneChangeLine(PhoneChangeStatus.fromJson(const {'status': 'expired'}), _t0), contains('expired'));
      expect(phoneChangeLine(PhoneChangeStatus.fromJson(const {'status': 'cancelled'}), _t0), isNull);
      expect(PhoneChangeStatus.fromJson(null), isNull);
    });
  });

  group('page', () {
    for (final b in Brightness.values) {
      testWidgets('Update: asks the phone, then "Updated just now" and the facts read again (${b.name})', (tester) async {
        final f = await _pump(tester, b: b);
        await _open(tester, 'd9');
        expect(find.byKey(const ValueKey('god-view-phone-report')), findsOneWidget);
        final loadsBefore = f.phones.loads;
        f.repo.detailAnswers.addAll([false, true]);
        await tester.tap(find.byKey(const ValueKey('god-view-update')));
        await tester.pump();
        expect(f.repo.pinged, ['d9']);
        expect(_text(tester, 'god-view-update-line'), 'Asking the phone…');
        await tester.pump(const Duration(seconds: 5));
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(_text(tester, 'god-view-update-line'), 'Updated just now');
        expect(f.phones.loads, greaterThan(loadsBefore), reason: 'the card reads the fresh row');
        expect(find.text('41%'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('Update: no answer after the wait (${b.name})', (tester) async {
        final f = await _pump(tester, b: b);
        await _open(tester, 'd9');
        await tester.tap(find.byKey(const ValueKey('god-view-update')));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(seconds: 5));
        }
        expect(f.repo.detailAsks, 9);
        expect(_text(tester, 'god-view-update-line'), startsWith('No answer.'));
      });
    }

    testWidgets('Update is greyed out, with the reason, for a phone already live', (tester) async {
      await _pump(tester);
      await _open(tester, 'd1');
      final button = tester.widget<TextButton>(find.byKey(const ValueKey('god-view-update')));
      expect(button.onPressed, isNull);
      expect(_text(tester, 'god-view-update-line'), 'App open: location updates live.');
    });

    for (final b in Brightness.values) {
      testWidgets('the pencil by Phone: a new number, then waiting for SMS confirm (${b.name})', (tester) async {
        final f = await _pump(tester, b: b);
        await _open(tester, 'd9');
        await tester.tap(find.byKey(const ValueKey('god-view-edit-phone')));
        await tester.pumpAndSettle();
        final send = find.byKey(const ValueKey('god-view-edit-phone-send'));
        expect(tester.widget<FilledButton>(send).onPressed, isNull, reason: 'no number yet');
        await tester.enterText(find.byKey(const ValueKey('god-view-edit-phone-number')), '0123456789');
        await tester.pump();
        await tester.tap(send);
        await tester.pumpAndSettle();
        expect(f.repo.phoneChanges, [('d9', '+60123456789')], reason: 'the leading 0 dropped, the country code added');
        expect(_text(tester, 'god-view-phone-change'), 'New number ending 6789: waiting for SMS confirm');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('no pencil without EDIT on the Users pages', (tester) async {
      await _pump(tester, grants: const [AdminGrant(page: godViewPage, edit: false), AdminGrant(page: 'admin-users', edit: false)]);
      await _open(tester, 'd9');
      expect(find.byKey(const ValueKey('god-view-edit-phone')), findsNothing);
    });

    for (final b in Brightness.values) {
      testWidgets('Live now: off, starting, live with the countdown, then Stop (${b.name})', (tester) async {
        var now = _t0;
        final f = await _pump(tester, b: b, clock: () => now);
        await _open(tester, 'd9');
        // Off: the lengths and the button.
        expect(find.byKey(const ValueKey('god-view-live-15')), findsOneWidget);
        expect(find.byKey(const ValueKey('god-view-live-badge')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('god-view-live-60')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('god-view-live-15')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('god-view-live-start')));
        await tester.pump();
        await tester.pump();
        expect(f.repo.started, [('d9', 15)]);
        // Starting: Stop with the time left, waiting for the phone.
        expect(_text(tester, 'god-view-live-stop'), 'Stop live · 15:00 left');
        expect(_text(tester, 'god-view-live-line'), 'Waiting for their phone to start…');
        // A point arrives: live, the badge, the red pulsing marker.
        now = _t0.add(const Duration(seconds: 5));
        f.repo.points.add(GodViewLivePoint(1, TrailPoint(3.11, 101.61, now)));
        await tester.pump();
        await tester.pump();
        expect(_text(tester, 'god-view-live-stop'), 'Stop live · 14:55 left');
        expect(_text(tester, 'god-view-live-line'), startsWith('Live · every 5 s'));
        expect(find.byKey(const ValueKey('god-view-live-badge')), findsOneWidget);
        expect(find.byKey(const ValueKey('god-view-live-pulse')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('god-view-live-stop')));
        await tester.pump();
        await tester.pump();
        expect(f.repo.stopped, ['live-1']);
        expect(find.byKey(const ValueKey('god-view-live-start')), findsOneWidget);
        expect(find.byKey(const ValueKey('god-view-live-badge')), findsNothing);
      });

      testWidgets('Live now: no stream in 20 s says to open the app (${b.name})', (tester) async {
        var now = _t0;
        await _pump(tester, b: b, clock: () => now);
        await _open(tester, 'd9');
        await tester.tap(find.byKey(const ValueKey('god-view-live-start')));
        await tester.pump();
        await tester.pump();
        now = _t0.add(const Duration(seconds: 25));
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(_text(tester, 'god-view-live-line'), startsWith('Open the app on their phone to go live'));
        expect(_text(tester, 'god-view-live-stop'), 'Stop live · 14:35 left');
        expect(find.byKey(const ValueKey('god-view-live-badge')), findsOneWidget, reason: 'still on until it ends');
      });
    }

    testWidgets('Live now with reduced motion: red, still rings, no pulse', (tester) async {
      var now = _t0;
      final f = await _pump(tester, still: true, clock: () => now);
      await _open(tester, 'd9');
      await tester.tap(find.byKey(const ValueKey('god-view-live-start')));
      await tester.pump();
      await tester.pump();
      now = _t0.add(const Duration(seconds: 5));
      f.repo.points.add(GodViewLivePoint(1, TrailPoint(3.11, 101.61, now)));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('god-view-live-badge')), findsOneWidget);
      expect(find.byKey(const ValueKey('god-view-live-pulse')), findsNothing);
    });

    testWidgets('a share another admin started shows when the person is opened', (tester) async {
      var now = _t0.add(const Duration(minutes: 1));
      final f = await _pump(tester, clock: () => now);
      f.repo.session = _s(first: _t0.add(const Duration(seconds: 4)));
      await _open(tester, 'd9');
      await tester.pump();
      expect(_text(tester, 'god-view-live-stop'), 'Stop live · 14:00 left');
      now = now.add(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('god-view-live-badge')), findsOneWidget);
    });
  });

  group("the person's side", () {
    for (final b in Brightness.values) {
      testWidgets('"Shared live with support" with the time left (${b.name})', (tester) async {
        await tester.pumpWidget(ProviderScope(
          overrides: [
            liveShareProvider.overrideWith(() => _FixedShare(LiveShare(id: 's', endsAt: _t0.add(const Duration(minutes: 14, seconds: 55))))),
            liveShareClockProvider.overrideWithValue(() => _t0),
          ],
          child: MaterialApp(
            theme: appTheme(b),
            home: const LiveShareNotice(child: Scaffold(body: Center(child: Text('Home')))),
          ),
        ));
        await tester.pump();
        expect(find.text('Shared live with support · 14:55 left'), findsOneWidget);
        expect(find.text('Home'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('no notice without a share, or once it is over', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          liveShareProvider.overrideWith(() => _FixedShare(LiveShare(id: 's', endsAt: _t0.subtract(const Duration(seconds: 1))))),
          liveShareClockProvider.overrideWithValue(() => _t0),
        ],
        child: const MaterialApp(home: LiveShareNotice(child: Text('Home'))),
      ));
      await tester.pump();
      expect(find.byKey(const ValueKey('live-share-notice')), findsNothing);
    });

    for (final b in Brightness.values) {
      testWidgets('the SMS link: confirm the new number (${b.name})', (tester) async {
        final repo = _FakeLink();
        await tester.pumpWidget(ProviderScope(
          overrides: [numberChangeLinkRepositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(theme: appTheme(b), home: const ConfirmNumberScreen(token: 'tok-123456789012345678901')),
        ));
        await tester.pump();
        expect(find.text('Confirm your new number'), findsOneWidget);
        expect(find.textContaining('+60 ••• 6789'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('confirm-number-go')));
        await tester.pump();
        await tester.pump();
        expect(repo.confirmed, ['tok-123456789012345678901']);
        expect(find.text('Number confirmed'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the SMS link: expired or not valid', (tester) async {
      final repo = _FakeLink()..status = 'expired';
      await tester.pumpWidget(ProviderScope(
        overrides: [numberChangeLinkRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: ConfirmNumberScreen(token: 't')),
      ));
      await tester.pump();
      expect(find.text('This link has expired'), findsOneWidget);
      expect(find.byKey(const ValueKey('confirm-number-go')), findsNothing);
    });
  });
}

class _FixedShare extends LiveShareController {
  _FixedShare(this.share);
  final LiveShare share;

  @override
  LiveShare? build() => share;
}

class _FakeLink extends NumberChangeLinkRepository {
  _FakeLink() : super(null);
  String status = 'waiting';
  final confirmed = <String>[];

  @override
  Future<Map<String, dynamic>> lookup(String token) async => {'status': status, 'phone_masked': '+60 ••• 6789'};

  @override
  Future<Map<String, dynamic>> confirm(String token) async {
    confirmed.add(token);
    return {'status': 'confirmed', 'phone_masked': '+60 ••• 6789'};
  }
}
