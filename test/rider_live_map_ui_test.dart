// Rider live map (migration 0322) in the app, light and dark: the overlays
// button on the home map (hidden until the rider has an overlay to use),
// its picker, each sheet, the layers, Settings › Map, the member's "Stop
// sharing" and "Company trip", and Admin › Settings › Rider live map.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/live_map/rider_live_map_screen.dart';
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart' show grantablePages;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/family.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/rider_live_map.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/family_repository.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/rider_live_map_repository.dart';
import 'package:get_ride/src/features/family/family_trip_parts.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/features/ride/home_screen.dart';
import 'package:get_ride/src/features/ride/live_map_overlays.dart';
import 'package:get_ride/src/features/settings/map_settings_card.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _FakeRides implements RideRepository {
  @override
  Future<RideRequest?> ongoingForRider() async => null;
  @override
  Future<List<RideRequest>> ridesOnTheGo() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repo extends RiderLiveMapRepository {
  _Repo() : super(_db);
  List<LiveMapRule> stored = const [
    LiveMapRule(id: 'd', values: {
      'cars_on': false, 'cars_may_hide': true, 'cars_fields': ['car', 'bike', 'van', 'count', 'pickup_time'],
      'cars_offset_m': 150, 'cars_every_s': 10, 'cars_radius_m': 3000,
      'busy_on': false, 'busy_who': 'all', 'busy_fields': ['level', 'fare', 'wait', 'next_hour', 'tip'], 'busy_hex_m': 350,
      'busy_min': 5, 'busy_every_s': 60, 'busy_window_min': 30, 'busy_colours': ['#FFEDA0', '#FEB24C', '#F03B20', '#99000D'],
      'busy_opacity': 55, 'people_on': false, 'people_who': 'hosts',
      'people_fields': ['spot', 'status', 'eta', 'dropoff', 'driver'], 'people_history_min': 0, 'people_after_min': 5,
      'people_every_s': 10, 'team_on': false, 'team_who': 'admins', 'team_fields': ['spot', 'purpose', 'eta', 'cost'],
      'team_after_min': 0, 'team_log_days': 30, 'team_every_s': 10,
    }),
    LiveMapRule(id: 'kl', country: 'Malaysia', state: 'Kuala Lumpur', city: 'Kuala Lumpur', values: {'busy_on': true}),
  ];
  final saved = <LiveMapRule>[];
  final stopped = <String>[];

  @override
  Future<List<LiveMapRule>> rules() async => stored;
  @override
  Future<void> saveRule(LiveMapRule rule) async => saved.add(rule);
  @override
  Future<void> stopSharing(String tripId) async => stopped.add(tripId);
  @override
  Future<CompanyTripNote> tripNote(String tripId) async =>
      const CompanyTripNote(company: true, name: 'Acme Sdn Bhd', shown: true, who: 'admins', seenBy: ['Mei']);
  @override
  Future<BusyAreas> busy({required double south, required double west, required double north, required double east,
      required LivePlace place}) async => BusyAreas.none;
  @override
  Future<LivePeople> people(LivePlace place) async => LivePeople.none;
  @override
  Future<LivePeople> team(LivePlace place) async => LivePeople.none;
  @override
  Future<LiveCars> cars(double lat, double lng, LivePlace place) async => LiveCars.none;
}

Widget _app(Brightness b, Widget home, {List overrides = const [], _Repo? repo}) => ProviderScope(
  retry: (_, _) => null,
  overrides: [
    ...quietLiveOverrides,
    riderLiveMapRepositoryProvider.overrideWithValue(repo ?? _Repo()),
    currentUserIdProvider.overrideWithValue('u1'),
    pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
    ...overrides,
  ],
  child: MaterialApp(theme: appTheme(b), home: home),
);

/// A screen with a button that opens [open].
Widget _opener(Future<void> Function(BuildContext) open) => Scaffold(
  body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => open(c), child: const Text('open')))),
);

