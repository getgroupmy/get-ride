// Admin → God View (lib/src/core/god_view.dart, lib/src/admin/screens/
// god_view_screen.dart): the status words and order, the filters and the
// search, a user in a ride drawn as their partner only, the stats and the
// legend, which actions an admin's grants show; and the page with a fake
// repository in light and dark, wide and on a phone, the phone hidden until
// Show, Suspend asking for a reason (and warning about a trip), Send push
// sending to one person.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/god_view_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/god_view.dart';
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
);

final _people = [
  _p('d1', GodViewStatus.free, name: 'Hafiz R.', plate: 'VJK 4821', vehicle: 'Perodua Bezza', area: 'Bukit Bintang'),
  _p('d2', GodViewStatus.pickup, name: 'Mei Ling T.', ride: '7q2k', plate: 'WXY 9033', nextLat: 3.2),
  _p('d3', GodViewStatus.trip, name: 'Kumar S.', ride: '5m8t', service: 'Motorcycle', nextLat: 3.0),
  _p('d6', GodViewStatus.offline, name: 'Jason W.', ageSeconds: 2700),
  _p('d7', GodViewStatus.sos, name: 'Rahim A.', ride: '9f1d', incident: 'inc-1'),
  _p('u1', GodViewStatus.searching, kind: GodViewKind.user, name: 'Aisyah F.', ride: '8k4a'),
  _p('u2', GodViewStatus.ride, kind: GodViewKind.user, name: 'Daniel L.', ride: '5m8t'),
  _p('u3', GodViewStatus.appOpen, kind: GodViewKind.user, name: 'Priya K.'),
  _p('u4', GodViewStatus.ride, kind: GodViewKind.user, name: 'Farah Z.', ride: '9f1d'),
  _p('u5', GodViewStatus.offline, kind: GodViewKind.user, name: 'Tan B. H.', ageSeconds: 4000),
];

class _FakeRepo extends GodViewRepository {
  _FakeRepo() : super(null);
  final asked = <({bool offline, String query, bool box})>[];
  final revealed = <String>[];
  final suspended = <(String, String, String?)>[];
  final pushed = <(String, String, String)>[];
  bool onTrip = true;

