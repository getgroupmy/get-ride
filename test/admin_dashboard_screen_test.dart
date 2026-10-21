// Admin > Dashboard (lib/src/admin/screens/dashboard_screen.dart) with a fake
// repository: every panel lays out in light and dark, on a phone and wide;
// cancellations falling read as good news; an open SOS is red; the period
// bar switches and remembers the period; Custom has the date boxes; the
// chart answers a tap; a failed read offers Retry; a KPI opens its list.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/dashboard_panels.dart';
import 'package:get_ride/src/admin/screens/dashboard_screen.dart';
import 'package:get_ride/src/core/admin_dashboard.dart';
import 'package:get_ride/src/data/admin_dashboard_repository.dart';
import 'package:get_ride/src/widgets/date_boxes.dart';
import 'package:go_router/go_router.dart';

class _FakeRepo extends AdminDashboardRepository {
  _FakeRepo({this.fail = false}) : super(null);
  final bool fail;
  final asked = <DashboardRange>[];

  @override
  Future<DashboardSummary> summary(DashboardRange r) async {
    asked.add(r);
    if (fail) throw Exception('boom');
    return _summary(r);
  }

  @override
  Future<DashboardLive> live() async => const DashboardLive(
    driversOnline: 48,
    ridesInProgress: 17,
    openRequests: 6,
    firstOfferSeconds: 134,
    firstOfferSamples: 20,
    queueWaiting: 11,
    queues: [(name: 'KLIA T1', waiting: 11)],
    sosOpen: 1,
  );
}

class _MemoryStore implements DashboardChoiceStore {
  _MemoryStore([this.saved = DashboardChoice.initial]);
  DashboardChoice saved;

  @override
  Future<DashboardChoice> load() async => saved;

  @override
  Future<void> save(DashboardChoice choice) async => saved = choice;
}

DashboardSummary _summary(DashboardRange r) {
  final n = r.oneDay ? 11 : 3;
  List<DashboardBucketRow> buckets(double k) => [
    for (var i = 0; i < n; i++)
      DashboardBucketRow(
        start: DateTime.utc(2026, 10, 21, i),
        trips: (10 * k).round() + i,
        bookings: 316.0 * k + i,
        riders: 8 + i,
        requests: 14 + i,
        accepted: 12 + i,
        cancelled: 1,
      ),
  ];
  return DashboardSummary(
    current: DashboardPeriodFigures(
      kpis: const DashboardKpis(
        trips: 193,
        bookings: 6098.8,
        commission: 731.86,
        ridersActive: 150,
        requests: 260,
        accepted: 224,
        cancelled: 26,
        newRiders: 42,
        newPartners: 6,
      ),
      buckets: buckets(1),
      funnel: const DashboardFunnel(requests: 260, offered: 236, accepted: 224, pickedUp: 199, completed: 193),
      services: const [
        DashboardMix(name: 'Ride', trips: 89, bookings: 2800),
        DashboardMix(name: 'Comfort', trips: 35, bookings: 1300),
        DashboardMix(name: 'Teksi', trips: 27, bookings: 900),
        DashboardMix(name: '6-seater', trips: 17, bookings: 700),
        DashboardMix(name: 'Delivery & Food', trips: 25, bookings: 400),
      ],
      payments: const [
        DashboardMix(name: 'Cash', trips: 100, bookings: 3170),
        DashboardMix(name: 'Get Pay', trips: 93, bookings: 2928),
      ],
      heat: const [DashboardHeatCell(3, 9, 12), DashboardHeatCell(3, 18, 20), DashboardHeatCell(6, 22, 4)],
      quality: const DashboardQuality(ratingAvg: 4.82, ratings: 120, driverCancels: 7, riderCancels: 19, pickupMin: 5.6, complaints: 2),
    ),
    previous: DashboardPeriodFigures(
      kpis: const DashboardKpis(
        trips: 178,
        bookings: 5480,
        commission: 660,
        requests: 250,
        accepted: 210,
        cancelled: 29,
        newRiders: 40,
        newPartners: 7,
      ),
      buckets: buckets(0.9),
      quality: const DashboardQuality(ratingAvg: 4.79, driverCancels: 8, riderCancels: 16, pickupMin: 5.6, complaints: 2),
    ),
    areas: const [
      DashboardArea(name: 'Kuala Lumpur City Centre', trips: 41, bookings: 1566, prevTrips: 36),
      DashboardArea(name: 'Petaling Jaya', city: 'Petaling Jaya', trips: 29, bookings: 699, prevTrips: 27),
      DashboardArea(trips: 3, bookings: 70, prevTrips: 4),
    ],
    onlineRecorded: true,
    drivers: const [
      DashboardDriver(profileId: 'u1', partnerId: 'p1', name: 'Ahmad bin Abdullah', trips: 10, earned: 278, rating: 4.95, onlineSeconds: 33000),
      DashboardDriver(profileId: 'u2', name: 'Siti', trips: 9, earned: 250),
    ],
    airports: const [
      DashboardAirport(id: 'a1', kind: 'airport', name: 'KLIA T1', waiting: 8, pickups: 30, prevPickups: 25),
      DashboardAirport(id: 'a2', kind: 'place', name: 'Suria KLCC', waiting: 0, pickups: 24, prevPickups: 20),
      DashboardAirport(id: 'a3', kind: 'place', name: 'Mid Valley Megamall', waiting: 0, pickups: 0, prevPickups: 0),
    ],
    attention: const DashboardAttention(
      partnersPending: 4,
      partnerDocsPending: 5,
      vehicleDocsPending: 4,
      vehiclesNoPermit: 5,
      permitsExpiring: 2,
      ticketsOpen: 3,
    ),
  );
}

