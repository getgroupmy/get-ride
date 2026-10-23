// Admin → God View (lib/src/core/god_view.dart, lib/src/admin/screens/
// god_view_screen.dart): the status words and order, the filters and the
// search, a user in a ride drawn as their partner only, the stats and the
// legend, the 0272 statuses (always on, not responding, last known) and
// their ages, which actions an admin's grants show; and the page with a fake
// repository in light and dark, wide and on a phone, the phone hidden until
// Show, Suspend asking for a reason (and warning about a trip), Send push
// sending to one person; the "No location" section (0275) with its reasons;
// 0276: a quiet Always on phone's "Not moved since", "Ping now" and its
// answer, and the God View settings sheet.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/god_view_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/app_version.dart';
import 'package:get_ride/src/core/date_order.dart';
import 'package:get_ride/src/core/god_view.dart';
import 'package:get_ride/src/data/app_version_repository.dart';
import 'package:get_ride/src/data/god_view_repository.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));
final _now = DateTime.utc(2026, 10, 21, 8);

GodViewPerson _p(
  String id,
  GodViewStatus s, {
  GodViewKind kind = GodViewKind.partner,
  String? name,
  String? ride,
  String? plate,
  String? service,
  String? vehicle,
  String? area,
  int ageSeconds = 3,
  String? incident,
  String? partnerRow,
  double? nextLat,
  Duration? movedAgo,
}) => GodViewPerson(
  kind: kind,
  id: id,
  status: s,
  lat: 3.1,
  lng: 101.6,
  name: name ?? id,
  rideId: ride,
  rideCode: ride == null ? null : 'R-${ride.toUpperCase()}',
  plate: plate,
  service: service,
  vehicle: vehicle,
  area: area,
  updatedAt: _now.subtract(Duration(seconds: ageSeconds)),
  sos: s == GodViewStatus.sos,
  incidentId: incident,
  partnerRowId: partnerRow ?? (kind == GodViewKind.partner ? 'row-$id' : null),
  nextLat: nextLat,
  nextLng: nextLat == null ? null : 101.7,
  movedAt: movedAgo == null ? null : _now.subtract(movedAgo),
);

final _people = [
  _p('d1', GodViewStatus.free, name: 'Hafiz R.', plate: 'VJK 4821', vehicle: 'Perodua Bezza', area: 'Bukit Bintang'),
  _p('d2', GodViewStatus.pickup, name: 'Mei Ling T.', ride: '7q2k', plate: 'WXY 9033', nextLat: 3.2),
  _p('d3', GodViewStatus.trip, name: 'Kumar S.', ride: '5m8t', service: 'Motorcycle', nextLat: 3.0),
  _p('d6', GodViewStatus.lastKnown, name: 'Jason W.', ageSeconds: 2700),
  _p('d8', GodViewStatus.notResponding, name: 'Amir N.', ageSeconds: 10080),
  _p('d9', GodViewStatus.alwaysOn, name: 'Chong W.', ageSeconds: 600),
  _p('d7', GodViewStatus.sos, name: 'Rahim A.', ride: '9f1d', incident: 'inc-1'),
  _p('u1', GodViewStatus.searching, kind: GodViewKind.user, name: 'Aisyah F.', ride: '8k4a'),
  _p('u2', GodViewStatus.ride, kind: GodViewKind.user, name: 'Daniel L.', ride: '5m8t'),
  _p('u3', GodViewStatus.appOpen, kind: GodViewKind.user, name: 'Priya K.'),
  _p('u4', GodViewStatus.ride, kind: GodViewKind.user, name: 'Farah Z.', ride: '9f1d'),
  _p('u5', GodViewStatus.lastKnown, kind: GodViewKind.user, name: 'Tan B. H.', ageSeconds: 3 * 86400 + 60),
  _p('u6', GodViewStatus.alwaysOn, kind: GodViewKind.user, name: 'Siti A.', ageSeconds: 300,
      movedAgo: const Duration(hours: 2, minutes: 30)),
];

final _unlocated = [
  GodViewUnlocated.fromJson(const {'kind': 'partner', 'id': 'n1', 'partner_row_id': 'pr-n1', 'name': 'Nur Aina',
      'vehicle': 'Proton Saga', 'plate': 'NL 275', 'reason': 'no_app'}),
  GodViewUnlocated.fromJson(const {'kind': 'user', 'id': 'n2', 'name': 'Ong K.', 'reason': 'never_located',
      'app_version': '1.2.0', 'app_platform': 'android'}),
  GodViewUnlocated.fromJson(const {'kind': 'user', 'id': 'n3', 'name': 'Siti', 'reason': 'stale',
      'last_seen_at': '2026-10-01T04:00:00Z'}),
];

const _rules = [AppVersionRule(platform: 'Android', latest: '1.4.10')];

class _FakeRepo extends GodViewRepository {
  _FakeRepo() : super(null);
  final asked = <({bool offline, String query, bool box})>[];
  final askedUnlocated = <String>[];

  @override
  Future<List<GodViewUnlocated>> unlocated({String query = '', int limit = 500}) async {
    askedUnlocated.add(query);
    return _unlocated;
  }

  final revealed = <String>[];
  final suspended = <(String, String, String?)>[];
  final pushed = <(String, String, String)>[];
  bool onTrip = true;

  GodViewSettings settings = const GodViewSettings(editable: true);
  final saved = <GodViewSettings>[];
  final pinged = <String>[];
  GodViewPingResult pingResult = GodViewPingResult(phones: 1, sent: 1, posted: true, sentAt: _now);