  @override
  Future<GodViewSnapshot> snapshot({
    ({double minLat, double minLng, double maxLat, double maxLng})? box,
    bool showOffline = false,
    String query = '',
    int limit = 1500,
  }) async {
    asked.add((offline: showOffline, query: query, box: box != null));
    return GodViewSnapshot(
      at: _now,
      people: _people,
      counts: const GodViewCounts(partnersOnline: 4, partnersFree: 1, partnersOnJob: 3, usersSearching: 1, usersAppOpen: 1, sos: 1),
      total: _people.length,
      query: query,
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
}) async {
  final repo = _FakeRepo();
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
        godViewClockProvider.overrideWithValue(() => _now),
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
  group('logic', () {
    test('status words, the pulse and the order', () {
      expect(GodViewStatus.parse('app_open'), GodViewStatus.appOpen);
      expect(GodViewStatus.parse('pickup').label, 'Going to pickup');
      expect(GodViewStatus.parse('whatever'), GodViewStatus.offline);
      expect(GodViewStatus.values.where((s) => s.pulses), [GodViewStatus.searching, GodViewStatus.sos]);
      final order = godViewListOrder(_people).map((p) => p.id).toList();
      expect(order.first, 'd7', reason: 'SOS first');
      expect(order.indexOf('d2'), lessThan(order.indexOf('u1')));
      expect(order.indexOf('u3'), lessThan(order.indexOf('d6')), reason: 'offline last');
    });

    test('rows from the server', () {
      final s = GodViewSnapshot.fromJson({
        'at': '2026-10-21T08:00:00Z',
        'total': 3,
        'omitted': 1,
        'scoped': true,
        'counts': {'partners_online': 2, 'users_app_open': 5, 'sos': 1},
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
      expect((s.omitted, s.scoped, s.query), (1, true, 'ali'));
    });

    test('a partner''s icon by service', () {
      expect(godViewServiceOf('Car'), GodViewService.car);
      expect(godViewServiceOf('Bike'), GodViewService.motorcycle);
      expect(godViewServiceOf(null, 'Yamaha motorcycle'), GodViewService.motorcycle);
      expect(godViewServiceOf('Freight'), GodViewService.freight);
      expect(godViewServiceOf('Lorry 1-tonne'), GodViewService.freight);
      expect(godViewServiceOf('Van'), GodViewService.freight);
    });

    test('filters: partners, users, offline and the users sub-filter', () {
      Set<String> ids(GodViewFilters f) => godViewShown(_people, f).map((p) => p.id).toSet();
      expect(ids(const GodViewFilters()), {'d1', 'd2', 'd3', 'd7', 'u1', 'u2', 'u3', 'u4'});
      expect(ids(const GodViewFilters(showOffline: true)), containsAll(['d6', 'u5']));
      expect(ids(const GodViewFilters(users: false)), {'d1', 'd2', 'd3', 'd7'});
      expect(ids(const GodViewFilters(partners: false)), {'u1', 'u2', 'u3', 'u4'});
      expect(ids(const GodViewFilters(partners: false, userFilter: GodViewUserFilter.searching)), {'u1'});
      expect(ids(const GodViewFilters(partners: false, userFilter: GodViewUserFilter.ride)), {'u2', 'u4'});
      expect(ids(const GodViewFilters(partners: false, userFilter: GodViewUserFilter.appOpen)), {'u3'});
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
      expect(ids('0123456', server: '0123456'), hasLength(8), reason: 'rows the server matched stay');
    });

    test('a user in a ride with a shown partner is drawn as the partner only', () {
      final shown = godViewShown(_people, const GodViewFilters());
      final markers = godViewMarkers(shown).map((p) => p.id).toSet();
      expect(markers.contains('u2'), isFalse, reason: 'with Kumar on 5m8t');
      expect(markers.contains('u4'), isFalse, reason: 'with Rahim on 9f1d (SOS)');
      expect(markers.containsAll(['u1', 'u3', 'd3', 'd7']), isTrue);
      final usersOnly = godViewShown(_people, const GodViewFilters(partners: false));
      expect(godViewMarkers(usersOnly).map((p) => p.id), containsAll(['u2', 'u4']),
          reason: 'with partners hidden the riders show');
    });

    test('stats, legend, ages and the live line', () {
      const c = GodViewCounts(partnersOnline: 4, partnersFree: 1, partnersOnJob: 3, usersSearching: 2, usersAppOpen: 9, sos: 1);
      final stats = godViewStats(c);
      expect(stats.map((s) => s.label), ['Online partners', 'Free', 'On a job', 'Users searching', 'Users with app open', 'SOS']);
      expect(stats.last.alarm, isTrue);
      expect(godViewStats(c, users: false).map((s) => s.label), isNot(contains('Users searching')));
      expect(godViewLegend(showOffline: false), isNot(contains(GodViewStatus.offline)));
      expect(godViewLegend(showOffline: true), contains(GodViewStatus.offline));
      expect(godViewLegend(showOffline: false), contains(GodViewStatus.appOpen));
      expect(godViewAge(_now.subtract(const Duration(seconds: 4)), _now), '4 s ago');
      expect(godViewAge(_now.subtract(const Duration(minutes: 45)), _now), '45 min ago');
      expect(godViewAge(_now.subtract(const Duration(hours: 2)), _now), '2 h ago');
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
        });
      }
    }

    testWidgets('SOS first in the list; Show offline asks the server again', (tester) async {
      final repo = await _pump(tester);
      final first = tester.getTopLeft(find.byKey(const ValueKey('god-view-row-d7')));
      final other = tester.getTopLeft(find.byKey(const ValueKey('god-view-row-d1')));
      expect(first.dy, lessThan(other.dy));
      expect(find.byKey(const ValueKey('god-view-row-d6')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('god-view-offline')));
      await tester.pump();
      await tester.pump();
      expect(repo.asked.last.offline, isTrue);
      expect(find.byKey(const ValueKey('god-view-row-d6')), findsOneWidget);
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
  });
}
