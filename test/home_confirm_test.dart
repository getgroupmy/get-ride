// The confirm step (a destination chosen) laid out as Expo's ride-confirm:
// addresses over the map, the fare inside the chosen vehicle, and a fixed
// bar with the payment icon and "Find a driver".
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderObject, RenderRepaintBoundary, debugDisableShadows;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart' show rideSearchRoute;
import 'package:get_ride/src/core/home_layout.dart' show homeLayoutKey;
import 'package:get_ride/src/core/home_sections.dart' show pinMiddleOffsetKey;
import 'package:get_ride/src/widgets/map_sheet_layout.dart' show MapFocusShift;
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/overlay_back.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/core/ride_assistance.dart';
import 'package:get_ride/src/core/ride_option_charges.dart';
import 'package:get_ride/src/core/ride_pets.dart';
import 'package:get_ride/src/core/ride_rebook.dart';
import 'package:get_ride/src/core/route_estimate.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/location_source.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/promo_repository.dart';
import 'package:get_ride/src/data/scheduled_ride_repository.dart' show scheduledRidesConfigProvider;
import 'package:get_ride/src/core/scheduled_rides.dart' show ScheduledRidesConfig;
import 'package:get_ride/src/core/sheet_min_height.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/promo_codes.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/route_estimate_repository.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/features/ride/auto_accept.dart';
import 'package:get_ride/src/core/page_styles.dart' show PageStyles;
import 'package:get_ride/src/features/ride/confirm_parts.dart'
    show ConfirmSwitch, DemandNote, SheetTopBar, addStopSteps, demandBandColor;
import 'package:get_ride/src/features/ride/promo_parts.dart' show ConfirmPromoBar;
import 'package:get_ride/src/features/ride/home_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/page_style_host.dart' show PageStyleScope;
import 'package:get_ride/src/widgets/web_overlay_back.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _eco = Place(name: 'Eco Majestic', address: 'Semenyih', point: LatLng(2.9300, 101.8300));
const _klcc = Place(name: 'KLCC', address: 'Kuala Lumpur', point: LatLng(2.9400, 101.8400));

class _Rides implements RideRepository {
  _Rides({this.bidding = false, this.pricing = RegionPricing.none});
  final bool bidding;
  final RegionPricing pricing;
  Map<Symbol, dynamic>? created;

  @override
  Future<List<RideRequest>> ridesOnTheGo() async => const [];

  @override
  Future<bool> biddingEnabledFor(LatLng pickup, Future<AreaInfo?> Function() area) async => bidding;

  @override
  Future<RegionPricing> pricingFor(LatLng pickup, Future<AreaInfo?> Function() area) async => pricing;

  @override
  Future<String?> publicIp() async => null;

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #createRequest) {
      created = i.namedArguments;
      final ride = RideRequest({'id': 'r9', 'rider_id': 'me', 'status': 'open', 'fare': 10});
      return Future<Booked>.value((now: ride, later: null));
    }
    return super.noSuchMethod(i);
  }
}

/// The AI estimate, held until [answer] completes.
class _SlowAi implements RouteEstimateRepository {
  final answer = Completer<({RouteEstimate? estimate, bool unavailable})?>();

  @override
  Future<({RouteEstimate? estimate, bool unavailable})?> estimateDetailed(
    LatLng from,
    LatLng to, {
    List<LatLng> via = const [],
  }) => answer.future;

  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

/// Every trip the AI was asked about (its stops), answering through them
/// with a fare that is up, or as a proxy from before stops when [old].
class _StopsAi implements RouteEstimateRepository {
  _StopsAi({this.old = false});
  final bool old;
  final asked = <List<LatLng>>[];

  @override
  Future<({RouteEstimate? estimate, bool unavailable})?> estimateDetailed(
    LatLng from,
    LatLng to, {
    List<LatLng> via = const [],
  }) async {
    asked.add(via);
    return (
      estimate: RouteEstimate(
        distanceKm: 12,
        durationMin: 30,
        stops: old ? 0 : via.length,
        trend: const FareTrend(direction: FareTrendDirection.up, fromFareRange: false, aiMin: 30, standardMin: 20),
      ),
      unavailable: false,
    );
  }

  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

/// The promo codes the server would answer (migration 0242).
class _Promos extends PromoRepository {
  _Promos([this.list = const [], this.zone = false, this.later = const []]) : super(null);
  List<PromoOffer> list;

  /// The codes for a ride for later (asked with its pickup time).
  List<PromoOffer> later;
  final pickupTimes = <DateTime?>[];
  bool zone;
  final checked = <String>[];
  final zoneAsked = <LatLng>[];
  int offersAsked = 0;

  /// The fare each offers call was asked about.
  final fares = <double?>[];

  @override
  Future<List<PromoOffer>> offers({
    required double pickupLat,
    required double pickupLng,
    double? dropLat,
    double? dropLng,
    String? service,
    double? fare,
    DateTime? pickupAt,
  }) async {
    offersAsked++;
    fares.add(fare);
    pickupTimes.add(pickupAt);
    return pickupAt == null ? list : later;
  }

  @override
  Future<PromoCheckResult> check(
    String code, {
    required double pickupLat,
    required double pickupLng,
    double? dropLat,
    double? dropLng,
    String? service,
    double? fare,
    DateTime? pickupAt,
  }) async {
    checked.add(code);
    if (code == 'GOOD3') {
      return PromoCheckResult.fromJson(
          {'ok': true, 'code_id': 'c3', 'code': 'GOOD3', 'discount_type': 'fixed', 'discount_value': 3, 'discount': 3});
    }
    return PromoCheckResult.fromJson(
        {'ok': false, 'reason': 'min_fare', 'message': 'This code needs a fare of at least RM50.00.'});
  }

  @override
  Future<bool> zoneHere(double lat, double lng) async {
    zoneAsked.add(LatLng(lat, lng));
    return zone;
  }
}

const _ride5 = PromoOffer(
  codeId: 'c5',
  code: 'RIDE5',
  discountValue: 5,
  estimatedDiscount: 5,
  autoApply: true,
);
const _sched7 = PromoOffer(codeId: 's7', code: 'SCHED7', discountValue: 7, estimatedDiscount: 7, autoApply: true);
const _pct = PromoOffer(
  codeId: 'c10',
  code: 'TENPC',
  discountType: PromoDiscountType.percent,
  discountValue: 10,
  estimatedDiscount: 1,
);

/// A phone that knows where it is at once.
class _Here implements LocationSource {
  const _Here(this.at);
  final LatLng at;
  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<LocationPermission> checkPermission() async => LocationPermission.whileInUse;
  @override
  Future<LocationPermission> requestPermission() async => LocationPermission.whileInUse;
  @override
  Future<LatLng?> lastKnown() async => at;
  @override
  Future<LatLng> current(LocationAccuracy accuracy) async => at;
}

class _NoAi implements RouteEstimateRepository {
  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

/// Lets a sheet or dialog finish opening or closing.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The whole screen, for reading its pixels.
final _screen = GlobalKey();

/// The screen as drawn: its pixels (RGBA) and its width. With
/// `--dart-define=BAR_SHOTS=<dir>` it is saved there too as `<name>.png`.
/// Shadows are drawn soft, as on a phone (tests draw them as solid black
/// edges otherwise, which would read as map between the bars).
Future<({ByteData rgba, int width})> _shoot(WidgetTester tester, String name) async {
  final boundary = _screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  void repaint(RenderObject o) {
    o.markNeedsPaint();
    o.visitChildren(repaint);
  }
  debugDisableShadows = false;
  addTearDown(() => debugDisableShadows = true);
  repaint(boundary);
  await tester.pump();
  final out = await tester.runAsync(() async {
    final image = await boundary.toImage();
    final rgba = (await image.toByteData())!;
    const dir = String.fromEnvironment('BAR_SHOTS');
    if (dir.isNotEmpty) {
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      File('$dir/$name.png').writeAsBytesSync(png.buffer.asUint8List());
    }
    final w = image.width;
    image.dispose();
    return (rgba: rgba, width: w);
  });
  debugDisableShadows = true;
  repaint(boundary);
  await tester.pump();
  return out!;
}

/// The colour at [p] of a [_shoot].
Color _pixel(({ByteData rgba, int width}) shot, Offset p) {
  final i = (p.dy.floor() * shot.width + p.dx.floor()) * 4;
  final d = shot.rgba;
  return Color.fromARGB(d.getUint8(i + 3), d.getUint8(i), d.getUint8(i + 1), d.getUint8(i + 2));
}

/// How far apart two colours are: the most any channel differs (0–255).
int _apart(Color a, Color b) => [
  ((a.r - b.r) * 255).round().abs(),
  ((a.g - b.g) * 255).round().abs(),
  ((a.b - b.b) * 255).round().abs(),
].reduce(math.max);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Rides rides, {
  bool book = true,
  RouteEstimateRepository? ai,
  Map<String, dynamic> display = const <String, dynamic>{},
  PromoRepository? promos,
  LatLng? here,
  ScheduledRidesConfig? scheduled,
  Brightness brightness = Brightness.light,
  Size size = const Size(400, 860),
  PageStyles? styles,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      rideRepositoryProvider.overrideWithValue(rides),
      routeEstimateRepositoryProvider.overrideWithValue(ai ?? _NoAi()),
      geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
      coinTradeQuoteProvider.overrideWith((ref) => Future.error('offline')),
      serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
      rideServicesProvider.overrideWith(
        (ref) async => const [
          RideService('Teksi', 'Metered taxi', 1, 4),
          RideService('GET XL', 'Up to 6 seats', 1.5, 6),
        ],
      ),
      recentPlacesProvider.overrideWith((ref) async => const [_eco, _klcc]),
      displaySettingsBlobProvider.overrideWith((ref) async => display),
      appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
      deviceBlockedProvider.overrideWith((ref) async => false),
      profileProvider.overrideWith((ref) async => null),
      fareTariffsProvider.overrideWith((ref) async => const []),
      meterLaunchSessionProvider.overrideWithValue(null),
      promoRepositoryProvider.overrideWithValue(promos ?? PromoRepository(null)),
      if (here != null) locationSourceProvider.overrideWithValue(_Here(here)),
      if (scheduled != null) scheduledRidesConfigProvider.overrideWith((ref) async => scheduled),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/ride/:id', builder: (_, s) => Text('ride ${s.pathParameters['id']}')),
    ],
  );
  await tester.pumpWidget(
    RepaintBoundary(
      key: _screen,
      child: PageStyleScope(
        styles: styles ?? PageStyles.none,
        child: UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(theme: appTheme(brightness), routerConfig: router),
        ),
      ),
    ),
  );
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (!book) return container;
  // Pickup by dragging the map under the pin, destination from the recent
  // list.
  final g = await tester.startGesture(const Offset(200, 150));
  for (var i = 0; i < 5; i++) {
    await g.moveBy(const Offset(0, 8));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await g.up();
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  // The sheet starts fully down: drag it up to reach the recent places.
  await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, -300));
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.tap(find.text('KLCC').first);
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return container;
}