  /// The answers to come, one per ask; then "not yet".
  final answers = <bool>[];
  int answerAsks = 0;

  @override
  Future<GodViewPingResult> ping(String profileId) async {
    pinged.add(profileId);
    return pingResult;
  }

  @override
  Future<({bool answered, DateTime? at})> pingAnswer(String profileId, DateTime since) async {
    answerAsks++;
    final yes = answers.isNotEmpty && answers.removeAt(0);
    return (answered: yes, at: yes ? _now : null);
  }

  @override
  Future<GodViewSettings> saveSettings(GodViewSettings s) async {
    saved.add(s);
    return s;
  }

  @override
  Future<GodViewSnapshot> snapshot({
    ({double minLat, double minLng, double maxLat, double maxLng})? box,
    bool showOffline = true,
    String query = '',
    int limit = 1500,
  }) async {
    asked.add((offline: showOffline, query: query, box: box != null));
    return GodViewSnapshot(
      at: _now,
      people: _people,
      counts: const GodViewCounts(
        partnersOnline: 4,
        partnersFree: 1,
        partnersOnJob: 3,
        partnersNotResponding: 1,
        partnersAlwaysOn: 1,
        partnersLastKnown: 1,
        usersSearching: 1,
        usersAppOpen: 1,
        usersAlwaysOn: 1,
        usersLastKnown: 1,
        sos: 1,
      ),
      total: _people.length,
      query: query,
      settings: settings,
    );
  }

  @override
  Future<String?> revealPhone(String profileId) async {
    revealed.add(profileId);
    return '+60 12-345 6789';
  }

  @override
  Future<bool> suspend(String profileId, String reason, {String? note}) async {
    suspended.add((profileId, reason, note));
    return onTrip;
  }

  @override
  Future<void> sendPush(String profileId, String title, String body) async => pushed.add((profileId, title, body));
}

Future<_FakeRepo> _pump(
  WidgetTester tester, {
  Brightness b = Brightness.light,
  Size size = const Size(1400, 900),
  List<AdminGrant> grants = const [AdminGrant(page: '*', edit: true)],
  _FakeRepo? fake,
}) async {
  final repo = fake ?? _FakeRepo();
  await tester.binding.setSurfaceSize(size);
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
        godViewClockProvider.overrideWithValue(() => _now),
        appVersionRulesProvider.overrideWith((_) async => _rules),
      ],
      child: MaterialApp(theme: appTheme(b), home: const GodViewScreen()),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return repo;
}

