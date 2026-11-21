// The rider's home map keeps up with the rider: the blue dot moves as they do.
// Only the dot. The map, the pickup pin and its address stay where the rider
// put them, and move as they always did: when the map is dragged, or recenter
// is tapped.
//
// A rider is walked and driven along the real home screen here, a fix a second
// as a phone's GPS gives them, and after every frame the dot is compared with
// where they truly are.
import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/app_permissions.dart';
import 'package:get_ride/src/core/fare.dart' show RideService;
import 'package:get_ride/src/core/follow_motion.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/data/active_location.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/live_fix.dart';
import 'package:get_ride/src/data/location_source.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/permission_probe.dart';
import 'package:get_ride/src/data/promo_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/route_estimate_repository.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/features/ride/home_parts.dart' show PickupPill;
import 'package:get_ride/src/features/ride/home_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/live_position.dart';
import 'package:get_ride/src/widgets/map_drag_pin.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _start = LatLng(3.1000, 101.6000);
final _clock0 = DateTime.utc(2026, 11, 20, 8);

/// 50 frames a second.
const _frame = Duration(milliseconds: 20);
const _frameSeconds = 0.02;

/// A point [east] and [north] metres from [_start].
LatLng _at(double east, double north) => movedAlong(movedAlong(_start, north, 0), east, 90);

/// The phone: where it is now ([at], which a test moves), and whether its
/// location may be used.
class _Phone implements LocationSource {
  _Phone({this.allowed = true});
  LatLng at = _start;
  bool allowed;
  int asked = 0;

  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<LocationPermission> checkPermission() async =>
      allowed ? LocationPermission.whileInUse : LocationPermission.denied;
  @override
  Future<LocationPermission> requestPermission() async {
    asked++;
    allowed = true;
    return LocationPermission.whileInUse;
  }

  @override
  Future<LatLng?> lastKnown() async => at;
  @override
  Future<LatLng> current(LocationAccuracy accuracy) async => at;
}

/// A phone whose position can be followed as it changes, as the real one's.
class _LivePhone extends _Phone implements LiveLocationSource {
  _LivePhone({super.allowed});
  final fixes = StreamController<LiveFix>.broadcast();
  int followed = 0;

  @override
  Stream<LiveFix> liveFixes() {
    followed++;
    return fixes.stream;
  }
}