void main() {
  testWidgets("Android's navigation buttons don't cover the sheet's search bar", (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.padding = const FakeViewPadding(bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await _pump(tester, _Rides(), book: false);
    final bar = find.byKey(const ValueKey('home-search'));
    expect(bar, findsOneWidget);
    expect(tester.getRect(bar).bottom, lessThanOrEqualTo(860 - 48), reason: 'above the buttons');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets("the home vehicle bar's (i) opens the fare details", (tester) async {
    await _pump(tester, _Rides(), book: false);
    await tester.tap(find.byKey(const ValueKey('vehicle-type-GET XL')));
    await tester.pump();
    // A 44-square tap target, named for screen readers.
    final info = find.byKey(const ValueKey('vehicle-info-GET XL'));
    expect(tester.getSize(info).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(info).height, greaterThanOrEqualTo(44));
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel('Fare details for GET XL'), findsOneWidget);
    semantics.dispose();
    await tester.tap(info);
    await tester.pumpAndSettle();
    final sheet = find.byKey(const ValueKey('fare-details-sheet'));
    expect(find.descendant(of: sheet, matching: find.text('GET XL')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Fares in the app:')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.byType(DemandNote)), findsNothing, reason: 'no high-fare note here');
    expect(find.byKey(const ValueKey('fare-tax')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('fare-info-ok')));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
  });

  testWidgets('all the way down, a short screen still shows the whole search bar', (tester) async {
    await _pump(tester, _Rides(), book: false);
    // A short phone, its navigation bar already taken off the bottom.
    tester.view.physicalSize = const Size(400, 600);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final bar = find.byKey(const ValueKey('home-search'));
    expect(bar, findsOneWidget);
    expect(tester.getRect(bar).bottom, lessThanOrEqualTo(600), reason: 'inside the sheet, not cut off');
    // Dragged down, it stops there.
    await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(tester.getRect(bar).bottom, lessThanOrEqualTo(600));
  });

  for (final b in Brightness.values) {
    testWidgets('high demand: a labelled band that opens how much higher, the uplift by each price, the fare note '
        '(${b.name})', (tester) async {
      final handle = tester.ensureSemantics();
      final ai = _SlowAi();
      await _pump(tester, _Rides(), ai: ai, brightness: b);
      ai.answer.complete((
        estimate: const RouteEstimate(
          distanceKm: 60,
          durationMin: 90,
          trend: FareTrend(direction: FareTrendDirection.up, fromFareRange: false, aiMin: 30, standardMin: 20),
        ),
        unavailable: false,
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The arrows are named.
      expect(find.bySemanticsLabel(RegExp(r'High demand\. Heavy traffic')), findsWidgets);
      // Each row: the uplift beside its price, from the fare with and
      // without the traffic-aware basis.
      for (final name in ['Teksi', 'GET XL']) {
        final u = find.byKey(ValueKey('uplift-$name'));
        expect(u, findsOneWidget);
        expect(tester.widget<Text>(u).data, startsWith('+RM'));
      }
      expect(find.bySemanticsLabel(RegExp(r'High demand, \+RM')), findsWidgets);
      // The fare line says it.
      final note = tester.widget<Text>(find.byKey(const ValueKey('route-demand-note')));
      expect(note.data, startsWith('Includes high demand +RM'));
      expect(note.data, endsWith(tester.widget<Text>(find.byKey(const ValueKey('uplift-Teksi'))).data!.substring(1)));
      // The band is a button with a label, opening how much higher.
      expect(find.bySemanticsLabel('High demand, fare is higher. Fare details'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('high-demand')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('demand-higher'))).data,
        matches(RegExp(r'^Fares are \d+% higher right now because of demand')),
      );
      expect(tester.takeException(), isNull);
      handle.dispose();
    });
  }

  for (final size in const [Size(360, 640), Size(844, 390)]) {
    testWidgets('band and promo bar both fit a short or sideways phone (${size.width.round()}x${size.height.round()})',
        (tester) async {
      final ai = _SlowAi();
      await _pump(tester, _Rides(), ai: ai, size: size, promos: _Promos([_ride5]));
      ai.answer.complete((
        estimate: const RouteEstimate(
          distanceKm: 60,
          durationMin: 90,
          trend: FareTrend(direction: FareTrendDirection.up, fromFareRange: true),
        ),
        unavailable: false,
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      final promo = find.byKey(const ValueKey('confirm-promo-bar'));
      if (promo.evaluate().isNotEmpty) {
        // Both bars on screen, the band above the promo code.
        final band = tester.getRect(find.byKey(const ValueKey('high-demand')));
        expect(band.top, greaterThanOrEqualTo(0));
        // Its foot runs on behind the promo bar, past that bar's rounded corners.
        expect(band.bottom, tester.getRect(promo).top + SheetTopBar.underlap);
        // Its visible top; the foot tucks under the sheet.
        await tester.tapAt(tester.getRect(promo).topCenter + const Offset(0, 12));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('Promo code'), findsWidgets, reason: 'the promo code is still usable');
      }
    });
  }

  // ---- The bars over the sheet: no map shows under or between them ----
  /// The fare judged high (or low), for the demand band.
  Future<void> judged(WidgetTester tester, _SlowAi ai, [FareTrendDirection dir = FareTrendDirection.up]) async {
    ai.answer.complete((
      estimate: RouteEstimate(distanceKm: 12, durationMin: 30, trend: FareTrend(direction: dir, fromFareRange: true)),
      unavailable: false,
    ));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The admin's Map sheet top curve, deeper than the app's 20.
  const deep = 40.0;
  PageStyles? curve(double? r) => r == null ? null : PageStyles({'app': {'mapSheetRadius': r}});
  String mode(bool bidding) => bidding ? 'bidding' : 'fixed';

  for (final b in Brightness.values) {
    for (final bidding in const [false, true]) {
      for (final radius in const [null, deep]) {
        testWidgets('band over the promo bar: its foot behind the promo bar, the promo bar\'s behind the sheet '
            '(${mode(bidding)}, curve ${radius ?? 'default'}, ${b.name})', (tester) async {
          final ai = _SlowAi();
          await _pump(tester, _Rides(bidding: bidding), ai: ai, brightness: b, promos: _Promos([_ride5]), styles: curve(radius));
          await judged(tester, ai);
          expect(tester.takeException(), isNull);
          final t = Theme.of(tester.element(find.byType(HomeScreen)));
          // The demand band shows for a fixed fare and for an offer alike.
          final band = tester.getRect(find.byKey(const ValueKey('high-demand')));
          final promo = tester.getRect(find.byKey(const ValueKey('confirm-promo-bar')));
          final sheetTop = tester.getRect(find.byKey(const ValueKey('map-sheet-header'))).top;
          final r = radius ?? 20;
          // The promo bar's foot runs behind the sheet past its rounded corners,
          // the band's behind the promo bar past that bar's (16).
          expect(promo.bottom - sheetTop, greaterThan(r));
          expect(band.bottom - promo.top, greaterThan(16));
          expect(band.top, lessThan(promo.top), reason: 'the band stands above the promo bar');
          // And as drawn: in the sheet's corner the promo bar's fill shows, in
          // the promo bar's corner the band's, never the map.
          final shot = await _shoot(tester, 'bars_${mode(bidding)}_${b.name}${radius == null ? '' : '_curve40'}');
          expect(_apart(_pixel(shot, Offset(1, sheetTop + 1)), ConfirmPromoBar.fillFor(t, applied: true)), lessThan(40));
          expect(_apart(_pixel(shot, Offset(1, promo.top + 1)), t.colorScheme.surfaceContainerHighest), lessThan(40));
        });
      }

      testWidgets('the band alone: its foot behind the sheet past a deep curve (${mode(bidding)}, ${b.name})',
          (tester) async {
        final ai = _SlowAi();
        await _pump(tester, _Rides(bidding: bidding), ai: ai, brightness: b, styles: curve(deep));
        await judged(tester, ai, FareTrendDirection.down);
        final t = Theme.of(tester.element(find.byType(HomeScreen)));
        final band = tester.getRect(find.byKey(const ValueKey('low-demand')));
        expect(find.byKey(const ValueKey('confirm-promo-bar')), findsNothing);
        final sheetTop = tester.getRect(find.byKey(const ValueKey('map-sheet-header'))).top;
        expect(band.bottom - sheetTop, greaterThan(deep));
        final shot = await _shoot(tester, 'bars_${mode(bidding)}_band_${b.name}');
        expect(_apart(_pixel(shot, Offset(1, sheetTop + 1)), demandBandColor(t)), lessThan(40));
        expect(_apart(_pixel(shot, Offset(1, sheetTop + deep - 6)), demandBandColor(t)), lessThan(40));
      });
    }

    for (final radius in const [null, deep]) {
      testWidgets('a bar in front of the sheet: a foot fills the sheet\'s corners (curve ${radius ?? 'default'}, ${b.name})',
          (tester) async {
        final ai = _SlowAi();
        await _pump(
          tester,
          _Rides(),
          ai: ai,
          brightness: b,
          promos: _Promos([_ride5]),
          styles: curve(radius),
          display: const {'discountBarInFront': true},
        );
        await judged(tester, ai);
        final t = Theme.of(tester.element(find.byType(HomeScreen)));
        final promo = tester.getRect(find.byKey(const ValueKey('confirm-promo-bar')));
        final foot = tester.getRect(find.byKey(const ValueKey('confirm-bar-foot')));
        final sheetTop = tester.getRect(find.byKey(const ValueKey('map-sheet-header'))).top;
        final r = radius ?? 20;
        expect(promo.bottom, moreOrLessEquals(sheetTop), reason: 'it stands on the sheet\'s top edge');
        expect(foot.top, lessThan(promo.bottom), reason: 'from behind the bar');
        expect(foot.bottom - sheetTop, greaterThan(r), reason: 'down past the sheet\'s corners');
        final shot = await _shoot(tester, 'bars_front_${b.name}${radius == null ? '' : '_curve40'}');
        expect(_apart(_pixel(shot, Offset(1, sheetTop + 1)), ConfirmPromoBar.fillFor(t, applied: true)), lessThan(40));
      });
    }
  }

  testWidgets('an up trend that does not raise the fare shows no uplift and no note', (tester) async {
    final ai = _SlowAi();
    await _pump(tester, _Rides(), ai: ai);
    ai.answer.complete((
      estimate: const RouteEstimate(
        distanceKm: 1,
        durationMin: 3,
        trend: FareTrend(direction: FareTrendDirection.up, fromFareRange: true),
      ),
      unavailable: false,
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('fare-trend-up')), findsWidgets);
    expect(find.byKey(const ValueKey('uplift-Teksi')), findsNothing, reason: 'no made-up uplift');
    expect(find.byKey(const ValueKey('route-demand-note')), findsNothing);
  });

  testWidgets('fare trend arrows stand before every fare, and leave the one the rider changes', (tester) async {
    final ai = _SlowAi();
    await _pump(tester, _Rides(bidding: true), ai: ai);
    ai.answer.complete((
      estimate: const RouteEstimate(
        distanceKm: 12,
        durationMin: 30,
        trend: FareTrend(direction: FareTrendDirection.up, fromFareRange: false, aiMin: 30, standardMin: 20),
      ),
      unavailable: false,
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The chosen card's fare and the other card's price; the demand bar
    // over the list carries its own (bidding too).
    final band = find.byKey(const ValueKey('high-demand'));
    expect(band, findsOneWidget, reason: 'the demand bar shows while bidding too');
    const up = ValueKey('fare-trend-up');
    expect(find.descendant(of: band, matching: find.byKey(up)), findsOneWidget);
    int onCards() => find.byKey(up).evaluate().length - find.descendant(of: band, matching: find.byKey(up)).evaluate().length;
    expect(onCards(), 2);
    expect(find.bySemanticsLabel(RegExp('10 min longer than on clear roads')), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('fare-raise')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(onCards(), 1, reason: 'only the untouched card');
  });

  for (final dir in FareTrendDirection.values) {
    testWidgets('a fixed fare carries the ${dir.name} arrows on every row, chosen too, and its demand bar', (tester) async {
      final ai = _SlowAi();
      await _pump(tester, _Rides(), ai: ai);
      ai.answer.complete((
        estimate: RouteEstimate(
          distanceKm: 12,
          durationMin: 30,
          trend: FareTrend(direction: dir, fromFareRange: true),
        ),
        unavailable: false,
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final key = ValueKey('fare-trend-${dir.name}');
      expect(find.byKey(const ValueKey('fare-raise')), findsNothing, reason: 'no bidding');
      expect(
        find.descendant(of: find.byKey(const ValueKey('service-Teksi')), matching: find.byKey(key)),
        findsOneWidget,
        reason: 'the chosen row',
      );
      expect(
        find.descendant(of: find.byKey(const ValueKey('service-GET XL')), matching: find.byKey(key)),
        findsOneWidget,
        reason: 'the other row',
      );
      final up = dir == FareTrendDirection.up;
      // The band in the discount bar's place, opening why.
      final band = find.byKey(ValueKey(up ? 'high-demand' : 'low-demand'));
      expect(band, findsOneWidget);
      expect(find.byKey(ValueKey(up ? 'low-demand' : 'high-demand')), findsNothing);
      // No promo code fits this trip (0242): the band alone, no promo bar.
      expect(find.byKey(const ValueKey('demand-promo-bars')), findsNothing);
      expect(find.byKey(const ValueKey('confirm-promo-bar')), findsNothing);
      await tester.tap(band);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Fare details'), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('demand-sheet')), matching: find.byKey(key)),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('fare-info-ok')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // And in the chosen vehicle's details.
      await tester.tap(find.byKey(const ValueKey('fare-details')));
      // The arrows never settle: they move on.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.descendant(of: find.byKey(const ValueKey('fare-details-sheet')), matching: find.byKey(key)),
        findsOneWidget,
      );
    });
  }

  Future<void> addStop(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(const ValueKey('confirm-add-stop')));
    await _settle(tester);
    await tester.tap(find.text(name).last);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('add-stop-add')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('adding a stop: its steps, then what it adds, to Add or Cancel', (tester) async {
    final ai = _SlowAi();
    await _pump(tester, _Rides(), ai: ai);
    ai.answer.complete((estimate: null, unavailable: false));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final card = find.byKey(const ValueKey('confirm-address-card'));
    expect(find.descendant(of: card, matching: find.textContaining('KLCC', findRichText: true)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-add-stop')));
    await _settle(tester);
    await tester.tap(find.text('Eco Majestic').last);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('add-stop-progress')), findsOneWidget);
    expect(find.byKey(const ValueKey('calculating-fare')), findsOneWidget, reason: 'one box, not two');
    expect(
      [addStopSteps[0], addStopSteps[1], addStopSteps[2]].contains(
        tester.widget<Text>(find.byKey(const ValueKey('calculating-title'))).data,
      ),
      isTrue,
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('add-stop-progress')), findsNothing);
    expect(find.byKey(const ValueKey('add-stop-confirm')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-stop-cost')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-stop-time')), findsOneWidget);
    // Cancel: the trip as it was.
    await tester.tap(find.byKey(const ValueKey('add-stop-cancel')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('add-stop-confirm')), findsNothing);
    expect(find.textContaining('route stops', findRichText: true), findsNothing, reason: 'the stop is not added');
    expect(tester.takeException(), isNull);
  });

  testWidgets('"Ask before adding a stop" off: the stop is added without Add or Cancel', (tester) async {
    await _pump(tester, _Rides(), display: const {'addStopConfirm': false});
    await tester.tap(find.byKey(const ValueKey('confirm-add-stop')));
    await _settle(tester);
    await tester.tap(find.text('Eco Majestic').last);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('add-stop-confirm')), findsNothing);
    expect(find.textContaining('2 route stops', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stop is priced by the AI through it, and again when the stops change', (tester) async {
    final ai = _StopsAi();
    await _pump(tester, _Rides(), ai: ai);
    expect(ai.asked, [<LatLng>[]]);
    await addStop(tester, 'Eco Majestic');
    expect(ai.asked.last, [_eco.point], reason: 'the stop goes to the AI');
    expect(find.textContaining('2 route stops', findRichText: true), findsOneWidget);
    expect(find.byKey(const ValueKey('fare-trend-up')), findsWidgets, reason: 'judged high or low through the stop');

    // Rearranged on "Destination addresses": asked again, in the new order.
    await tester.tap(find.byKey(const ValueKey('confirm-drop')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('route-stop-remove-1')));
    await _settle(tester);
    expect(ai.asked.last, <LatLng>[], reason: 'Eco Majestic is the destination now');
    expect(find.byKey(const ValueKey('fare-trend-up')), findsWidgets);
  });

  testWidgets('an answer that did not go through the stops does not price the trip', (tester) async {
    final ai = _StopsAi(old: true);
    await _pump(tester, _Rides(), ai: ai);
    expect(find.byKey(const ValueKey('fare-trend-up')), findsWidgets, reason: 'no stops: it covers the trip');
    await addStop(tester, 'Eco Majestic');
    expect(ai.asked.last, [_eco.point]);
    expect(find.byKey(const ValueKey('fare-trend-up')), findsNothing, reason: 'pickup → drop-off only: map route');
  });

  testWidgets('"Calculating fare" covers the confirm step until the AI estimate is in', (tester) async {
    final ai = _SlowAi();
    await _pump(tester, _Rides(), ai: ai);
    expect(find.byKey(const ValueKey('calculating-fare')), findsOneWidget);
    expect(find.text('Calculating fare'), findsOneWidget);
    ai.answer.complete((estimate: null, unavailable: false));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('calculating-fare')), findsNothing);
    expect(find.byKey(const ValueKey('traffic-unavailable')), findsNothing);
  });

  testWidgets('an AI fare service that is on but gives nothing warns about traffic', (tester) async {
    final ai = _SlowAi();
    await _pump(tester, _Rides(), ai: ai);
    ai.answer.complete((estimate: null, unavailable: true));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text(trafficUnavailableTitle), findsOneWidget);
    await tester.tap(find.text('OK'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text(trafficUnavailableTitle), findsNothing);
  });

  testWidgets('Where to & for how much? leads the sheet, over the vehicles, with two recent places', (tester) async {
    await _pump(tester, _Rides(), book: false);
    final search = find.byKey(const ValueKey('home-search'));
    expect(search, findsOneWidget, reason: 'one search bar, not two');
    expect(find.text('Where to & for how much?'), findsOneWidget);
    expect(tester.getRect(search).bottom, lessThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('vehicle-type-bar'))).top));
    // Both recent places in view with the sheet all the way down, under the vehicles.
    for (final p in ['Eco Majestic', 'KLCC']) {
      final row = find.byKey(ValueKey('home-recent-$p'));
      expect(tester.getRect(row).bottom, lessThanOrEqualTo(860));
      expect(tester.getRect(row).top, greaterThan(tester.getRect(search).bottom));
    }
    // A recent place goes straight on to the confirm step, sheet still down.
    await tester.tap(find.byKey(const ValueKey('home-recent-KLCC')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('confirm-address-card')), findsOneWidget);
  });

  testWidgets('on a small phone at large text the search bar and both recent places still show', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, _Rides(), book: false);
    tester.view.physicalSize = const Size(375, 667);
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byKey(const ValueKey('home-search'))).bottom, lessThanOrEqualTo(667));
    expect(tester.getRect(find.byKey(const ValueKey('home-recent-KLCC'))).bottom, lessThanOrEqualTo(667));
  });

  testWidgets("Display Settings' switches still hide the search bar and the recent places", (tester) async {
    await _pump(tester, _Rides(), book: false, display: const {'searchBar': false, 'recentLocations': false});
    expect(find.byKey(const ValueKey('home-search')), findsNothing);
    // The plain Where to? row stands in for it, still first.
    final where = find.byKey(const ValueKey('home-where-to'));
    expect(where, findsOneWidget);
    expect(tester.getRect(where).bottom, lessThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('vehicle-type-bar'))).top));
    expect(find.byKey(const ValueKey('home-recent-KLCC')), findsNothing);
  });

  for (final b in Brightness.values) {
    testWidgets('Home page layout: its order, its search words and its switches (${b.name})', (tester) async {
      // Recent places moved above the search bar, the bar reworded, the
      // vehicle bar switched off.
      await _pump(tester, _Rides(), book: false, brightness: b, display: {
        homeLayoutKey: {
          'sections': [
            {'id': 'recent', 'type': 'recent', 'atRest': 1, 'more': false},
            {'id': 'search', 'type': 'search', 'text': 'Ke mana hari ini?'},
            {'id': 'vehicles', 'type': 'vehicles', 'on': false},
            {'id': 'fold', 'type': 'fold'},
          ],
        },
      });
      expect(tester.takeException(), isNull);
      expect(find.text('Ke mana hari ini?'), findsOneWidget);
      expect(find.byKey(const ValueKey('vehicle-type-bar')), findsNothing);
      // One recent place with the sheet down, above the bar; the rest not kept.
      final recent = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('home-recent-'));
      expect(recent, findsOneWidget);
      expect(tester.getRect(recent).bottom, lessThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('home-search'))).top));
    });
  }

  testWidgets('a box or a tile set to Ride opens Enter your route, as the search bar does', (tester) async {
    await _pump(tester, _Rides(), book: false, display: {
      homeLayoutKey: {
        'sections': [
          {'id': 'boxes', 'type': 'boxes', 'on': true, 'rows': ['k1'], 'boxes': [
            {'name': 'Ride', 'route': rideSearchRoute},
          ]},
          {'id': 't', 'type': 'tiles', 'title': 'Go', 'items': [
            {'id': 'go', 'caption': 'Ride', 'route': rideSearchRoute},
          ]},
          {'id': 'fold', 'type': 'fold'},
        ],
      },
    });
    for (final key in ['service-box-0', 'home-tile-go']) {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await _settle(tester);
      await tester.tap(find.byKey(ValueKey(key)));
      await _settle(tester);
      expect(find.text('Enter your route'), findsOneWidget, reason: key);
      Navigator.of(tester.element(find.text('Enter your route'))).pop();
      await _settle(tester);
      expect(find.text('Enter your route'), findsNothing);
    }
  });

  testWidgets('the pin and its address bar stay halfway between the top and the sheet, whatever the map height', (tester) async {
    // Where the map keeps the pin: the middle of what shows above the sheet
    // all the way down (map_focus_test.dart), shifted by this.
    Future<Offset> shift(Map<String, dynamic> display) async {
      await _pump(tester, _Rides(), book: false, display: display);
      final s = tester.widget<MapFocusShift>(find.byType(MapFocusShift)).shift;
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
      return s;
    }

    expect(await shift(const {}), Offset.zero);
    // A taller map reaches 265 above the screen, its centre half that up:
    // the pin is put back down by as much, and the old Drop pin height
    // (made to offset it) no longer counts.
    expect(await shift(const {'mapHeightOffset': 265, 'dropPinTopOffset': 65}), const Offset(0, 132.5));
    // Pin up / down moves it from the middle.
    expect(await shift(const {pinMiddleOffsetKey: 30}), const Offset(0, 30));
  });

  testWidgets('on its side at large text the whole route card shows above the confirm sheet', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, _Rides());
    tester.view.physicalSize = const Size(852, 393);
    tester.view.padding = const FakeViewPadding(left: 59, right: 59, bottom: 21);
    tester.view.viewPadding = const FakeViewPadding(left: 59, right: 59, bottom: 21);
    await _settle(tester);
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byKey(const ValueKey('confirm-address-card')));
    final sheetTop = tester.getRect(find.byKey(const ValueKey('map-sheet-handle'))).top;
    expect(card.bottom, lessThanOrEqualTo(sheetTop), reason: 'the route card clear of the sheet');
  });

  testWidgets('the Entrance chip answers a screen reader; the keypad hints, takes digits only, and clears', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, _Rides());
    final chip = find.bySemanticsLabel('Set entrance');
    expect(chip, findsOneWidget);
    tester.semantics.tap(find.semantics.byLabel('Set entrance'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('entrance-hint')), findsOneWidget);
    expect(find.text('ABC'), findsNothing);
    expect(find.byKey(const ValueKey('entrance-clear')), findsNothing, reason: 'nothing to clear yet');
    await tester.tap(find.byKey(const ValueKey('entrance-key-4')));
    await tester.pump();
    expect(find.byKey(const ValueKey('entrance-hint')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('entrance-done')));
    await _settle(tester);
    expect(find.text('Entrance 4'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-entrance')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('entrance-clear')));
    await _settle(tester);
    expect(find.text('Entrance 4'), findsNothing);
    expect(find.text('Entrance'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets("a vehicle's fare details sheet is as tall as what it holds", (tester) async {
    await _pump(tester, _Rides(), book: false);
    await tester.tap(find.byKey(const ValueKey('vehicle-type-GET XL')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('vehicle-info-GET XL')));
    await tester.pumpAndSettle();
    final sheet = tester.getRect(find.byType(BottomSheet));
    final ok = tester.getRect(find.byKey(const ValueKey('fare-info-ok')));
    expect(sheet.top, greaterThan(860 * 0.2), reason: 'not full height');
    expect(sheet.bottom - ok.bottom, lessThan(80), reason: 'no empty space under OK');
  });

  testWidgets('the main screen opens with its sheet fully down', (tester) async {
    await _pump(tester, _Rides(), book: false);
    final top = tester.getTopLeft(find.byKey(const ValueKey('map-sheet-handle'))).dy;
    // At its lowest: down to the two recent places under the search bar
    // and the vehicles, not half way up.
    expect(top, greaterThan(860 * 0.55), reason: 'at its lowest, not half way up');
    final second = tester.getRect(find.byKey(const ValueKey('home-recent-KLCC')));
    expect(second.bottom, lessThanOrEqualTo(860), reason: 'the second recent place shows whole');
  });

  testWidgets('the route is framed between the address card and the bar on the sheet', (tester) async {
    await _pump(tester, _Rides(), promos: _Promos([_ride5]));
    await _settle(tester);
    final card = tester.getRect(find.byKey(const ValueKey('confirm-address-card')));
    final bar = tester.getRect(find.byKey(const ValueKey('confirm-promo-bar')));
    for (final mark in ['map-dot-pickup', 'map-dot-drop']) {
      final r = tester.getRect(find.byKey(ValueKey(mark)));
      expect(r.top, greaterThanOrEqualTo(card.bottom), reason: '$mark below the card');
      expect(r.bottom, lessThanOrEqualTo(bar.top), reason: '$mark above the bar on the sheet');
    }
  });

  testWidgets('on its side, Back on the confirm step stays off the route card and the notch', (tester) async {
    await _pump(tester, _Rides());
    // Turned on its side (iPhone 15): the notch left and right, the home bar.
    tester.view.physicalSize = const Size(852, 393);
    tester.view.padding = const FakeViewPadding(left: 59, right: 59, bottom: 21);
    tester.view.viewPadding = const FakeViewPadding(left: 59, right: 59, bottom: 21);
    await _settle(tester);
    expect(tester.takeException(), isNull);
    final back = tester.getRect(find.byKey(const ValueKey('confirm-back')));
    final card = tester.getRect(find.byKey(const ValueKey('confirm-address-card')));
    expect(back.overlaps(card), isFalse, reason: 'Back beside the route card, not on it');
    expect(back.left, greaterThanOrEqualTo(59), reason: 'clear of the notch');
    expect(back.top, greaterThanOrEqualTo(0));
    await tester.tap(find.byKey(const ValueKey('confirm-back')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('confirm-address-card')), findsNothing);
  });

  testWidgets('the confirm step is laid out as Expo ride-confirm', (tester) async {
    await _pump(tester, _Rides());

    expect(find.byKey(const ValueKey('confirm-address-card')), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey('confirm-address-card')), matching: find.text('Pinned location')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('confirm-back')), findsOneWidget);
    expect(find.byKey(const ValueKey('map-recenter')), findsNothing, reason: "Expo's confirm has no recenter");
    expect(find.byKey(const ValueKey('map-dot-pickup')), findsOneWidget);
    expect(find.byKey(const ValueKey('map-dot-drop')), findsOneWidget);
    // No promo code fits the trip (0242): no promo bar.
    expect(find.byKey(const ValueKey('confirm-promo-bar')), findsNothing);
    // A fixed fare (inDrive's): the chosen row keeps its price, outlined,
    // with no fare section and no −/+; its details are behind the (i).
    expect(find.byKey(const ValueKey('confirm-fare')), findsNothing);
    expect(find.text('Recommended fare'), findsNothing);
    expect(
      find.descendant(of: find.byKey(const ValueKey('service-Teksi')), matching: find.byKey(const ValueKey('fare-details'))),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('fare-edit')), findsNothing);
    expect(find.byKey(const ValueKey('fare-raise')), findsNothing);
    expect(find.text('Fare does not include state entry tax, tolls, or parking fees'), findsOneWidget);
    // Above the pinned bar, faded out until the sheet is all the way up
    // (Expo shows it only expanded), and out again when it comes down.
    double shown() =>
        tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('map-sheet-above-footer'))).opacity;
    expect(shown(), 0);
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('confirm-disclaimer'))).dy,
      lessThan(tester.getTopLeft(find.text('Find a driver')).dy),
    );
    await tester.drag(find.byKey(const ValueKey('service-Teksi')), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(shown(), 1);
    await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(shown(), 0);
    expect(find.text('Find a driver'), findsOneWidget);
    expect(find.byKey(const ValueKey('confirm-payment')), findsOneWidget);
    // A fixed fare takes no offers, so there is nothing to auto-accept.
    expect(find.textContaining('Auto-accept offer of'), findsNothing);

    // Choosing another vehicle outlines it instead (the sheet raised to
    // reach it above the footer), and its (i) opens the fare's details.
    await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('service-GET XL')));
    await tester.pump();
    final info = find.descendant(
      of: find.byKey(const ValueKey('service-GET XL')),
      matching: find.byKey(const ValueKey('fare-details')),
    );
    expect(info, findsOneWidget);
    await tester.tap(info);
    await tester.pumpAndSettle();
    // inDrive's details: the vehicle, its rates, what an in-app fare covers.
    final sheet = find.byKey(const ValueKey('fare-details-sheet'));
    expect(find.descendant(of: sheet, matching: find.text('GET XL')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.textContaining('Flag fall')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Fares in the app:')), findsOneWidget);
    expect(find.byKey(const ValueKey('metered-note')), findsNothing, reason: 'not a taxi');
    await tester.tap(find.byKey(const ValueKey('fare-info-ok')));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);

    // Back leaves the confirm step for the home map.
    await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, 600));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-back')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('confirm-address-card')), findsNothing);
    expect(find.text('Find a driver'), findsNothing);
  });

  testWidgets('the entrance, the payment and auto-accept go with the booking', (tester) async {
    // Auto-accept is an offer setting: only where bidding is on.
    final rides = _Rides(bidding: true);
    final container = await _pump(tester, rides);

    await tester.tap(find.byKey(const ValueKey('confirm-entrance')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('entrance-key-1')));
    await tester.tap(find.byKey(const ValueKey('entrance-key-2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('entrance-done')));
    await _settle(tester);
    expect(find.text('Entrance 12'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('confirm-payment')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('payment-Get Pay')));
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('auto-accept')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('book')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(rides.created, isNotNull);
    expect(rides.created![#note], 'Entrance 12');
    expect(rides.created![#paymentMode], 'Get Pay');
    expect(container.read(autoAcceptProvider)['r9'], rides.created![#fare]);
    expect(find.text('ride r9'), findsOneWidget);
  });

  testWidgets('a region with whole fares and a tax: no decimals, the tax line, both on the booking', (tester) async {
    const pricing = RegionPricing(wholeFare: true, tax: RegionTax(name: 'SST', kind: TaxKind.percent, value: 6));
    final rides = _Rides(pricing: pricing);
    await _pump(tester, rides);
    // A fixed fare: the tax line is in the fare's details, behind the (i).
    await tester.tap(find.byKey(const ValueKey('fare-details')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fare-tax')), findsOneWidget);
    expect(find.textContaining('SST 6%'), findsOneWidget);
    // Teksi is a metered taxi: the meter decides.
    expect(find.byKey(const ValueKey('metered-note')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fare-info-ok')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('book')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final fare = rides.created![#fare] as double;
    expect(fare, fare.roundToDouble(), reason: 'a whole fare');
    expect(rides.created![#pricing], pricing);
  });

  testWidgets('the options button beside Find a driver opens Options; they go with the booking', (tester) async {
    final rides = _Rides();
    await _pump(tester, rides);
    Badge badge() => tester.widget<Badge>(
      find.descendant(of: find.byKey(const ValueKey('confirm-options')), matching: find.byType(Badge)),
    );
    expect(badge().isLabelVisible, isFalse);
    expect(find.text('Note to driver (optional)'), findsNothing, reason: 'the note is Options → Comments');
    expect(
      tester.getCenter(find.byKey(const ValueKey('confirm-options'))).dx,
      greaterThan(tester.getCenter(find.byKey(const ValueKey('book'))).dx),
      reason: 'right of Find a driver',
    );

    await tester.tap(find.byKey(const ValueKey('confirm-options')));
    await _settle(tester);
    expect(find.text('Options'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('option-child-seat')));
    await tester.pump();
    // "Pet with me" opens Your pets; cancelled with none saved, it stays off.
    await tester.tap(find.byKey(const ValueKey('option-pet')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ride-pets')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pets-cancel')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ride-pets')), findsNothing);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('option-pet'))).value, isFalse);
    // Comments: ← goes back to Options without saving; Save keeps it.
    await tester.tap(find.byKey(const ValueKey('option-comments')));
    await _settle(tester);
    expect(find.text('What your driver should know?'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('option-comments-field')), 'Not this');
    await tester.tap(find.byKey(const ValueKey('option-comments-back')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('option-comments-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('ride-options')), findsOneWidget);
    expect(find.text('Not this'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('option-comments')));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('option-comments-field')), 'Blue gate');
    await tester.tap(find.byKey(const ValueKey('option-comments-done')));
    await _settle(tester);
    expect(find.descendant(of: find.byKey(const ValueKey('option-comments')), matching: find.text('Blue gate')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ride-options-close')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ride-options')), findsNothing);
    expect(badge().isLabelVisible, isTrue, reason: 'an option is on');

    // ✕ on Comments closes Options too.
    await tester.tap(find.byKey(const ValueKey('confirm-options')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('option-comments')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('option-comments-x')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('option-comments-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('ride-options')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('book')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(rides.created![#note], 'Child safety seat · Blue gate');
    expect(rides.created![#pets], isEmpty);
    expect(rides.created![#passengers], 1);
  });

  // Admin → Display Settings → Ride Options (0248).
  for (final b in Brightness.values) {
    testWidgets('every ride option hidden: Options keeps Comments (${b.name})', (tester) async {
      await _pump(
        tester,
        _Rides(),
        brightness: b,
        display: const {
          'rideOptions': {
            'hidden': ['child-seat', 'more-passengers', 'pet', 'assistance'],
          },
        },
      );
      expect(find.byKey(const ValueKey('book')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-options')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ride-options')), findsOneWidget);
      expect(find.byKey(const ValueKey('option-comments')), findsOneWidget);
      for (final k in ['option-child-seat', 'option-more-passengers', 'option-pet', 'option-assistance']) {
        expect(find.byKey(ValueKey(k)), findsNothing);
      }
    });

    testWidgets('pet and assistance charges: in the fare, a line before booking, on the booking (${b.name})',
        (tester) async {
      const display = {
        'petPhotoRequired': false,
        'petTypes': ['Dog', 'Iguana'],
        'petCharges': {
          'Iguana': {'kind': 'fixed', 'value': 10, 'per': 'pet'},
        },
        'assistanceCatalogue': [
          {
            'id': 'custom-1',
            'name': 'Sign language',
            'emoji': '🤟',
            'group': 'Talking',
            'charge': {'kind': 'fixed', 'value': 5},
          },
        ],
      };
      // The same trip with no options, for its fare.
      final plain = _Rides();
      await _pump(tester, plain, display: display, brightness: b);
      expect(find.byKey(const ValueKey('option-charges-note')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('book')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final base = plain.created![#fare] as double;
      expect(plain.created![#optionCharges], isEmpty);

      final rides = _Rides();
      await _pump(tester, rides, display: display, brightness: b);
      await tester.tap(find.byKey(const ValueKey('confirm-options')));
      await _settle(tester);
      // A custom pet type.
      await tester.tap(find.byKey(const ValueKey('option-pet')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pets-type-Iguana')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pet-size-Iguana-0-M')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pets-done')));
      await _settle(tester);
      // A custom help item.
      await tester.tap(find.byKey(const ValueKey('option-assistance')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('assist-item-custom-1')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('assist-done')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('ride-options-close')));
      await _settle(tester);

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('option-charges-note')),
          matching: find.text('Pet charge RM10 · Assistance charge RM5'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('book')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(rides.created![#fare], closeTo(base + 15, 0.001), reason: 'the fare includes the charges');
      expect([for (final c in rides.created![#optionCharges] as List<OptionChargeLine>) c.toJson()], [
        {'kind': 'pet', 'name': 'Pet charge', 'amount': 10.0},
        {'kind': 'assistance', 'name': 'Assistance charge', 'amount': 5.0},
      ]);
      expect((rides.created![#pets] as List<RidePet>).single.type, 'Iguana');
      expect((rides.created![#assistance] as RideAssistance).items.single.name, 'Sign language');
      expect(rides.created![#note], 'Pet with me: 1 iguana (M) · Assistance: Sign language');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    });

    testWidgets('promo codes asked about the fare less the option charges when the admin says so (${b.name})',
        (tester) async {
      final promos = _Promos([_ride5]);
      final rides = _Rides();
      await _pump(
        tester,
        rides,
        brightness: b,
        promos: promos,
        display: const {
          'petPhotoRequired': false,
          'petCharges': {
            'Dog': {'kind': 'fixed', 'value': 10, 'per': 'pet'},
          },
          'rideOptionCharges': {'commission': true, 'promo': false},
        },
      );
      await tester.tap(find.byKey(const ValueKey('confirm-options')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('option-pet')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pets-type-Dog')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pet-size-Dog-0-M')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pets-done')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('ride-options-close')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('book')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final fare = rides.created![#fare] as double;
      expect(promos.fares.last, closeTo(fare - 10, 0.001), reason: 'the code discounts the fare less the pet charge');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    });
  }

  testWidgets('booking for someone else is a toggle under GET.coin; the modal fills it in', (tester) async {
    final rides = _Rides();
    await _pump(tester, rides);
    final toggle = find.byKey(const ValueKey('who-riding'));
    expect(find.text('Someone else'), findsNothing, reason: 'no Me / Someone else buttons any more');
    // In the pinned footer, below the auto-accept row's top and above Find a driver.
    expect(find.descendant(of: find.byKey(const ValueKey('confirm-footer')), matching: toggle), findsOneWidget);
    expect(tester.getTopLeft(toggle).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('book'))).dy));
    expect(tester.widget<ConfirmSwitch>(toggle).value, isFalse);

    // Closed without Done the first time: back off.
    await tester.tap(toggle);
    await _settle(tester);
    expect(find.byKey(const ValueKey('book-for-sheet')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('book-for-done'))).onPressed, isNull);
    await tester.tapAt(const Offset(200, 20));
    await _settle(tester);
    expect(find.byKey(const ValueKey('book-for-sheet')), findsNothing);
    expect(tester.widget<ConfirmSwitch>(toggle).value, isFalse);
    expect(find.byKey(const ValueKey('book-for-edit')), findsNothing);
    expect(find.text('Find a driver'), findsOneWidget);

    // Filled in and Done: on, and the row shows who, with a pen.
    await tester.tap(toggle);
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('book-for-name')), 'Aminah');
    await tester.enterText(find.byKey(const ValueKey('book-for-phone')), '+60 12-345 6789');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('book-for-done')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('book-for-sheet')), findsNothing);
    expect(tester.widget<ConfirmSwitch>(toggle).value, isTrue);
    expect(tester.widget<Text>(find.byKey(const ValueKey('book-for-who'))).data, 'Aminah · +60123456789');
    expect(find.text('Find a driver for Aminah'), findsOneWidget);

    // The pen reopens it filled in; closing it keeps them.
    await tester.tap(find.byKey(const ValueKey('book-for-edit')));
    await _settle(tester);
    expect(find.widgetWithText(TextField, 'Aminah'), findsOneWidget);
    await tester.tapAt(const Offset(200, 20));
    await _settle(tester);
    expect(find.text('Find a driver for Aminah'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('book')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(rides.created![#bookedFor], (name: 'Aminah', phone: '+60123456789'));
  });

  testWidgets('switching it off books for the rider again', (tester) async {
    final rides = _Rides();
    await _pump(tester, rides);
    final toggle = find.byKey(const ValueKey('who-riding'));
    await tester.tap(toggle);
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('book-for-name')), 'Aminah');
    await tester.enterText(find.byKey(const ValueKey('book-for-phone')), '+60 12-345 6789');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('book-for-done')));
    await _settle(tester);
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<ConfirmSwitch>(toggle).value, isFalse);
    expect(find.text('Find a driver'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('book')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(rides.created![#bookedFor], isNull);
  });

  testWidgets('where bidding is on the chosen card has the round −/+ and a pencil', (tester) async {
    await _pump(tester, _Rides(bidding: true));
    expect(find.byKey(const ValueKey('fare-raise')), findsOneWidget);
    expect(find.byKey(const ValueKey('fare-edit')), findsOneWidget);
    final before = tester.widget<Text>(find.byKey(const ValueKey('confirm-fare'))).data;
    await tester.tap(find.byKey(const ValueKey('fare-raise')));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('confirm-fare'))).data, isNot(before));
    expect(find.textContaining('Recommended fare: '), findsOneWidget);
  });

  testWidgets('the pencil opens Offer your fare; a typed fare and the payment come back to the sheet', (tester) async {
    await _pump(tester, _Rides(bidding: true));
    await tester.tap(find.byKey(const ValueKey('fare-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('offer-fare-screen')), findsOneWidget);
    expect(find.text('You can change the recommended fare'), findsOneWidget);
    final recommended = tester.widget<Text>(find.byKey(const ValueKey('offer-fare-note'))).data!;
    expect(recommended, startsWith('Recommended fare: '));

    // A fare far below the range is named, and Find a driver waits for a good one.
    await tester.enterText(find.byKey(const ValueKey('offer-fare-field')), '1');
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('offer-fare-note'))).data, startsWith('Minimum fare is'));
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('offer-fare-find'))).onPressed, isNull);

    final field = tester.widget<TextField>(find.byKey(const ValueKey('offer-fare-field')));
    final typed = (double.parse(recommended.replaceAll(RegExp(r'[^0-9.]'), '')) + 2).round();
    await tester.enterText(find.byKey(const ValueKey('offer-fare-field')), '$typed');
    await tester.pump();
    expect(field.controller!.text, '$typed');
    await tester.tap(find.byKey(const ValueKey('offer-fare-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('offer-fare-screen')), findsNothing);
    expect(tester.widget<Text>(find.byKey(const ValueKey('confirm-fare'))).data, contains('$typed'));
  });

  testWidgets('Offer your fare leaves by the iOS edge swipe, and its fare still comes back', (tester) async {
    await _pump(tester, _Rides(bidding: true));
    await tester.tap(find.byKey(const ValueKey('fare-edit')));
    await tester.pumpAndSettle();
    final page = find.byKey(const ValueKey('offer-fare-screen'));
    final route = ModalRoute.of(tester.element(page))!;
    // Nothing holds the page: the swipe back is on.
    expect(route.popDisposition, RoutePopDisposition.pop);
    final recommended = tester.widget<Text>(find.byKey(const ValueKey('offer-fare-note'))).data!;
    final typed = (double.parse(recommended.replaceAll(RegExp(r'[^0-9.]'), '')) + 3).round();
    await tester.enterText(find.byKey(const ValueKey('offer-fare-field')), '$typed');
    await tester.pump();
    // Left as the swipe (or the system Back) leaves it: popped with no value.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(page, findsNothing);
    expect(tester.widget<Text>(find.byKey(const ValueKey('confirm-fare'))).data, contains('$typed'));
  });

  testWidgets('Offer your fare follows a stop added there: the route and the recommended fare', (tester) async {
    await _pump(tester, _Rides(bidding: true));
    await tester.tap(find.byKey(const ValueKey('fare-edit')));
    await tester.pumpAndSettle();
    final note = find.byKey(const ValueKey('offer-fare-note'));
    final before = tester.widget<Text>(note).data!;
    final field = tester.widget<TextField>(find.byKey(const ValueKey('offer-fare-field'))).controller!;
    final typedBefore = field.text;
    expect(find.text('KLCC'), findsOneWidget, reason: 'one destination');

    await tester.tap(find.byKey(const ValueKey('offer-fare-add-stop')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('recent-2.93,101.83')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('add-stop-add')));
    await _settle(tester);

    expect(find.byKey(const ValueKey('offer-fare-screen')), findsOneWidget, reason: 'still on the page');
    expect(find.text('2 route stops'), findsOneWidget);
    final after = tester.widget<Text>(note).data!;
    expect(after, isNot(before), reason: 'the fare for the new route');
    expect(field.text, isNot(typedBefore), reason: 'an untouched fare follows the new one');
    expect(tester.takeException(), isNull);
  });

  testWidgets("Enter your route: the From changes the pickup, the destination kept", (tester) async {
    await _pump(tester, _Rides());
    final card = find.byKey(const ValueKey('confirm-address-card'));
    expect(find.descendant(of: card, matching: find.textContaining('KLCC', findRichText: true)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-drop')));
    await _settle(tester);
    expect(find.text('Enter your route'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('place-search-from')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('recent-2.93,101.83')));
    await _settle(tester);
    expect(find.text('Enter your route'), findsNothing);
    expect(
      find.descendant(of: find.byKey(const ValueKey('confirm-pickup')), matching: find.text('Eco Majestic')),
      findsOneWidget,
      reason: 'the new pickup',
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('KLCC', findRichText: true)),
      findsOneWidget,
      reason: 'the destination kept',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('on the web, browser Back steps back from the confirm step to the search, as its arrow does', (tester) async {
    final history = _History();
    final before = webOverlayBack;
    addTearDown(() => webOverlayBack = before);
    webOverlayBack = history.stack = OverlayBackStack(history, session: 'h');
    await _pump(tester, _Rides());
    expect(find.text('Find a driver'), findsOneWidget);
    expect(history.stack.markers, hasLength(1));

    // The browser's Back lands on the page's own entry.
    expect(history.stack.onPop(null, '/'), isTrue);
    await _settle(tester);
    expect(find.text('Find a driver'), findsNothing);
    expect(history.stack.markers, isEmpty);
    expect(history.moves, isEmpty, reason: 'the Back already took the entry off');
    // Back in the route search, on the destination picked before.
    final field = find.byKey(const ValueKey('place-search-field'));
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, 'KLCC');
    await tester.tap(find.byKey(const ValueKey('place-search-close')));
    await _settle(tester);
    expect(field, findsNothing);

    // Left by the back arrow: its entry is taken off.
    await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, -300));
    await _settle(tester);
    await tester.tap(find.text('KLCC').first);
    await _settle(tester);
    expect(history.stack.markers, hasLength(1));
    await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, 600));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-back')));
    await _settle(tester);
    expect(history.stack.markers, isEmpty);
    expect(history.moves, [-1]);
    expect(find.byKey(const ValueKey('place-search-field')), findsOneWidget, reason: 'the arrow does the same');
  });

  for (final bidding in const [true, false]) {
    testWidgets('a ride to book again comes filled in on the confirm step (#131${bidding ? ', offer mode' : ''})',
        (tester) async {
      final rides = _Rides(bidding: bidding);
      final container = await _pump(tester, rides, book: false);
      container.read(rideRebookProvider.notifier).set(
        const RideRebook(pickup: _eco, drop: _klcc, service: 'GET XL', fare: 33, payment: 'Cash'),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(container.read(rideRebookProvider), isNull, reason: 'filled in once');
      expect(find.byKey(const ValueKey('book')), findsOneWidget, reason: 'on the confirm step');
      expect(find.text('Eco Majestic'), findsWidgets);
      // Sent by the rider, through the booking every ride takes.
      expect(rides.created, isNull);
      await tester.tap(find.byKey(const ValueKey('book')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(rides.created![#pickupName], 'Eco Majestic');
      expect(rides.created![#dropName], 'KLCC');
      expect(rides.created![#service], 'GET XL');
      if (bidding) expect(rides.created![#fare], 33, reason: 'the same fare offered again');
      expect(find.text('ride r9'), findsOneWidget);
    });
  }

  // ---- Promo codes (0242) ----
  for (final b in Brightness.values) {
    testWidgets('promo: auto-applied with a note, changed, removed, a typed code refused then one taken (${b.name})',
        (tester) async {
      final rides = _Rides();
      final promos = _Promos([_ride5, _pct]);
      await _pump(tester, rides, promos: promos, brightness: b);
      await _settle(tester);
      expect(promos.offersAsked, greaterThan(0));
      final bar = find.byKey(const ValueKey('confirm-promo-bar'));
      expect(bar, findsOneWidget);
      expect(find.text('RIDE5 applied automatically'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^You pay about .* after promo$')), findsOneWidget);

      // Changed to the other code.
      await tester.tap(bar);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('promo-offer-TENPC')));
      await _settle(tester);
      expect(find.text('TENPC applied'), findsOneWidget);

      // Removed: the codes stay on offer, none applied, and none comes back by itself.
      await tester.tap(bar);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('promo-remove')));
      await _settle(tester);
      expect(find.text('2 promos available'), findsOneWidget);
      expect(find.text('Tap to apply'), findsOneWidget);

      // A typed code the server refuses: its reason, and nothing applied.
      await tester.tap(bar);
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('promo-code')), 'bad1');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('promo-apply')));
      await _settle(tester);
      expect(promos.checked, ['BAD1']);
      expect(find.text('This code needs a fare of at least RM50.00.'), findsOneWidget);
      // Another one it takes.
      await tester.enterText(find.byKey(const ValueKey('promo-code')), 'good3');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('promo-apply')));
      await _settle(tester);
      expect(find.text('GOOD3 applied'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('book')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(rides.created![#promoCodeId], 'c3', reason: 'booked with the code; the server checks it again');
    });

    testWidgets('promo: the auto-applied code is booked unless removed (${b.name})', (tester) async {
      final rides = _Rides();
      await _pump(tester, rides, promos: _Promos([_ride5]), brightness: b);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('book')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(rides.created![#promoCodeId], 'c5');
    });

    testWidgets('promo: a ride for later gets the codes for its pickup time, then is booked with one (${b.name})',
        (tester) async {
      final rides = _Rides();
      final promos = _Promos([_ride5], false, [_sched7]);
      await _pump(tester, rides, promos: promos, brightness: b,
          scheduled: const ScheduledRidesConfig(enabled: true, feeFixed: 2));
      await _settle(tester);
      expect(find.text('RIDE5 applied automatically'), findsOneWidget, reason: 'a ride now first');
      await tester.tap(find.byKey(const ValueKey('book-later')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pickup-confirm')));
      await _settle(tester);
      // The same promo sheet, with the codes for that pickup time: the
      // now-only code gone, the scheduled one applied by itself.
      expect(promos.pickupTimes.whereType<DateTime>(), isNotEmpty, reason: 'asked with the pickup time');
      expect(find.text('Promo for your scheduled ride'), findsOneWidget);
      expect(find.byKey(const ValueKey('promo-later-at')), findsOneWidget);
      expect(find.byKey(const ValueKey('promo-offer-SCHED7')), findsOneWidget);
      expect(find.byKey(const ValueKey('promo-offer-RIDE5')), findsNothing);
      expect(find.text('Book with SCHED7'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('promo-continue')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(rides.created![#scheduleAt], isNotNull);
      expect(rides.created![#promoCodeId], 's7', reason: 'stored on the booking; the server checks it at pickup time');
      expect(tester.takeException(), isNull);
    });

    testWidgets('home: the promo zone bar shows only inside a zone (${b.name})', (tester) async {
      final inZone = _Promos(const [], true);
      await _pump(tester, _Rides(), book: false, promos: inZone, here: _eco.point, brightness: b);
      await _settle(tester);
      expect(inZone.zoneAsked, isNotEmpty);
      expect(find.byKey(const ValueKey('promo-zone-bar')), findsOneWidget);
      expect(find.text('You are within promo zone'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('home: no promo zone bar outside a zone (${b.name})', (tester) async {
      final out = _Promos(const [], false);
      await _pump(tester, _Rides(), book: false, promos: out, here: _eco.point, brightness: b);
      await _settle(tester);
      expect(out.zoneAsked, isNotEmpty);
      expect(find.byKey(const ValueKey('promo-zone-bar')), findsNothing);
    });
  }

  // Admin → Display Settings → Bottom sheet minimum height: the admin's px
  // move how low each sheet rests, pulled all the way down.
  group('bottom sheet minimum height', () {
    /// The sheet's top edge once pulled all the way down and let go.
    Future<double> restTop(WidgetTester tester) async {
      await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, 600));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return tester.getRect(find.byKey(const ValueKey('map-sheet-header'))).top;
    }

    for (final b in Brightness.values) {
      testWidgets('home: the adjustment moves the least height by its px; the search bar stays whole (${b.name})',
          (tester) async {
        Future<double> top(Map<String, dynamic> display) async {
          await tester.pumpWidget(const SizedBox());
          await _pump(tester, _Rides(), book: false, display: display, brightness: b);
          return restTop(tester);
        }

        final auto = await top(const {});
        // Every item shown, the recent places too, with the sheet down.
        expect(tester.getRect(find.byKey(const ValueKey('home-recent-KLCC'))).bottom, lessThanOrEqualTo(860));
        expect(auto - await top(const {homeSheetMinAdjustKey: 100}), closeTo(100, 1));
        expect(await top(const {homeSheetMinAdjustKey: -40}) - auto, closeTo(40, 1));
        // An item turned off takes its height off; the adjustment still adds.
        final noRecent = await top(const {'recentLocations': false});
        expect(noRecent, greaterThan(auto + 50));
        expect(noRecent - await top(const {'recentLocations': false, homeSheetMinAdjustKey: 60}), closeTo(60, 1));
        // Taken right down, it stops with the search bar whole.
        await top(const {'rideTypes': false, 'recentLocations': false, homeSheetMinAdjustKey: -60});
        final bar = tester.getRect(find.byKey(const ValueKey('home-search')));
        expect(bar.top, greaterThan(tester.getRect(find.byKey(const ValueKey('map-sheet-header'))).bottom));
        expect(bar.bottom, lessThanOrEqualTo(860));
        expect(tester.takeException(), isNull);
      });

      testWidgets('confirm: the adjustment moves the least height by its px (${b.name})', (tester) async {
        Future<double> top(Map<String, dynamic> display) async {
          await tester.pumpWidget(const SizedBox());
          await _pump(tester, _Rides(), display: display, brightness: b);
          expect(find.byKey(const ValueKey('confirm-address-card')), findsOneWidget);
          return restTop(tester);
        }

        final auto = await top(const {});
        expect(auto - await top(const {confirmSheetMinAdjustKey: 40}), closeTo(40, 1));
        expect(await top(const {confirmSheetMinAdjustKey: -40}) - auto, closeTo(40, 1));
        expect(tester.takeException(), isNull);
      });
    }
  });
}

/// The browser's history, as far as the confirm step's entry goes.
class _History implements OverlayHistory {
  late OverlayBackStack stack;
  final moves = <int>[];

  @override
  String get page => '/';

  @override
  Future<void> push(String marker) async {}

  @override
  void go(int delta) {
    moves.add(delta);
    scheduleMicrotask(() => stack.onPop(null, '/'));
  }

  @override
  Future<void> settled() async {}
}