final _cellCentre = hexCentre(31722, 1144, 350, 3);
final _areas = BusyAreas.fromJson({
  'on': true, 'hexM': 350, 'latRef': 3, 'at': DateTime.now().toUtc().toIso8601String(),
  'cells': [
    {'q': 31722, 'r': 1144, 'lat': _cellCentre.latitude, 'lng': _cellCentre.longitude, 'level': 3, 'area': 'Mid Valley',
     'fare': 1.4, 'wait': 6, 'next': 'down', 'tip': {'m': 600, 'dir': 'north', 'fare': 1.1}},
    {'q': 31723, 'r': 1144, 'lat': 3.12, 'lng': 101.68, 'level': 0},
  ],
});

const _aisha = LivePerson(
  id: 'm1', name: 'Aisha', status: 'on_trip', from: 'Mid Valley', to: 'KLCC', point: LatLng(3.12, 101.68), eta: 12,
  progress: 0.42, driver: 'Siti', car: 'Perodua Bezza, silver',
);
const _lim = LivePerson(
  id: 'r1', name: 'Lim', company: 'Acme Sdn Bhd', status: 'on_trip', from: 'Acme, Bangsar South',
  to: 'Client office, Jalan Ampang', point: LatLng(3.12, 101.67), eta: 8, cost: 14.2, purpose: 'Client visit', progress: 0.55,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the home map', () {
    List homeOverrides(LiveMapConfig config) => [
      rideRepositoryProvider.overrideWithValue(_FakeRides()),
      geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
      coinTradeQuoteProvider.overrideWith((ref) => Future.error('offline')),
      serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
      rideServicesProvider.overrideWith((ref) async => const [RideService('Teksi', 'Metered taxi', 1, 4)]),
      recentPlacesProvider.overrideWith((ref) async => const []),
      displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
      appDisplayProvider.overrideWith((ref) => Future.error('offline')),
      fareTariffsProvider.overrideWith((ref) async => const []),
      meterLaunchSessionProvider.overrideWithValue(null),
      profileProvider.overrideWith((ref) async => null),
      adminAccessProvider.overrideWith((ref) => Future.error('offline')),
      liveMapConfigProvider.overrideWith((ref, key) async => config),
    ];

    Future<void> pumpHome(WidgetTester tester, Brightness b, LiveMapConfig config) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(b, const HomeScreen(), overrides: homeOverrides(config)));
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
    }

    for (final b in Brightness.values) {
      testWidgets('unchanged until the rider has an overlay (${b.name})', (tester) async {
        await pumpHome(tester, b, LiveMapConfig.off);
        expect(find.byKey(const ValueKey('map-type')), findsOneWidget);
        expect(find.byKey(const ValueKey('map-overlays')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('the honeycomb button tops the right-hand buttons and opens the picker (${b.name})', (tester) async {
        await pumpHome(tester, b, const LiveMapConfig(busyOn: true, teamOn: true));
        final button = find.byKey(const ValueKey('map-overlays'));
        expect(button, findsOneWidget);
        expect(find.descendant(of: button, matching: find.byIcon(Icons.hive)), findsOneWidget);
        expect(tester.getRect(button).bottom, lessThan(tester.getRect(find.byKey(const ValueKey('map-type'))).top));
        expect(find.byKey(const ValueKey('map-overlays-count')), findsNothing);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text('Map overlays'), findsWidgets);
        expect(find.byKey(const ValueKey('overlay-busy')), findsOneWidget);
        expect(find.byKey(const ValueKey('overlay-team')), findsOneWidget);
        expect(find.byKey(const ValueKey('overlay-people')), findsNothing, reason: 'My people only for family members');
        await tester.tap(find.byKey(const ValueKey('overlay-busy')));
        await tester.tap(find.byKey(const ValueKey('overlay-team')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('live-sheet-close')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('overlay-picker')), findsNothing);
        expect(find.text('2'), findsOneWidget, reason: 'the button counts the overlays on');
        // Remembered for this rider.
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('live_map.u1.overlays'), 'busy,team');
        await tester.pumpWidget(const SizedBox());
      });
    }
  });

  group('layers', () {
    testWidgets('the honeycomb: see-through cells, white edges, the tapped one outlined; people and cars', (tester) async {
      late List<Widget> layers;
      late List<Marker> people, cars;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        layers = busyLayers(c, _areas, selected: _areas.cells.first);
        people = personMarkers(const [_aisha, LivePerson(id: 'x', name: 'No spot')], team: false, onTap: (_) {});
        cars = carMarkers(LiveCars.fromJson({'on': true, 'cars': [{'lat': 3.1, 'lng': 101.6, 'kind': 'van'}]}));
        return const SizedBox();
      })));
      final honeycomb = layers.first as PolygonLayer;
      expect(honeycomb.polygons, hasLength(2));
      expect(honeycomb.polygons.first.points, hasLength(6));
      expect(honeycomb.polygons.first.color!.a, lessThan(1));
      expect(honeycomb.polygons.first.borderColor.r, 1.0);
      expect(layers, hasLength(2), reason: 'the outline of the tapped cell');
      expect(people, hasLength(1), reason: 'only people with a spot are on the map');
      expect(cars, hasLength(1));
      expect(busyLayers(tester.element(find.byType(SizedBox)), BusyAreas.none), isEmpty);
    });
  });

  for (final b in Brightness.values) {
    group('sheets (${b.name})', () {
      testWidgets('a busy area: level, fares, wait, next hour, the tip, set pickup here', (tester) async {
        var set = 0;
        await tester.pumpWidget(_app(b, _opener((c) => showBusyAreaSheet(c, cell: _areas.cells.first, areas: _areas,
            onSetPickup: () => set++))));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('Mid Valley area'), findsOneWidget);
        expect(find.textContaining('Busy areas · updated'), findsOneWidget);
        expect(find.text('Very busy'), findsOneWidget);
        expect(find.text('about 1.4x usual'), findsOneWidget);
        expect(find.text('about 6 min'), findsOneWidget);
        expect(find.text('Getting quieter'), findsOneWidget);
        expect(find.text('Quieter 600 m north: about 1.1x'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('busy-set-pickup')));
        await tester.pumpAndSettle();
        expect(set, 1);
        expect(find.byKey(const ValueKey('busy-area-sheet')), findsNothing);
      });

      testWidgets('a family member: the trip, the car without the plate, Call, and that it is shared', (tester) async {
        await tester.pumpWidget(_app(b, _opener((c) => showFamilyMemberSheet(c, person: _aisha, colour: personColour(0))),
            overrides: [
              familyMineProvider.overrideWith((ref) async => FamilyView.fromJson({
                'role': 'host',
                'members': [{'id': 'm1', 'name': 'Aisha', 'phone': '+60100322002', 'status': 'active'}],
              })),
            ]));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('Aisha'), findsOneWidget);
        expect(find.text('Shared with family'), findsOneWidget);
        expect(find.text('Ride to KLCC'), findsOneWidget);
        expect(find.text('ETA 12 min'), findsOneWidget);
        expect(find.text('Perodua Bezza, silver, with Siti'), findsOneWidget);
        expect(find.byKey(const ValueKey('family-member-call')), findsOneWidget);
        expect(find.textContaining('can stop sharing at any time'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('live-sheet-close')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('family-member-sheet')), findsNothing);
      });

      testWidgets('a company trip: where, purpose, ETA, cost so far, why it shows', (tester) async {
        await tester.pumpWidget(_app(b, _opener((c) => showTeamTripSheet(c, trip: _lim))));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('Lim · Company trip'), findsOneWidget);
        expect(find.text('Acme Sdn Bhd'), findsOneWidget);
        expect(find.text('Client office, Jalan Ampang'), findsWidgets);
        expect(find.text('Client visit'), findsOneWidget);
        expect(find.text('8 min'), findsOneWidget);
        expect(find.text('Shown because Acme Sdn Bhd pays for this trip.'), findsOneWidget);
        // Dragged down, it closes.
        await tester.drag(find.byKey(const ValueKey('team-trip-sheet')), const Offset(0, 600));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('team-trip-sheet')), findsNothing);
      });

      testWidgets('Settings › Map: cars and remembering the overlays, kept for this rider', (tester) async {
        await tester.pumpWidget(_app(b, const Scaffold(body: SingleChildScrollView(child: MapSettingsCard()))));
        await tester.pumpAndSettle();
        expect(find.text('Show cars near me on the map'), findsOneWidget);
        expect(find.text(showCarsHint), findsOneWidget);
        expect(find.text('Map overlays remember my last choice'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('settings-show-cars')));
        await tester.tap(find.byKey(const ValueKey('settings-remember-overlays')));
        await tester.pumpAndSettle();
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('live_map.u1.hide_cars'), isTrue);
        expect(prefs.getBool('live_map.u1.remember'), isFalse);
      });

      testWidgets('the member stops sharing at once; a company trip says so', (tester) async {
        final repo = _Repo();
        await tester.pumpWidget(_app(b, Scaffold(body: Builder(builder: (c) => Consumer(builder: (c, ref, _) => Column(children: [
          WhoCanSeeCard(
            status: const FamilyTripStatus(family: true, shared: true, mine: true,
                viewers: [(name: 'Karpal', what: 'Live location until drop-off', role: 'host'),
                          (name: 'Your family members', what: 'Live location on their map until drop-off', role: 'members')]),
            onStop: () => ref.read(riderLiveMapRepositoryProvider).stopSharing('t1'),
          ),
          const CompanyTripChip(tripId: 't2'),
        ])))), repo: repo));
        await tester.pumpAndSettle();
        expect(find.text('Karpal (family host): live location until drop-off.'), findsOneWidget);
        expect(find.text('Your family members: live location on their map until drop-off.'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('family-stop-sharing')));
        await tester.pumpAndSettle();
        expect(repo.stopped, ['t1']);
        await tester.tap(find.byKey(const ValueKey('company-trip-chip')));
        await tester.pumpAndSettle();
        expect(find.text('Travel admins at Acme Sdn Bhd can see this trip on their map until drop-off.'), findsOneWidget);
        expect(find.text('Looked lately: Mei'), findsOneWidget);
      });

      testWidgets('admin: region chips, four cards, locked fields, steppers, the colour scale, save', (tester) async {
        tester.view.physicalSize = const Size(1280, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final repo = _Repo();
        await tester.pumpWidget(_app(b, const RiderLiveMapScreen(), repo: repo));
        await tester.pumpAndSettle();
        expect(find.text('Rider live map'), findsWidgets);
        expect(find.byKey(const ValueKey('rlm-region-|||')), findsOneWidget);
        expect(find.text('Kuala Lumpur'), findsOneWidget);
        expect(find.byKey(const ValueKey('rlm-add-region')), findsOneWidget);
        for (final t in ['Cars near me', 'Busy areas', 'My people', 'Team']) {
          expect(find.text(t), findsOneWidget);
        }
        expect(find.text(carsNeverShown), findsOneWidget);
        expect(find.text('Family hosts'), findsOneWidget);
        expect(find.text('Travel admins'), findsOneWidget);
        expect(find.text('150 m'), findsOneWidget);
        expect(find.text('350 m'), findsOneWidget);
        expect(find.text('5 bookings'), findsOneWidget);
        expect(find.text('None'), findsOneWidget);
        expect(find.byKey(const ValueKey('rlm-colour-scale')), findsOneWidget);
        // Every mode starts off; turning Busy areas on and the hexagon up.
        expect(tester.widget<Switch>(find.byKey(const ValueKey('rlm-busy-on'))).value, isFalse);
        await tester.tap(find.byKey(const ValueKey('rlm-busy-on')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Raise Hexagon size'));
        await tester.pumpAndSettle();
        expect(find.text('400 m'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('rlm-save')));
        await tester.pumpAndSettle();
        expect(repo.saved.single.values['busy_on'], isTrue);
        expect(repo.saved.single.values['busy_hex_m'], 400);
        expect(find.text('Saved Default'), findsOneWidget);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        // A region shows what it follows.
        await tester.tap(find.byKey(const ValueKey('rlm-region-malaysia|kuala lumpur|kuala lumpur|')));
        await tester.pumpAndSettle();
        expect(tester.widget<Switch>(find.byKey(const ValueKey('rlm-busy-on'))).value, isTrue);
        expect(find.text('Follows the rule above'), findsNWidgets(3));
        expect(find.text('Set for this region'), findsOneWidget);
      });
    });
  }

  test('listed under Settings, grantable to sub-admins', () {
    final e = allAdminEntries.firstWhere((e) => e.title == 'Rider live map');
    expect(e.pages, [riderLiveMapPage]);
    expect(grantablePages, contains(riderLiveMapPage));
  });
}