// Wednesday 21 October 2026, 10:30 in Kuala Lumpur.
final _now = DateTime.utc(2026, 10, 21, 2, 30);

Future<void> _at(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

GoRouter _router() => GoRouter(
  initialLocation: '/admin/dashboard',
  routes: [
    GoRoute(path: '/admin/dashboard', builder: (_, _) => const AdminDashboardScreen()),
    GoRoute(path: '/admin/rides', builder: (_, s) => Scaffold(body: Text('RIDES ${s.uri.queryParameters['status']}'))),
  ],
);

Widget _app({
  required Brightness b,
  required _FakeRepo repo,
  _MemoryStore? store,
  double scale = 1,
}) => ProviderScope(
  overrides: [
    adminDashboardRepositoryProvider.overrideWithValue(repo),
    adminDashboardRefreshProvider.overrideWithValue(null),
    adminDashboardClockProvider.overrideWithValue(() => _now),
    dashboardChoiceStoreProvider.overrideWithValue(store ?? _MemoryStore()),
  ],
  child: MaterialApp.router(
    theme: ThemeData(brightness: Brightness.light, colorSchemeSeed: const Color(0xFF2DABE2)),
    darkTheme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: const Color(0xFF2DABE2)),
    themeMode: b == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    routerConfig: _router(),
    builder: (c, child) => MediaQuery(
      // Less motion: the live dot holds still (and the test can settle).
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: child!,
    ),
  ),
);

/// The colour of the part of [t] that holds [glyph].
Color? _spanColor(RichText t, String glyph) {
  Color? found;
  t.text.visitChildren((s) {
    if (s is TextSpan && (s.text ?? '').contains(glyph)) {
      found = s.style?.color;
      return false;
    }
    return true;
  });
  return found;
}