/// Location on and allowed, as far as the recenter button asks.
class _Allowed implements PermissionProbe {
  @override
  Future<(bool, PermState)> location() async => (true, PermState.granted);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Rides implements RideRepository {
  @override
  Future<List<RideRequest>> ridesOnTheGo() async => const [];
  @override
  Future<bool> biddingEnabledFor(LatLng pickup, Future<AreaInfo?> Function() area) async => false;
  @override
  Future<RegionPricing> pricingFor(LatLng pickup, Future<AreaInfo?> Function() area) async => RegionPricing.none;
  @override
  Future<String?> publicIp() async => null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _NoAi implements RouteEstimateRepository {
  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

/// The home screen on [phone], its live fixes those a test adds to the stream
/// [live] gives. [showing] off puts it under another tab, as the app's tabs do.
Future<void> _home(
  WidgetTester tester,
  _Phone phone,
  Stream<LiveFix> Function() live, {
  ValueNotifier<bool>? showing,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      locationSourceProvider.overrideWithValue(phone),
      liveFixesProvider.overrideWithValue(live),
      permissionProbeProvider.overrideWithValue(_Allowed()),
      rideRepositoryProvider.overrideWithValue(_Rides()),
      routeEstimateRepositoryProvider.overrideWithValue(_NoAi()),
      geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
      coinTradeQuoteProvider.overrideWith((ref) => Future.error('offline')),
      serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
      rideServicesProvider.overrideWith((ref) async => const [RideService('Teksi', 'Metered taxi', 1, 4)]),
      recentPlacesProvider.overrideWith((ref) async => const <Place>[]),
      displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
      appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
      deviceBlockedProvider.overrideWith((ref) async => false),
      profileProvider.overrideWith((ref) async => null),
      fareTariffsProvider.overrideWith((ref) async => const []),
      meterLaunchSessionProvider.overrideWithValue(null),
      promoRepositoryProvider.overrideWithValue(PromoRepository(null)),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const HomeScreen())]);
  final app = MaterialApp.router(theme: appTheme(Brightness.light), routerConfig: router);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: showing == null
          ? app
          : ValueListenableBuilder<bool>(
              valueListenable: showing,
              builder: (_, on, child) => TickerMode(enabled: on, child: child!),
              child: app,
            ),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester, [int tenths = 10]) async {
  for (var i = 0; i < tenths; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder get _mapFinder => find.descendant(of: find.byType(MapDragPin), matching: find.byType(FlutterMap)).first;

MapCamera _camera(WidgetTester tester) => tester.widget<FlutterMap>(_mapFinder).mapController!.camera;

RideMap _rideMap(WidgetTester tester) => tester.widget<RideMap>(find.byType(RideMap));

/// The pickup, as the drag pin has it.
LatLng? _pickup(WidgetTester tester) => tester.widget<MapDragPin>(find.byType(MapDragPin)).pin;

final _dot = find.byKey(const ValueKey('map-me-dot'));

/// Where a point of the screen is on the ground.
LatLng _onGround(WidgetTester tester, Offset onScreen) =>
    _camera(tester).screenOffsetToLatLng(onScreen - tester.getTopLeft(_mapFinder));

/// Where the dot is on the ground: the point of the map under its middle.
LatLng _dotOnGround(WidgetTester tester) => _onGround(tester, tester.getCenter(_dot));

/// Where the rider truly is at a moment: place, speed (m/s) and course.
typedef _Truth = ({LatLng at, double speed, double course});

/// Moves the rider from [from] to [to] seconds: a fix of where they are once a
/// second into [live], a frame every 20 ms, and [each] after every frame with
/// the time and where they truly are then. The phone's own position follows.
Future<void> _move(
  WidgetTester tester,
  _Phone phone,
  StreamController<LiveFix> live,
  _Truth Function(double t) truth, {
  required double from,
  required double to,
  void Function(double t, _Truth now)? each,
}) async {
  final first = (from / _frameSeconds).round(), last = (to / _frameSeconds).round();
  for (var f = first; f < last; f++) {
    final t = f * _frameSeconds;
    if (f % 50 == 0) {
      final now = truth(t);
      phone.at = now.at;
      live.add((
        at: now.at,
        speed: now.speed,
        course: now.speed > 0 ? now.course : null,
        time: _clock0.add(Duration(milliseconds: (t * 1000).round())),
        accuracy: 5,
      ));
    }
    await tester.pump(_frame);
    each?.call(t + _frameSeconds, truth(t + _frameSeconds));
  }
}

/// North along the road at [speed] m/s.
_Truth Function(double t) _north(double speed) =>
    (t) => (at: _at(0, speed * t), speed: speed, course: 0);

void main() {
  late StreamController<LiveFix> live;
  setUp(() => live = StreamController<LiveFix>.broadcast());
  tearDown(() => live.close());

  testWidgets('riding along: the dot keeps up; the map, the pin and its address stay where they are', (tester) async {
    final phone = _Phone();
    await _home(tester, phone, () => live.stream);
    // Located: the rider, the pickup and the dot are on the first fix.
    expect(_rideMap(tester).me, _start);
    expect(_pickup(tester), _start);
    expect(metresApart(_dotOnGround(tester), _start), lessThan(0.1));

    final map = _rideMap(tester);
    final camera = _camera(tester);
    final centre = camera.center, zoom = camera.zoom;
    final pin = tester.getRect(find.byKey(const ValueKey('pickup-pin')));
    final address = tester.widget<PickupPill>(find.byType(PickupPill)).place;

    // 29 km/h up the road for 8 s: 0.16 m a frame.
    LatLng? before;
    var worst = 0.0, slowest = double.infinity, fastest = 0.0;
    await _move(tester, phone, live, _north(8), from: 0, to: 8, each: (t, now) {
      final dotAt = _dotOnGround(tester);
      if (t > 1.5) {
        worst = math.max(worst, metresApart(dotAt, now.at));
        final step = metresApart(before!, dotAt);
        slowest = math.min(slowest, step);
        fastest = math.max(fastest, step);
      }
      before = dotAt;
      // Nothing else has moved: not the map…
      expect(_camera(tester).center, centre, reason: 'the map at ${t}s');
      expect(_camera(tester).zoom, zoom);
      // …nor the pickup.
      expect(_pickup(tester), _start, reason: 'the pickup at ${t}s');
    });
    expect(worst, lessThan(0.6), reason: 'the dot is on the rider, not a second behind');
    expect(slowest, greaterThan(0.12), reason: 'it never stops between fixes');
    expect(fastest, lessThan(0.20), reason: 'and never jumps to catch up');
    expect(metresApart(_dotOnGround(tester), _start), greaterThan(60), reason: 'it has gone up the road with them');

    // The pin is where it stood on the screen, and says what it said.
    expect(tester.getRect(find.byKey(const ValueKey('pickup-pin'))), pin);
    expect(identical(tester.widget<PickupPill>(find.byType(PickupPill)).place, address), isTrue);
    // The map was not built again for any of it: only the dot's own layer was.
    expect(identical(_rideMap(tester), map), isTrue);
    expect(_rideMap(tester).me, _start, reason: 'the fix the pickup was set from is still that fix');
  });

  testWidgets('walking: the dot goes with them at a walk', (tester) async {
    final phone = _Phone();
    await _home(tester, phone, () => live.stream);
    var worst = 0.0;
    await _move(tester, phone, live, _north(1.4), from: 0, to: 12, each: (t, now) {
      if (t > 2.5) worst = math.max(worst, metresApart(_dotOnGround(tester), now.at));
    });
    expect(worst, lessThan(0.5));
    expect(_pickup(tester), _start);
  });

  testWidgets('standing, with the GPS wandering round them as it does: the dot keeps still', (tester) async {
    final phone = _Phone();
    await _home(tester, phone, () => live.stream);
    // Standing here: the first fix to say so is where they are.
    live.add((at: _start, speed: 0.0, course: null, time: _clock0, accuracy: 5));
    await _settle(tester, 5);
    final wander = math.Random(3);
    final first = _dotOnGround(tester);
    var furthest = 0.0;
    for (var second = 1; second <= 20; second++) {
      live.add((
        at: movedAlong(_start, wander.nextDouble() * 1.5, wander.nextDouble() * 360),
        speed: wander.nextDouble() * 0.2,
        course: null,
        time: _clock0.add(Duration(seconds: second)),
        accuracy: 5,
      ));
      for (var f = 0; f < 50; f++) {
        await tester.pump(_frame);
        furthest = math.max(furthest, metresApart(first, _dotOnGround(tester)));
      }
    }
    // A point on the screen is 1.2 m of ground at the home map's zoom.
    expect(furthest, lessThan(1.2), reason: 'within a point of where they stand');
  });

  testWidgets('recenter: the map goes to where they are now, and the pin with it', (tester) async {
    final phone = _Phone();
    await _home(tester, phone, () => live.stream);
    final pin = tester.getCenter(find.byKey(const ValueKey('pickup-pin')));
    await _move(tester, phone, live, _north(8), from: 0, to: 8);
    // Stopped, 64 m up the road.
    final here = _at(0, 64);
    phone.at = here;
    live.add((at: here, speed: 0.0, course: null, time: _clock0.add(const Duration(seconds: 8)), accuracy: 5));
    await _settle(tester);
    expect(_pickup(tester), _start, reason: 'not moved until asked');
    expect(metresApart(_dotOnGround(tester), here), lessThan(0.5));

    await tester.tap(find.byKey(const ValueKey('map-recenter')));
    await _settle(tester, 20);
    expect(metresApart(_pickup(tester)!, here), lessThan(0.5), reason: 'the pickup is where they are now');
    // The pin stands where it stood on the screen, with the dot under its foot.
    final pinNow = tester.getRect(find.byKey(const ValueKey('pickup-pin')));
    expect((pinNow.center - pin).distance, lessThan(1.5));
    expect(metresApart(_dotOnGround(tester), _pickup(tester)!), lessThan(0.5));
  });

  testWidgets('dragging the map moves the pin, as before, and leaves the dot on the rider', (tester) async {
    final phone = _Phone();
    await _home(tester, phone, () => live.stream);
    await _move(tester, phone, live, _north(1.4), from: 0, to: 3);
    live.add((at: _at(0, 4.2), speed: 0.0, course: null, time: _clock0.add(const Duration(seconds: 3)), accuracy: 5));
    await _settle(tester);
    final dotWas = _dotOnGround(tester);

    final g = await tester.startGesture(const Offset(200, 250));
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await g.up();
    await _settle(tester, 20);

    expect(metresApart(_pickup(tester)!, _start), greaterThan(40), reason: 'the pickup went where the map was dragged');
    expect(metresApart(_dotOnGround(tester), dotWas), lessThan(0.05), reason: 'the dot did not go with it');
  });

  testWidgets('under another tab the GPS is not kept on for a dot nobody sees', (tester) async {
    final listening = <bool>[];
    live = StreamController<LiveFix>.broadcast(
      onListen: () => listening.add(true),
      onCancel: () => listening.add(false),
    );
    final showing = ValueNotifier(true);
    addTearDown(showing.dispose);
    await _home(tester, _Phone(), () => live.stream, showing: showing);
    expect(listening, [true]);

    showing.value = false; // another tab is in front
    await _settle(tester, 2);
    expect(listening, [true, false]);

    showing.value = true; // back on the home map
    await _settle(tester, 2);
    expect(listening, [true, false, true]);
  });

  testWidgets('location not yet allowed: asked for once, by the locate — then the dot goes live', (tester) async {
    final phone = _Phone(allowed: false);
    var opened = 0;
    Stream<LiveFix> fixes() {
      opened++;
      // As the app's own stream: nothing while location is not allowed.
      return phone.allowed ? live.stream : const Stream.empty();
    }

    await _home(tester, phone, fixes);
    expect(phone.asked, 1, reason: 'the home screen asked, as it always has');
    expect(opened, 2, reason: 'tried on opening, and again once a fix showed location is allowed');
    await _move(tester, phone, live, _north(8), from: 0, to: 4);
    expect(metresApart(_dotOnGround(tester), _at(0, 32)), lessThan(1.0));
  });

  test('the app\'s own stream never asks for location, and gives nothing until it is allowed', () async {
    final phone = _LivePhone(allowed: false);
    final container = ProviderContainer(overrides: [locationSourceProvider.overrideWithValue(phone)]);
    addTearDown(container.dispose);
    addTearDown(phone.fixes.close);
    expect(await container.read(liveFixesProvider)().toList(), isEmpty);
    expect(phone.asked, 0, reason: 'asking is the locate\'s to do');
    expect(phone.followed, 0, reason: 'the GPS is not even started');

    // Allowed (the locate asked, and the rider said yes): now it is the phone's own stream.
    phone.allowed = true;
    final got = <LiveFix>[];
    final sub = container.read(liveFixesProvider)().listen(got.add);
    await pumpEventQueue();
    phone.fixes.add((at: _start, speed: 1.0, course: 10.0, time: _clock0, accuracy: 5));
    await pumpEventQueue();
    expect(got.single.at, _start);
    expect(phone.followed, 1);
    expect(phone.asked, 0);
    await sub.cancel();
  });

  test('a stand-in for the phone that only answers when asked has no position to follow', () async {
    final phone = _Phone();
    final container = ProviderContainer(overrides: [locationSourceProvider.overrideWithValue(phone)]);
    addTearDown(container.dispose);
    expect(await container.read(liveFixesProvider)().toList(), isEmpty);
  });

  test('what the rider\'s map asks of the GPS: the best fix, every one, nothing in the background', () {
    final ios = riderMapLocationSettings(platform: TargetPlatform.iOS, web: false) as AppleSettings;
    expect(ios.accuracy, LocationAccuracy.best);
    expect(ios.distanceFilter, 0);
    expect(ios.activityType, ActivityType.other, reason: 'a rider may be on foot: not told they are driving');
    expect(ios.pauseLocationUpdatesAutomatically, isFalse);
    expect(ios.allowBackgroundLocationUpdates, isFalse);
    expect(ios.showBackgroundLocationIndicator, isFalse);
    final android = riderMapLocationSettings(platform: TargetPlatform.android, web: false) as AndroidSettings;
    expect(android.accuracy, LocationAccuracy.best);
    expect(android.intervalDuration, driverFixInterval, reason: 'the plugin would ask for one every 5 s');
    expect(android.foregroundNotificationConfig, isNull);
    expect(riderMapLocationSettings(web: true).accuracy, LocationAccuracy.best);
  });

  group('LivePosition', () {
    testWidgets('fixes in, a position a frame at a time out; it rests when the device does', (tester) async {
      final position = LivePosition(vsync: tester);
      addTearDown(position.dispose);
      expect(position.shown.value, isNull);
      expect(position.latest, isNull);

      position.take((at: _start, speed: 5.0, course: 90.0, time: _clock0, accuracy: 5));
      expect(position.shown.value, _start);
      expect(position.latest, _start);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final carried = metresApart(_start, position.shown.value!);
      expect(carried, greaterThan(1.5), reason: 'carried east at 5 m/s between fixes');
      expect(carried, lessThan(3.0));

      // A fix from before the one in hand is not news.
      position.take((at: _at(-50, 0), speed: 5.0, course: 90.0, time: _clock0.subtract(const Duration(seconds: 2)), accuracy: 5));
      expect(position.latest, _start);

      // Stopped: it comes to rest, and stops asking for frames.
      final stopped = _at(5, 0);
      position.take((at: stopped, speed: 0.0, course: null, time: _clock0.add(const Duration(seconds: 1)), accuracy: 5));
      await tester.pumpAndSettle();
      expect(metresApart(position.shown.value!, stopped), lessThan(0.1));

      position.clear();
      expect(position.shown.value, isNull);
      expect(position.latest, isNull);
    });
  });
}