Future<void> _openDetails(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('god-view-row-$id')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('0276 logic', () {
    test('the settings: defaults, clamped, editable only when the server says', () {
      const d = GodViewSettings();
      expect((d.pings, d.pingMinutes, d.alwaysOnHours, d.editable), (true, 30, 12, false));
      final s = GodViewSettings.fromJson(const {'pings': false, 'pingMinutes': 5, 'alwaysOnHours': 99, 'editable': true});
      expect((s.pings, s.pingMinutes, s.alwaysOnHours, s.editable), (false, 10, 48, true));
      final odd = GodViewSettings.fromJson(const {'pings': 'yes', 'pingMinutes': '45', 'alwaysOnHours': 6.4});
      expect((odd.pings, odd.pingMinutes, odd.alwaysOnHours), (true, 30, 6));
      final snap = GodViewSnapshot.fromJson(const {
        'settings': {'pings': true, 'pingMinutes': 60, 'alwaysOnHours': 24, 'editable': false},
        'people': [
          {'id': 'x', 'kind': 'user', 'status': 'always_on', 'lat': 3, 'lng': 101, 'moved_at': '2026-10-21T05:00:00Z'},
        ],
      });
      expect((snap.settings.pingMinutes, snap.settings.alwaysOnHours), (60, 24));
      expect(snap.people.single.movedAt, DateTime.utc(2026, 10, 21, 5));
      expect(GodViewSnapshot.fromJson(const {}).settings.pingMinutes, 30, reason: 'a server before 0276');
      expect([for (final m in [10, 60, 90, 240]) godViewMinutesLabel(m)], ['10 min', '1 h', '1 h 30 min', '4 h']);
    });

    test('the clock and the date when not today', () {
      expect(godViewClock(DateTime(2026, 10, 21, 16, 31)), '4:31 PM');
      expect(godViewClock(DateTime(2026, 10, 21, 0, 5)), '12:05 AM');
      expect(godViewClock(DateTime(2026, 10, 21, 12)), '12:00 PM');
      final now = DateTime(2026, 10, 21, 18);
      expect(godViewWhen(DateTime(2026, 10, 21, 16, 31), now), '4:31 PM');
      expect(godViewWhen(DateTime(2026, 10, 20, 16, 31), now, order: DateOrder.dmy), '20/10/2026, 4:31 PM');
      expect(godViewWhen(DateTime(2026, 10, 20, 16, 31), now, order: DateOrder.mdy), '10/20/2026, 4:31 PM');
    });

    test('Not moved since: a quiet Always on phone only', () {
      final now = DateTime(2026, 10, 21, 18);
      GodViewPerson p(GodViewStatus s, {Duration? moved, Duration updated = const Duration(hours: 2)}) => GodViewPerson(
        kind: GodViewKind.user,
        id: 'q',
        status: s,
        lat: 3,
        lng: 101,
        updatedAt: now.subtract(updated),
        movedAt: moved == null ? null : now.subtract(moved),
      );
      expect(godViewNotMovedSince(p(GodViewStatus.alwaysOn, moved: const Duration(hours: 1, minutes: 29)), now),
          'Not moved since 4:31 PM');
      expect(godViewNotMovedSince(p(GodViewStatus.alwaysOn), now), 'Not moved since 4:00 PM',
          reason: 'no move known: the last report');
      expect(godViewNotMovedSince(p(GodViewStatus.alwaysOn, moved: const Duration(hours: 25)), now, order: DateOrder.dmy),
          'Not moved since 20/10/2026, 5:00 PM');
      expect(godViewNotMovedSince(p(GodViewStatus.alwaysOn, moved: const Duration(minutes: 10)), now), isNull,
          reason: 'moved in the last 30 minutes');
      expect(godViewNotMovedSince(p(GodViewStatus.lastKnown, moved: const Duration(hours: 13)), now), isNull);
      expect(godViewNotMovedSince(p(GodViewStatus.appOpen, moved: const Duration(hours: 3)), now), isNull);
    });

    test('Ping now: who, and what each answer says', () {
      GodViewPerson p(GodViewStatus s) => GodViewPerson(kind: GodViewKind.partner, id: 'p', status: s, lat: 0, lng: 0);
      expect([for (final s in GodViewStatus.values) if (godViewCanPing(p(s))) s],
          [GodViewStatus.notResponding, GodViewStatus.alwaysOn, GodViewStatus.lastKnown]);
      expect(godViewPingStageOf(const GodViewPingResult()), GodViewPingStage.noPhone);
      expect(godViewPingStageOf(const GodViewPingResult(phones: 2, recent: 2)), GodViewPingStage.recent);
      expect(godViewPingStageOf(const GodViewPingResult(phones: 1, sent: 1)), GodViewPingStage.failed,
          reason: 'not queued: no function configured');
      expect(godViewPingStageOf(const GodViewPingResult(phones: 2, sent: 1, recent: 1, posted: true)),
          GodViewPingStage.waiting);
      final r = GodViewPingResult.fromJson(const {
        'phones': 1, 'sent': 0, 'recent': 1, 'posted': false, 'retry_at': '2026-10-21T08:02:00Z',
      });
      expect((r.phones, r.sent, r.recent, r.retryAt), (1, 0, 1, DateTime.utc(2026, 10, 21, 8, 2)));
      expect(godViewPingLine(GodViewPingStage.waiting), startsWith('Ping sent…'));
      expect(godViewPingLine(GodViewPingStage.answered, at: DateTime(2026, 10, 21, 16, 35)),
          'The phone answered at 4:35 PM. Position updated.');
      expect(godViewPingLine(GodViewPingStage.recent, at: DateTime(2026, 10, 21, 16, 37)),
          'Pinged in the last 2 minutes. Try again after 4:37 PM.');
      expect(godViewPingLine(GodViewPingStage.noAnswer), startsWith('No answer yet.'));
      for (final s in GodViewPingStage.values) {
        expect(godViewPingLine(s), isNot(contains('→')));
      }
    });
  });

  group('logic', () {
    test('no location: the reasons', () {
      const dmy = DateOrder.dmy;
      String why(Map<String, dynamic> j, [List<AppVersionRule> rules = _rules]) =>
          godViewNoLocationReason(GodViewUnlocated.fromJson(j), rules, order: dmy);
      expect(why({'id': 'a', 'reason': 'no_app'}), "Hasn't opened the new app");
      expect(why({'id': 'a', 'reason': 'stale', 'last_seen_at': '2026-10-01T12:00:00Z'}), 'Last seen 01/10/2026');
      expect(why({'id': 'a', 'reason': 'never_located', 'app_version': '1.2.0', 'app_platform': 'android'}),
          'Old app version (1.2.0)');
      expect(why({'id': 'a', 'reason': 'never_located', 'app_version': '1.4.10', 'app_platform': 'android'}),
          'Location not allowed', reason: 'a current build reports unless location is off');
      expect(why({'id': 'a', 'reason': 'never_located', 'app_version': '1.2.0', 'token_platform': 'android'}),
          'Old app version (1.2.0)', reason: "the token's platform when the profile has none");
      expect(why({'id': 'a', 'reason': 'never_located', 'app_version': '1.2.0', 'app_platform': 'ios'}),
          'No location yet', reason: 'no rule for iPhones');
      expect(why({'id': 'a', 'reason': 'never_located'}), 'No location yet', reason: 'no version');
      expect(why({'id': 'a', 'reason': 'never_located', 'app_version': '1.2.0', 'app_platform': 'android'}, const []),
          'No location yet', reason: 'no rules');
      expect(GodViewNoLocation.parse('whatever'), GodViewNoLocation.neverLocated);
    });

    test('no location: the filters', () {
      expect(godViewUnlocatedShown(_unlocated, const GodViewFilters()).map((u) => u.id), ['n1', 'n2', 'n3']);
      expect(godViewUnlocatedShown(_unlocated, const GodViewFilters(partners: false)).map((u) => u.id), ['n2', 'n3']);
      expect(godViewUnlocatedShown(_unlocated, const GodViewFilters(users: false)).map((u) => u.id), ['n1']);
      expect(
        godViewUnlocatedShown(_unlocated, const GodViewFilters(userFilter: GodViewUserFilter.searching)).map((u) => u.id),
        ['n1'],
        reason: 'nobody without a location is searching',
      );
      final n1 = _unlocated.first;
      expect((n1.isPartner, n1.vehicleLine, n1.initials, n1.partnerRowId), (true, 'Proton Saga · NL 275', 'NA', 'pr-n1'));
    });

    test('status words, the pulse and the order', () {
      expect(GodViewStatus.parse('app_open'), GodViewStatus.appOpen);
      expect(GodViewStatus.parse('pickup').label, 'Going to pickup');
      expect(GodViewStatus.parse('always_on'), GodViewStatus.alwaysOn);
      expect(GodViewStatus.parse('not_responding'), GodViewStatus.notResponding);
      expect(GodViewStatus.parse('not_responding').label, 'Online, not responding');
      expect(GodViewStatus.parse('last_known'), GodViewStatus.lastKnown);
      expect(GodViewStatus.parse('offline'), GodViewStatus.lastKnown, reason: "0270's word");
      expect(GodViewStatus.parse('whatever'), GodViewStatus.lastKnown);
      expect(GodViewStatus.values.where((s) => s.pulses), [GodViewStatus.searching, GodViewStatus.sos]);
      expect(GodViewStatus.values.where((s) => s.isLastKnown), [GodViewStatus.lastKnown]);
      final order = godViewListOrder(_people).map((p) => p.id).toList();
      expect(order.first, 'd7', reason: 'SOS first');
      expect(order.indexOf('d2'), lessThan(order.indexOf('u1')));
      expect(order.indexOf('d1'), lessThan(order.indexOf('d8')), reason: 'free before not responding');
      expect(order.indexOf('u3'), lessThan(order.indexOf('u6')), reason: 'app open before always on');
      for (final live in ['d8', 'd9', 'u3', 'u6']) {
        expect(order.indexOf(live), lessThan(order.indexOf('d6')), reason: '$live before the last known');
      }
      expect(order.sublist(order.length - 2), ['d6', 'u5'], reason: 'last known last, the newest first');
    });

    test('rows from the server', () {
      final s = GodViewSnapshot.fromJson({
        'at': '2026-10-21T08:00:00Z',
        'total': 3,
        'omitted': 1,
        'scoped': true,
        'omitted_last_known': 1,
        'counts': {
          'partners_online': 2, 'users_app_open': 5, 'sos': 1, 'partners_not_responding': 3,
          'partners_always_on': 4, 'users_always_on': 6, 'partners_offline': 7, 'users_offline': 8,
        },
        'people': [
          {
            'kind': 'partner', 'id': 'a', 'partner_row_id': 'r', 'name': 'Ali', 'service': 'Motorcycle',
            'status': 'trip', 'lat': 3.1, 'lng': 101.6, 'updated_at': '2026-10-21T07:59:50Z',
            'ride_id': 'x', 'ride_code': 'R-ABC123', 'eta_min': 7, 'next_lat': 3.2, 'next_lng': 101.7, 'sos': false,
          },
          {'kind': 'user', 'id': 'b', 'status': 'app_open', 'lat': 3, 'lng': 101},
        ],
      }, query: 'ali');
      expect(s.people, hasLength(2));
      expect(s.people.first.serviceIcon, GodViewService.motorcycle);
      expect(s.people.first.nextPoint, (lat: 3.2, lng: 101.7));
      expect(s.people.last.status, GodViewStatus.appOpen);
      expect(s.people.last.displayName, 'User');
      expect(s.counts.usersAppOpen, 5);
      expect(
        (s.counts.partnersNotResponding, s.counts.partnersAlwaysOn, s.counts.usersAlwaysOn),
        (3, 4, 6),
      );
      expect((s.counts.partnersLastKnown, s.counts.usersLastKnown), (7, 8));
      expect((s.omitted, s.omittedLastKnown, s.scoped, s.query), (1, 1, true, 'ali'));
    });

    test('a partner''s icon by service', () {
      expect(godViewServiceOf('Car'), GodViewService.car);
      expect(godViewServiceOf('Bike'), GodViewService.motorcycle);
      expect(godViewServiceOf(null, 'Yamaha motorcycle'), GodViewService.motorcycle);
      expect(godViewServiceOf('Freight'), GodViewService.freight);
      expect(godViewServiceOf('Lorry 1-tonne'), GodViewService.freight);
      expect(godViewServiceOf('Van'), GodViewService.freight);
    });

    test('filters: partners, users, last known and the users sub-filter', () {
      Set<String> ids(GodViewFilters f) => godViewShown(_people, f).map((p) => p.id).toSet();
      const live = GodViewFilters(lastKnown: false);
      expect(ids(live), {'d1', 'd2', 'd3', 'd7', 'd8', 'd9', 'u1', 'u2', 'u3', 'u4', 'u6'});
      expect(const GodViewFilters().lastKnown, isTrue, reason: 'on by default, so the page is never empty');
      expect(ids(const GodViewFilters()), containsAll(['d6', 'u5']));
      expect(ids(live.copyWith(users: false)), {'d1', 'd2', 'd3', 'd7', 'd8', 'd9'});
      expect(ids(live.copyWith(partners: false)), {'u1', 'u2', 'u3', 'u4', 'u6'});
      expect(ids(live.copyWith(partners: false, userFilter: GodViewUserFilter.searching)), {'u1'});
      expect(ids(live.copyWith(partners: false, userFilter: GodViewUserFilter.ride)), {'u2', 'u4'});
      expect(ids(live.copyWith(partners: false, userFilter: GodViewUserFilter.appOpen)), {'u3'});
      expect(ids(live.copyWith(partners: false, userFilter: GodViewUserFilter.alwaysOn)), {'u6'});
      expect(GodViewUserFilter.alwaysOn.label, 'Always on');
      final sosUser = _p('u9', GodViewStatus.sos, kind: GodViewKind.user);
      expect(godViewShown([sosUser], const GodViewFilters(userFilter: GodViewUserFilter.appOpen)), [sosUser],
          reason: 'an SOS passes every users filter');
    });

    test('search: name, plate without spaces, ride code; the server''s search is not redone', () {
      Set<String> ids(String q, {String server = ''}) =>
          godViewShown(_people, GodViewFilters(query: q), serverQuery: server).map((p) => p.id).toSet();
      expect(ids('hafiz'), {'d1'});
      expect(ids('vjk4821'), {'d1'});
      expect(ids('r-5m8t'), {'d3', 'u2'});
      expect(ids('bintang'), {'d1'});
      expect(ids('0123456'), isEmpty, reason: 'phone numbers are matched by the server only');
      expect(ids('0123456', server: '0123456'), hasLength(_people.length), reason: 'rows the server matched stay');
    });

    test('a user in a ride with a shown partner is drawn as the partner only', () {
      final shown = godViewShown(_people, const GodViewFilters(lastKnown: false));
      final markers = godViewMarkers(shown).map((p) => p.id).toSet();
      expect(markers.contains('u2'), isFalse, reason: 'with Kumar on 5m8t');
      expect(markers.contains('u4'), isFalse, reason: 'with Rahim on 9f1d (SOS)');
      expect(markers.containsAll(['u1', 'u3', 'd3', 'd7']), isTrue);
      final usersOnly = godViewShown(_people, const GodViewFilters(partners: false, lastKnown: false));
      expect(godViewMarkers(usersOnly).map((p) => p.id), containsAll(['u2', 'u4']),
          reason: 'with partners hidden the riders show');
    });

    test('stats, legend, ages and the live line', () {
      const c = GodViewCounts(
        partnersOnline: 4,
        partnersFree: 1,
        partnersOnJob: 3,
        partnersNotResponding: 2,
        partnersAlwaysOn: 5,
        partnersLastKnown: 7,
        usersSearching: 2,
        usersAppOpen: 9,
        usersAlwaysOn: 6,
        usersLastKnown: 11,
        sos: 1,
      );
      final stats = godViewStats(c);
      expect(stats.map((s) => s.label), [
        'Online partners', 'Free', 'On a job', 'Not responding', 'Users searching', 'Users with app open', 'Always on', 'SOS',
      ]);
      expect(stats.last.alarm, isTrue);
      expect(stats.firstWhere((s) => s.label == 'Always on').value, 11);
      expect(stats.firstWhere((s) => s.label == 'Not responding').value, 2);
      final withLastKnown = godViewStats(c, lastKnown: true);
      expect(withLastKnown.last, (label: 'Last known', value: 18, alarm: false));
      expect(godViewStats(c, users: false, lastKnown: true).map((s) => s.label), isNot(contains('Users searching')));
      expect(godViewStats(c, users: false).firstWhere((s) => s.label == 'Always on').value, 5);
      expect(godViewStats(c, partners: false).map((s) => s.label), isNot(contains('Not responding')));
      expect(godViewStats(c, partners: false, lastKnown: true).last.value, 11);
      expect(godViewLegend(lastKnown: false), isNot(contains(GodViewStatus.lastKnown)));
      expect(godViewLegend(lastKnown: true), contains(GodViewStatus.lastKnown));
      expect(godViewLegend(lastKnown: false), containsAll([GodViewStatus.appOpen, GodViewStatus.alwaysOn, GodViewStatus.notResponding]));
      expect(godViewLegend(lastKnown: false, partners: false), isNot(contains(GodViewStatus.notResponding)));
      expect(godViewAge(_now.subtract(const Duration(seconds: 4)), _now), '4 s ago');
      expect(godViewAge(_now.subtract(const Duration(minutes: 45)), _now), '45 min ago');
      expect(godViewAge(_now.subtract(const Duration(minutes: 59, seconds: 50)), _now), '59 min ago');
      expect(godViewAge(_now.subtract(const Duration(hours: 2)), _now), '2 h ago');
      expect(godViewAge(_now.subtract(const Duration(hours: 2, minutes: 48)), _now), '2 h 48 min ago');
      expect(godViewAge(_now.subtract(const Duration(hours: 23, minutes: 59)), _now), '23 h 59 min ago');
      expect(godViewAge(_now.subtract(const Duration(hours: 30)), _now), '1 day ago');
      expect(godViewAge(_now.subtract(const Duration(days: 3, hours: 5)), _now), '3 days ago');
      expect(godViewAge(null, _now), '');
      expect(
        godViewOmittedNote(GodViewSnapshot(at: _now, total: 2300, omitted: 800, omittedLastKnown: 800)),
        'Showing 1500 of 2300 (800 last known left out). Zoom in to see the rest.',
      );
      expect(
        godViewOmittedNote(GodViewSnapshot(at: _now, total: 1600, omitted: 100)),
        'Showing 1500 of 1600. Zoom in to see the rest.',
      );
      expect(godViewLiveLine(_now.subtract(const Duration(seconds: 2)), _now), 'Live · updated 2 s ago');
    });

    test('the padded box', () {
      final b = godViewPaddedBox(3, 101, 4, 102);
      expect(b.minLat, closeTo(2.85, 1e-9));
      expect(b.maxLng, closeTo(102.15, 1e-9));
      expect(godViewPaddedBox(-89.9, -179.9, 89.9, 179.9).minLat, -90);
    });

    test('actions by grant', () {
      final partner = _people.firstWhere((p) => p.id == 'd7');
      final all = godViewActionsFor(partner, canReadRides: true, canOpenProfile: true, canPush: true, canSuspend: true);
      expect(all, GodViewAction.values.toSet());
      final none = godViewActionsFor(partner, canReadRides: false, canOpenProfile: false, canPush: false, canSuspend: false);
      expect(none, {GodViewAction.follow, GodViewAction.message, GodViewAction.call, GodViewAction.openIncident});
      final idle = godViewActionsFor(_people.firstWhere((p) => p.id == 'u3'),
          canReadRides: true, canOpenProfile: true, canPush: true, canSuspend: true);
      expect(idle.contains(GodViewAction.openRide), isFalse);
      expect(idle.contains(GodViewAction.openIncident), isFalse);
    });
  });

  group('page', () {
    for (final b in Brightness.values) {
      for (final size in const [Size(1400, 900), Size(390, 844)]) {
        testWidgets('builds in ${b.name} at ${size.width.toInt()} wide', (tester) async {
          final repo = await _pump(tester, b: b, size: size);
          expect(tester.takeException(), isNull);
          expect(find.text('God View'), findsWidgets);
          expect(find.byKey(const ValueKey('god-view-legend')), findsOneWidget);
          expect(find.text('Users with app open'), findsOneWidget);
          // The legend starts closed, opens on a tap and closes again.
          final legendBox = find.byKey(const ValueKey('god-view-legend'));
          expect(find.descendant(of: legendBox, matching: find.text('Always on')), findsNothing);
          expect(find.descendant(of: legendBox, matching: find.text('Legend')), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('god-view-legend-toggle')));
          await tester.pump();
          expect(tester.takeException(), isNull);
          // 0272: the new statuses in the legend and the stats.
          for (final l in ['Always on', 'Online, not responding', 'Last known']) {
            expect(find.descendant(of: legendBox, matching: find.text(l)), findsOneWidget, reason: l);
          }
          for (final l in ['Always on', 'Not responding', 'Last known']) {
            expect(find.text(l), findsWidgets, reason: l);
          }
          expect(find.byKey(const ValueKey('god-view-last-known')), findsOneWidget);
          expect(find.byKey(const ValueKey('god-view-marker-d6')), findsOneWidget, reason: 'last known on by default');
          expect(find.text('Live · updated 0 s ago'), findsOneWidget);
          expect(find.byKey(const ValueKey('god-view-marker-u2')), findsNothing, reason: 'drawn as Kumar');
          expect(find.byKey(const ValueKey('god-view-marker-d3')), findsOneWidget);
          expect(find.byKey(const ValueKey('god-view-user-filter')), findsOneWidget);
          expect(repo.asked, isNotEmpty);
          // The panel sits beside the map when wide, under it on a phone.
          final panel = tester.getTopLeft(find.byKey(const ValueKey('god-view-tab-people')));
          final legend = tester.getTopLeft(find.byKey(const ValueKey('god-view-legend')));
          if (size.width > 1000) {
            expect(panel.dx, greaterThan(legend.dx + 300));
          } else {
            expect(panel.dy, greaterThan(legend.dy));
          }
          await tester.tap(find.byKey(const ValueKey('god-view-legend-toggle')));
          await tester.pump();
          expect(find.descendant(of: legendBox, matching: find.text('Always on')), findsNothing);
          expect(find.descendant(of: legendBox, matching: find.text('Legend')), findsOneWidget);
        });
      }
    }

    testWidgets('SOS first in the list, last known after the live ones; Last known asks the server again',
        (tester) async {
      final repo = await _pump(tester, size: const Size(1400, 2400));
      expect(repo.asked.first.offline, isTrue, reason: 'last known on by default');
      double y(String id) => tester.getTopLeft(find.byKey(ValueKey('god-view-row-$id'))).dy;
      expect(y('d7'), lessThan(y('d1')));
      expect(y('u6'), lessThan(y('d6')), reason: 'always on before the last known');
      expect(y('d8'), lessThan(y('u5')));
      expect(find.text('3 days ago'), findsOneWidget);
      expect(find.text('2 h 48 min ago'), findsOneWidget, reason: 'not responding for 2 h 48 min');
      await tester.tap(find.byKey(const ValueKey('god-view-last-known')));
      await tester.pump();
      await tester.pump();
      expect(repo.asked.last.offline, isFalse);
      expect(find.byKey(const ValueKey('god-view-row-d6')), findsNothing);
      expect(find.byKey(const ValueKey('god-view-row-d8')), findsOneWidget, reason: 'not responding stays');
    });

    testWidgets('tapping a name zooms in but keeps everyone in the list', (tester) async {
      final repo = await _pump(tester, size: const Size(1400, 2400));
      await _openDetails(tester, 'd8');
      // The map moved; let the camera settle and the next poll come in.
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(repo.asked.every((a) => !a.box), isTrue, reason: 'never narrowed to the map view');
      await tester.tap(find.byKey(const ValueKey('god-view-tab-people')));
      await tester.pump(const Duration(milliseconds: 400));
      for (final id in ['d7', 'd1', 'd8', 'u5']) {
        expect(find.byKey(ValueKey('god-view-row-$id')), findsOneWidget, reason: id);
      }
      expect(tester.takeException(), isNull);
    });

    for (final b in Brightness.values) {
      testWidgets('not responding and last known details in ${b.name}', (tester) async {
        await _pump(tester, b: b, size: const Size(1400, 2400));
        await _openDetails(tester, 'd8');
        expect(find.byKey(const ValueKey('god-view-not-responding-note')), findsOneWidget);
        expect(find.textContaining('nothing has come from it for 2 h 48 min'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('god-view-tab-people')));
        await tester.pump(const Duration(milliseconds: 400));
        await _openDetails(tester, 'u5');
        expect(find.text('Last known position, 3 days ago.'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    for (final b in Brightness.values) {
      testWidgets('No location: a collapsed section under the located people in ${b.name}', (tester) async {
        final repo = await _pump(tester, b: b, size: const Size(1400, 2400));
        expect(repo.askedUnlocated, [''], reason: 'asked once on open, not with every poll');
        final header = find.byKey(const ValueKey('god-view-no-location'));
        expect(header, findsOneWidget);
        expect(find.text('No location (3)'), findsOneWidget);
        expect(find.byKey(const ValueKey('god-view-unlocated-n1')), findsNothing, reason: 'collapsed');
        expect(find.byKey(const ValueKey('god-view-marker-n1')), findsNothing, reason: 'never on the map');
        expect(tester.getTopLeft(header).dy, greaterThan(tester.getTopLeft(find.byKey(const ValueKey('god-view-row-u5'))).dy),
            reason: 'below the located ones');
        await tester.tap(header);
        await tester.pump();
        for (final id in ['n1', 'n2', 'n3']) {
          expect(find.byKey(ValueKey('god-view-unlocated-$id')), findsOneWidget, reason: id);
        }
        expect(find.textContaining("Hasn't opened the new app"), findsOneWidget);
        expect(find.textContaining('Old app version (1.2.0)'), findsOneWidget);
        expect(find.textContaining('Last seen '), findsOneWidget);
        expect(find.text('No location'), findsNWidgets(3));
        expect(tester.takeException(), isNull);
        // Refresh asks again; the poll does not.
        await tester.tap(find.byTooltip('Refresh'));
        await tester.pump();
        expect(repo.askedUnlocated, ['', '']);
      });
    }

    testWidgets('No location follows the Partners and Users toggles and the search', (tester) async {
      final repo = await _pump(tester, size: const Size(1400, 2400));
      await tester.enterText(find.byKey(const ValueKey('god-view-search')), 'nur');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(repo.askedUnlocated.last, 'nur');
      await tester.tap(find.byKey(const ValueKey('god-view-no-location')));
      await tester.pump();
      expect(find.byKey(const ValueKey('god-view-unlocated-n1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('god-view-partners')));
      await tester.pump();
      expect(find.byKey(const ValueKey('god-view-unlocated-n1')), findsNothing, reason: 'a partner');
      expect(find.byKey(const ValueKey('god-view-unlocated-n2')), findsOneWidget);
    });

    testWidgets('the phone stays hidden until Show, which the server logs', (tester) async {
      final repo = await _pump(tester);
      await _openDetails(tester, 'd1');
      expect(find.text(godViewPhoneHidden), findsOneWidget);
      expect(find.textContaining('6789'), findsNothing);
      expect(repo.revealed, isEmpty);
      await tester.tap(find.byKey(const ValueKey('god-view-show-phone')));
      await tester.pump();
      await tester.pump();
      expect(repo.revealed, ['d1']);
      expect(find.text('+60 12-345 6789'), findsOneWidget);
      expect(find.text('Recorded in the admin log.'), findsOneWidget);
    });

    testWidgets('a full admin sees every action; SOS adds Open incident', (tester) async {
      await _pump(tester);
      await _openDetails(tester, 'd7');
      for (final k in ['follow', 'open-ride', 'profile', 'message', 'call', 'push', 'suspend', 'incident']) {
        expect(find.byKey(ValueKey('god-view-$k')), findsOneWidget, reason: k);
      }
      expect(find.byKey(const ValueKey('god-view-sos-note')), findsOneWidget);
    });

    testWidgets('a God View-only sub-admin: no Suspend, no Send push, no ride or profile', (tester) async {
      await _pump(tester, grants: const [AdminGrant(page: godViewPage, edit: false)]);
      await _openDetails(tester, 'd2');
      for (final k in ['follow', 'message', 'call']) {
        expect(find.byKey(ValueKey('god-view-$k')), findsOneWidget, reason: k);
      }
      for (final k in ['open-ride', 'profile', 'push', 'suspend']) {
        expect(find.byKey(ValueKey('god-view-$k')), findsNothing, reason: k);
      }
    });

    testWidgets('Partners edit shows Suspend on partners only; Push edit shows Send push', (tester) async {
      await _pump(tester, grants: const [
        AdminGrant(page: godViewPage, edit: false),
        AdminGrant(page: 'admin-partners', edit: true),
        AdminGrant(page: 'admin-settings-push-notification', edit: true),
        AdminGrant(page: 'admin-users', edit: false),
      ]);
      await _openDetails(tester, 'd2');
      expect(find.byKey(const ValueKey('god-view-suspend')), findsOneWidget);
      expect(find.byKey(const ValueKey('god-view-push')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('god-view-tab-people')));
      await tester.pump(const Duration(milliseconds: 400));
      await _openDetails(tester, 'u3');
      expect(find.byKey(const ValueKey('god-view-suspend')), findsNothing, reason: 'Users is view-only');
      expect(find.byKey(const ValueKey('god-view-push')), findsOneWidget);
    });

    testWidgets('Suspend asks for a reason and warns about the trip', (tester) async {
      final repo = await _pump(tester);
      await _openDetails(tester, 'd2');
      await tester.tap(find.byKey(const ValueKey('god-view-suspend')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('god-view-suspend-dialog')), findsOneWidget);
      expect(find.text('On a trip: they can finish this one.'), findsOneWidget);
      final confirm = find.byKey(const ValueKey('god-view-suspend-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull, reason: 'no reason yet');
      await tester.tap(find.byKey(const ValueKey('god-view-reason-Safety concern')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('god-view-suspend-note')), 'Rider called in');
      await tester.tap(confirm);
      await tester.pump();
      await tester.pump();
      expect(repo.suspended, [('d2', 'Safety concern', 'Rider called in')]);
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('On a trip: they can finish this one.'), findsOneWidget);
    });

    testWidgets('Send push goes to that one person', (tester) async {
      final repo = await _pump(tester);
      await _openDetails(tester, 'u3');
      await tester.tap(find.byKey(const ValueKey('god-view-push')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('god-view-push-title')), 'Hello');
      await tester.enterText(find.byKey(const ValueKey('god-view-push-body')), 'Your driver is near');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('god-view-push-send')));
      await tester.pump();
      await tester.pump();
      expect(repo.pushed, [('u3', 'Hello', 'Your driver is near')]);
    });

    for (final b in Brightness.values) {
      testWidgets('a quiet Always on phone: "Not moved since" in the row and the details in ${b.name}', (tester) async {
        await _pump(tester, b: b, size: const Size(1400, 2400));
        final since = godViewNotMovedSince(_people.firstWhere((p) => p.id == 'u6'), _now)!;
        expect(since, startsWith('Not moved since '));
        expect(find.descendant(of: find.byKey(const ValueKey('god-view-row-u6')), matching: find.text(since)),
            findsOneWidget);
        await _openDetails(tester, 'u6');
        expect(find.byKey(const ValueKey('god-view-not-moved')), findsOneWidget);
        expect(find.byKey(const ValueKey('god-view-ping')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('Ping now: sent, waiting, then the answer and a refresh in ${b.name}', (tester) async {
        final fake = _FakeRepo()..answers.addAll([false, true]);
        final repo = await _pump(tester, b: b, size: const Size(1400, 2400), fake: fake);
        await _openDetails(tester, 'u6');
        final asked = repo.asked.length;
        await tester.tap(find.byKey(const ValueKey('god-view-ping')));
        await tester.pump();
        await tester.pump();
        expect(repo.pinged, ['u6']);
        expect(find.textContaining('Ping sent…'), findsOneWidget);
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(find.textContaining('Ping sent…'), findsOneWidget, reason: 'not yet');
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(find.text(godViewPingLine(GodViewPingStage.answered, at: _now)), findsOneWidget);
        expect(repo.asked.length, greaterThan(asked), reason: 'the map is asked again');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Ping now: no answer after a minute', (tester) async {
      final repo = await _pump(tester, size: const Size(1400, 2400));
      await _openDetails(tester, 'd6');
      await tester.tap(find.byKey(const ValueKey('god-view-ping')));
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
      await tester.pump();
      expect(repo.answerAsks, 12);
      expect(find.textContaining('No answer yet.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 30));
      expect(repo.answerAsks, 12, reason: 'stops asking');
    });

    testWidgets('Ping now: pinged in the last 2 minutes, or no phone to ping', (tester) async {
      final fake = _FakeRepo()..pingResult = GodViewPingResult(phones: 1, recent: 1, retryAt: _now);
      await _pump(tester, size: const Size(1400, 2400), fake: fake);
      await _openDetails(tester, 'd8');
      await tester.tap(find.byKey(const ValueKey('god-view-ping')));
      await tester.pump();
      await tester.pump();
      expect(find.text(godViewPingLine(GodViewPingStage.recent, at: _now)), findsOneWidget);
      fake.pingResult = const GodViewPingResult();
      await tester.tap(find.byKey(const ValueKey('god-view-ping')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('No phone to ping'), findsOneWidget);
      expect(fake.answerAsks, 0);
    });

    testWidgets('no Ping now for someone already reporting', (tester) async {
      await _pump(tester, size: const Size(1400, 2400));
      await _openDetails(tester, 'd1');
      expect(find.byKey(const ValueKey('god-view-ping')), findsNothing);
    });

    for (final b in Brightness.values) {
      testWidgets('Settings: a full admin changes the pings and the hours in ${b.name}', (tester) async {
        final repo = await _pump(tester, b: b);
        await tester.tap(find.byKey(const ValueKey('god-view-settings')));
        await tester.pumpAndSettle();
        expect(find.text('God View settings'), findsOneWidget);
        expect(find.text('Ping a phone quiet for 30 min'), findsOneWidget);
        expect(find.text('Always on for 12 h after the last report'), findsOneWidget);
        expect(find.byKey(const ValueKey('god-view-settings-readonly')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('god-view-settings-pings')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('god-view-settings-save')));
        await tester.pumpAndSettle();
        expect(repo.saved.single.pings, isFalse);
        expect((repo.saved.single.pingMinutes, repo.saved.single.alwaysOnHours), (30, 12));
        expect(find.text('God View settings'), findsNothing, reason: 'closed');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Settings: read only for anyone but a full admin', (tester) async {
      final fake = _FakeRepo()..settings = const GodViewSettings(pingMinutes: 45);
      await _pump(tester, fake: fake, grants: const [AdminGrant(page: godViewPage, edit: false)]);
      await tester.tap(find.byKey(const ValueKey('god-view-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('god-view-settings-readonly')), findsOneWidget);
      expect(find.text('Ping a phone quiet for 45 min'), findsOneWidget);
      expect(find.byKey(const ValueKey('god-view-settings-save')), findsNothing);
      expect(tester.widget<Slider>(find.byKey(const ValueKey('god-view-settings-hours'))).onChanged, isNull);
      expect(fake.saved, isEmpty);
    });
  });
}