void main() {
  for (final b in Brightness.values) {
    for (final size in const [Size(390, 844), Size(320, 640), Size(1440, 1000)]) {
      for (final scale in const [1.0, 1.3]) {
        final at = '${size.width.toInt()}x${size.height.toInt()} @$scale ${b.name}';
        testWidgets('every panel lays out ($at)', (tester) async {
          await _at(tester, size);
          await tester.pumpWidget(_app(b: b, repo: _FakeRepo(), scale: scale));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Command Centre'), findsOneWidget);
          final scroll = find.byKey(const ValueKey('dashboard-scroll'));
          for (final k in [
            'dashboard-kpi-trips',
            'dashboard-panel-chart',
            'dashboard-panel-live',
            'dashboard-panel-funnel',
            'dashboard-panel-services',
            'dashboard-panel-heat',
            'dashboard-panel-attention',
            'dashboard-panel-areas',
            'dashboard-panel-drivers',
            'dashboard-panel-payments',
            'dashboard-panel-airports',
            'dashboard-panel-quality',
          ]) {
            await tester.scrollUntilVisible(find.byKey(ValueKey(k)), 300, scrollable: find.descendant(of: scroll, matching: find.byType(Scrollable)).first);
            expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
            expect(tester.takeException(), isNull, reason: k);
          }
          expect(find.text('Partners awaiting approval'), findsOneWidget);

          final c = CcColors.of(tester.element(find.byKey(const ValueKey('dashboard-panel-quality'))));
          // Accent: cyan in the dark, a deeper blue in the light.
          expect(c.accent.computeLuminance() > 0.3, b == Brightness.dark);
          // Cancellations fell: good news, in green.
          final cancel = find.descendant(
            of: find.byKey(const ValueKey('dashboard-kpi-cancellation')),
            matching: find.textContaining('▼', findRichText: true),
          );
          expect(cancel, findsOneWidget);
          expect(_spanColor(tester.widget<RichText>(cancel), '▼'), c.good);
          // Trips rose: also green.
          final trips = find.descendant(
            of: find.byKey(const ValueKey('dashboard-kpi-trips')),
            matching: find.textContaining('▲', findRichText: true),
          );
          expect(_spanColor(tester.widget<RichText>(trips), '▲'), c.good);
        });
      }
    }
  }

  testWidgets('airports and places: only busy ones listed; a search finds the quiet ones', (tester) async {
    await _at(tester, const Size(1440, 1000));
    await tester.pumpWidget(_app(b: Brightness.light, repo: _FakeRepo()));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('dashboard-panel-airports'));
    expect(find.descendant(of: panel, matching: find.text('Suria KLCC')), findsOneWidget);
    expect(find.descendant(of: panel, matching: find.text('Mid Valley Megamall')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('dashboard-airports-search')), 'mid');
    await tester.pumpAndSettle();
    expect(find.descendant(of: panel, matching: find.text('Mid Valley Megamall')), findsOneWidget);
    expect(find.descendant(of: panel, matching: find.text('Suria KLCC')), findsNothing);
  });

  testWidgets('an open SOS is red; the live panel shows its counts', (tester) async {
    await _at(tester, const Size(1440, 1000));
    await tester.pumpWidget(_app(b: Brightness.dark, repo: _FakeRepo()));
    await tester.pumpAndSettle();
    final sos = tester.widget<CcLiveTile>(find.byKey(const ValueKey('dashboard-live-sos')));
    expect(sos.alert, isTrue);
    expect(find.text('48'), findsOneWidget);
    expect(find.text('2:14'), findsOneWidget);
    expect(find.text('Waiting at KLIA T1'), findsOneWidget);
  });

  testWidgets('the period bar: Today first, Yesterday on a tap, remembered', (tester) async {
    await _at(tester, const Size(1440, 1000));
    final repo = _FakeRepo();
    final store = _MemoryStore();
    await tester.pumpWidget(_app(b: Brightness.light, repo: repo, store: store));
    await tester.pumpAndSettle();
    expect(find.text('Wed 21 Oct 2026, 00:00 to 10:30 · compared with yesterday to 10:30'), findsOneWidget);
    expect(repo.asked.last.period, DashboardPeriod.today);

    await tester.tap(find.byKey(const ValueKey('dashboard-period-yesterday')));
    await tester.pumpAndSettle();
    expect(find.text('Tue 20 Oct 2026 · compared with Mon 19 Oct'), findsOneWidget);
    expect(repo.asked.last.period, DashboardPeriod.yesterday);
    expect(store.saved.period, DashboardPeriod.yesterday);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the saved period opens; Custom has the date boxes and Apply', (tester) async {
    await _at(tester, const Size(390, 844));
    final repo = _FakeRepo();
    final store = _MemoryStore(DashboardChoice(DashboardPeriod.custom, first: DateTime(2026, 10, 1), last: DateTime(2026, 10, 7)));
    await tester.pumpWidget(_app(b: Brightness.dark, repo: repo, store: store));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dashboard-custom')), findsOneWidget);
    expect(find.byType(DateBoxesField), findsNWidgets(2));
    expect(find.byKey(const ValueKey('dashboard-apply')), findsOneWidget);
    expect(repo.asked.last.period, DashboardPeriod.custom);
    expect(repo.asked.last.days, 7);
    expect(find.textContaining('compared with the 7 days before'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dashboard-period-week')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dashboard-custom')), findsNothing);
    expect(store.saved.period, DashboardPeriod.week);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the chart shows a tooltip where it is tapped, and switches metric', (tester) async {
    await _at(tester, const Size(1440, 1000));
    await tester.pumpWidget(_app(b: Brightness.light, repo: _FakeRepo()));
    await tester.pumpAndSettle();
    final chart = find.byKey(const ValueKey('dashboard-chart'));
    await tester.tapAt(tester.getCenter(chart));
    await tester.pump();
    expect(find.byKey(const ValueKey('dashboard-chart-tip')), findsOneWidget);
    expect(find.textContaining('This period', findRichText: true), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('dashboard-tab-DashboardMetric.bookings')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed read offers Retry', (tester) async {
    await _at(tester, const Size(390, 844));
    await tester.pumpWidget(_app(b: Brightness.dark, repo: _FakeRepo(fail: true)));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't load the dashboard"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a KPI tile opens its list, filtered', (tester) async {
    await _at(tester, const Size(1440, 1000));
    await tester.pumpWidget(_app(b: Brightness.light, repo: _FakeRepo()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dashboard-kpi-cancellation')));
    await tester.pumpAndSettle();
    expect(find.text('RIDES cancelled'), findsOneWidget);
  });
}
