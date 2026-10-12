// My Ride for the rider: the favourite drivers page (add by code or QR,
// remove), its settings, the confirm step's switch into createRequest, and
// the searching banner (countdown, offer to all, add a driver).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/fare.dart' show RideService;
import 'package:get_ride/src/core/my_ride.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/my_ride_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/route_estimate_repository.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/features/my_ride/my_ride_parts.dart';
import 'package:get_ride/src/features/my_ride/my_ride_screen.dart';
import 'package:get_ride/src/features/my_ride/my_ride_settings.dart';
import 'package:get_ride/src/features/ride/home_screen.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ali = FavouriteDriver(
  driverId: 'd1',
  name: 'Ali',
  available: true,
  online: true,
  lastSeen: LastSeen.online,
  distanceKm: 1.5,
  colour: 'White',
  make: 'Perodua',
  model: 'Bezza',
  plate: 'VAB 1234',
  rating: 4.8,
);
const _ben = FavouriteDriver(driverId: 'd2', name: 'Ben', available: true, lastSeen: LastSeen.today, plate: 'WXY 9');
const _chan = FavouriteDriver(driverId: 'd3', name: 'Chan', available: false);
const _siti = FavouriteDriver(driverId: 'd9', name: 'Siti', available: true, make: 'Proton', model: 'Saga');

class _FakeMyRide implements MyRideRepository {
  _FakeMyRide([List<FavouriteDriver>? list]) : list = list ?? [_ali, _ben, _chan];

  List<FavouriteDriver>? list;
  AddFavouriteResult addResult = const FavouriteAdded(_siti);
  final codes = <String>[];
  final removed = <String>[];
  final offers = <String>[];
  final added = <List<String>>[];
  OfferToAllOutcome offerOutcome = OfferToAllOutcome.opened;

  @override
  Future<List<FavouriteDriver>?> favourites({double? lat, double? lng}) async => list == null ? null : [...list!];

  @override
  Future<AddFavouriteResult> addByCode(String input) async {
    codes.add(input);
    final r = addResult;
    if (r is FavouriteAdded && r.driver != null) list = [...?list, r.driver!];
    return r;
  }

  @override
  Future<bool> remove(String driverId) async {
    removed.add(driverId);
    list = [
      for (final d in list ?? const <FavouriteDriver>[])
        if (d.driverId != driverId) d,
    ];
    return true;
  }

  @override
  Future<OfferToAllOutcome> offerToAll(String requestId) async {
    offers.add(requestId);
    return offerOutcome;
  }

  @override
  Future<List<String>?> addTargets(String requestId, List<String> driverIds) async {
    added.add(driverIds);
    return ['d1', ...driverIds];
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _MemoryStore extends MyRideSettingsStore {
  _MemoryStore([this.saved = const MyRideSettings()]);
  MyRideSettings saved;

  @override
  Future<MyRideSettings> load() async => saved;

  @override
  Future<void> save(MyRideSettings s) async => saved = s;
}

Future<void> _settle(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The My Ride page (and its settings) under a router.
Future<void> _page(
  WidgetTester tester,
  _FakeMyRide repo, {
  MyRideSettingsStore? store,
  Brightness brightness = Brightness.light,
  Size size = const Size(400, 800),
  List<Override> extra = const [],
}) async {
  _size(tester, size);
  final router = GoRouter(
    initialLocation: '/account/my-ride',
    routes: [
      GoRoute(
        path: '/account/my-ride',
        builder: (_, _) => const MyRideScreen(),
        routes: [GoRoute(path: 'settings', builder: (_, _) => const MyRideSettingsScreen())],
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        currentUserIdProvider.overrideWithValue('me'),
        myRideRepositoryProvider.overrideWithValue(repo),
        myRideSettingsStoreProvider.overrideWithValue(store ?? _MemoryStore()),
        ...extra,
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: ThemeData(brightness: Brightness.light),
        darkTheme: ThemeData(brightness: Brightness.dark),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      ),
    ),
  );
  await _settle(tester);
}

void main() {
  group('rules', () {
    test('pick order: available, online, nearest, then name', () {
      const far = FavouriteDriver(driverId: 'd4', name: 'Dan', available: true, online: true, distanceKm: 9);
      expect(
        [
          for (final d in myRidePickOrder([_chan, _ben, far, _ali])) d.name,
        ],
        ['Ali', 'Dan', 'Ben', 'Chan'],
      );
    });

    test('default targets leave out the unavailable and the too far, at most 20', () {
      const far = FavouriteDriver(driverId: 'd4', name: 'Dan', available: true, online: true, distanceKm: 9);
      expect(defaultMyRideTargets([_chan, _ben, far, _ali], null), ['d1', 'd4', 'd2']);
      expect(defaultMyRideTargets([_chan, _ben, far, _ali], 5), ['d1', 'd2'], reason: 'Ben has no distance');
      final many = [for (var i = 0; i < 30; i++) FavouriteDriver(driverId: 'x$i', name: 'D$i', available: true)];
      expect(defaultMyRideTargets(many, null), hasLength(myRideMaxTargets));
    });

    test('names read short', () {
      expect(myRideNames(['d1'], [_ali, _ben]), 'Ali');
      expect(myRideNames(['d1', 'd2'], [_ali, _ben]), 'Ali and Ben');
      expect(myRideNames(['d1', 'd2', 'd3', 'zz'], [_ali, _ben, _chan]), 'Ali, Ben and 2 more');
      expect(myRideNames(['zz', 'yy'], const []), '2 drivers');
    });

    test('a rate-limited code says how long to wait', () {
      expect(
        addFavouriteMessage(AddFavouriteError.rateLimited, retryAfter: const Duration(seconds: 290)),
        'Too many codes tried. Try again in 5 minutes.',
      );
      expect(addFavouriteMessage(AddFavouriteError.rateLimited), AddFavouriteError.rateLimited.message);
      expect(addFavouriteMessage(AddFavouriteError.notFound), AddFavouriteError.notFound.message);
      expect(myRideOpensIn(const Duration(milliseconds: 41200)), 'Opens to all nearby drivers in 42s');
    });

    test('the settings store keeps both settings', () async {
      SharedPreferences.setMockInitialValues({});
      final store = MyRideSettingsStore();
      expect(await store.load(), const MyRideSettings());
      await store.save(const MyRideSettings(maxKm: 10, onByDefault: true));
      expect(await store.load(), const MyRideSettings(maxKm: 10, onByDefault: true));
      await store.save(const MyRideSettings(onByDefault: true));
      expect(await store.load(), const MyRideSettings(onByDefault: true));
    });
  });

  group('My Ride page', () {
    testWidgets('lists the favourites with their status, vehicle and distance', (tester) async {
      await _page(tester, _FakeMyRide());
      expect(find.text('Ali'), findsOneWidget);
      expect(find.text('White Perodua Bezza · VAB 1234'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Seen today'), findsOneWidget);
      expect(find.text('Unavailable'), findsOneWidget);
      expect(find.text('4.8'), findsOneWidget);
      expect(find.text('1.5 km away'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('with none, it explains how to add one', (tester) async {
      await _page(tester, _FakeMyRide([]));
      expect(find.byKey(const ValueKey('my-ride-empty')), findsOneWidget);
      expect(find.textContaining('Ask your driver for their My Ride code'), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-add')), findsOneWidget);
    });

    testWidgets("a database without My Ride says it isn't available, and offers nothing", (tester) async {
      await _page(tester, _FakeMyRide()..list = null);
      expect(find.byKey(const ValueKey('my-ride-unavailable')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-add')), findsNothing);
      expect(find.byKey(const ValueKey('my-ride-settings')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('adds a driver by code: tolerant input, and the card on success', (tester) async {
      final repo = _FakeMyRide([_ali]);
      await _page(tester, repo);
      await tester.tap(find.byKey(const ValueKey('my-ride-add')));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('favourite-code')), ' abcd-efgh ');
      await tester.tap(find.byKey(const ValueKey('favourite-code-add')));
      await _settle(tester);
      expect(repo.codes, ['ABCDEFGH']);
      expect(find.byKey(const ValueKey('favourite-added')), findsOneWidget);
      expect(find.text('Siti added to My Ride'), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('favourite-added')), matching: find.text('Proton Saga')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('favourite-added-done')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('favourite-d9')), findsOneWidget, reason: 'the list is read again');
    });

    testWidgets('a code that is not one is refused without asking the server', (tester) async {
      final repo = _FakeMyRide([_ali]);
      await _page(tester, repo);
      await tester.tap(find.byKey(const ValueKey('my-ride-add')));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('favourite-code')), 'ABC0');
      await tester.tap(find.byKey(const ValueKey('favourite-code-add')));
      await _settle(tester);
      expect(repo.codes, isEmpty);
      expect(find.text(AddFavouriteError.invalidCode.message), findsOneWidget);
    });

    for (final (name, result, message) in [
      ('not found', const FavouriteNotAdded(AddFavouriteError.notFound), AddFavouriteError.notFound.message),
      (
        'rate limited',
        const FavouriteNotAdded(AddFavouriteError.rateLimited, retryAfter: Duration(minutes: 12)),
        'Too many codes tried. Try again in 12 minutes.',
      ),
      ('not available', const MyRideNotAvailable(), myRideUnavailableMessage),
    ]) {
      testWidgets('an error is told plainly: $name', (tester) async {
        final repo = _FakeMyRide([_ali])..addResult = result;
        await _page(tester, repo);
        await tester.tap(find.byKey(const ValueKey('my-ride-add')));
        await _settle(tester);
        await tester.enterText(find.byKey(const ValueKey('favourite-code')), 'ABCDEFGH');
        await tester.tap(find.byKey(const ValueKey('favourite-code-add')));
        await _settle(tester);
        expect(find.text(message), findsOneWidget);
        expect(find.byKey(const ValueKey('favourite-added')), findsNothing);
      });
    }

    testWidgets('scans a My Ride QR; another QR is refused', (tester) async {
      final repo = _FakeMyRide([_ali]);
      late ValueChanged<String> seen;
      await _page(
        tester,
        repo,
        extra: [
          myRideScanViewProvider.overrideWithValue((_, onCode) {
            seen = onCode;
            return const ColoredBox(color: Colors.black);
          }),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('my-ride-add')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('favourite-scan')));
      await _settle(tester);
      expect(find.text('Scan My Ride QR'), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-scan-torch')), findsOneWidget);
      seen('https://example.com/pay');
      await tester.pump();
      expect(find.byKey(const ValueKey('my-ride-scan-error')), findsOneWidget);
      seen('getride://myride/abcdefgh');
      await _settle(tester);
      expect(repo.codes, ['ABCDEFGH']);
      expect(find.text('Siti added to My Ride'), findsOneWidget);
    });

    testWidgets('a code can be pasted on the scan screen', (tester) async {
      final repo = _FakeMyRide([_ali]);
      await _page(tester, repo, extra: [myRideScanViewProvider.overrideWithValue((_, _) => const SizedBox())]);
      await tester.tap(find.byKey(const ValueKey('my-ride-add')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('favourite-scan')));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('my-ride-scan-manual')), 'abcd efgh');
      await tester.tap(find.byKey(const ValueKey('my-ride-scan-go')));
      await _settle(tester);
      expect(repo.codes, ['ABCDEFGH']);
    });

    testWidgets('removing asks first', (tester) async {
      final repo = _FakeMyRide();
      await _page(tester, repo);
      await tester.tap(find.byKey(const ValueKey('favourite-remove-d2')));
      await _settle(tester);
      expect(find.text('Remove Ben?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('favourite-remove-cancel')));
      await _settle(tester);
      expect(repo.removed, isEmpty);
      await tester.tap(find.byKey(const ValueKey('favourite-remove-d2')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('favourite-remove-confirm')));
      await _settle(tester);
      expect(repo.removed, ['d2']);
      expect(find.byKey(const ValueKey('favourite-d2')), findsNothing);
    });

    testWidgets('settings: the distance and the default are kept', (tester) async {
      final store = _MemoryStore();
      await _page(tester, _FakeMyRide(), store: store);
      await tester.tap(find.byKey(const ValueKey('my-ride-settings')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('my-ride-max-10')));
      await tester.tap(find.byKey(const ValueKey('my-ride-default-on')));
      await _settle(tester);
      expect(store.saved, const MyRideSettings(maxKm: 10, onByDefault: true));
      await tester.tap(find.byKey(const ValueKey('my-ride-max-0')));
      await _settle(tester);
      expect(store.saved, const MyRideSettings(onByDefault: true));
    });

    for (final b in Brightness.values) {
      testWidgets('${b.name} mode at 360 px: the page, the add sheet and the picker lay out', (tester) async {
        await _page(tester, _FakeMyRide(), brightness: b, size: const Size(360, 700));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('my-ride-add')));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        Navigator.of(tester.element(find.byKey(const ValueKey('favourite-code')))).pop();
        await _settle(tester);
        unawaited(showMyRidePicker(tester.element(find.byType(MyRideScreen)), drivers: [_ali, _ben, _chan], maxKm: 1));
        await _settle(tester);
        expect(find.byKey(const ValueKey('my-ride-picker')), findsOneWidget);
        expect(find.text('Farther than your 1 km limit'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('${b.name} mode on a desktop width', (tester) async {
        await _page(tester, _FakeMyRide(), brightness: b, size: const Size(1400, 900));
        expect(find.text('Ali'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('the confirm step', () {
    testWidgets('My Ride on: the picked favourites go with the booking', (tester) async {
      final rides = _Rides();
      await _home(tester, rides, _FakeMyRide(), _MemoryStore(const MyRideSettings(maxKm: 5)));
      expect(find.byKey(const ValueKey('my-ride-row')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('my-ride-switch')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('my-ride-picker')), findsOneWidget);
      // Ali and Ben are picked; Chan can't be.
      await tester.tap(find.byKey(const ValueKey('my-ride-pick-d2')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('my-ride-pick-done')));
      await _settle(tester);
      expect(find.text('To Ali first · Change'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('book')));
      await _settle(tester, 10);
      expect(rides.created![#targetDriverIds], ['d1']);
      expect(rides.created![#myRideMaxKm], 5);
    });

    testWidgets('dismissing the picker leaves My Ride off', (tester) async {
      final rides = _Rides();
      await _home(tester, rides, _FakeMyRide(), _MemoryStore());
      await tester.tap(find.byKey(const ValueKey('my-ride-switch')));
      await _settle(tester);
      await tester.tapAt(const Offset(200, 20));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('book')));
      await _settle(tester, 10);
      expect(rides.created![#targetDriverIds], isEmpty);
      expect(rides.created![#myRideMaxKm], isNull);
    });

    testWidgets('on by default: every available favourite, nearest online first', (tester) async {
      final rides = _Rides();
      await _home(tester, rides, _FakeMyRide(), _MemoryStore(const MyRideSettings(onByDefault: true)));
      expect(find.text('To Ali and Ben first · Change'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('book')));
      await _settle(tester, 10);
      expect(rides.created![#targetDriverIds], ['d1', 'd2']);
    });

    testWidgets('no switch without an available favourite, or without My Ride', (tester) async {
      await _home(tester, _Rides(), _FakeMyRide([_chan]), _MemoryStore(const MyRideSettings(onByDefault: true)));
      expect(find.byKey(const ValueKey('my-ride-row')), findsNothing);
      expect(find.byKey(const ValueKey('book')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no switch on a database without My Ride; the ride books as before', (tester) async {
      final rides = _Rides();
      await _home(tester, rides, _FakeMyRide()..list = null, _MemoryStore(const MyRideSettings(onByDefault: true)));
      expect(find.byKey(const ValueKey('my-ride-row')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('book')));
      await _settle(tester, 10);
      expect(rides.created![#targetDriverIds], isEmpty);
    });
  });

  group('searching', () {
    final t0 = DateTime.utc(2026, 10, 6, 9);
    late DateTime now;
    late StreamController<RideRequest> rows;
    late _FakeMyRide repo;

    RideRequest ride({Duration age = const Duration(seconds: 10), Map<String, dynamic> extra = const {}}) =>
        RideRequest({
          'id': 'r1',
          'rider_id': 'me',
          'status': 'open',
          'fare': 20,
          'currency': 'MYR',
          'pickup_name': 'KLCC',
          'drop_name': 'KL Sentral',
          'pickup_lat': 3.15,
          'pickup_lng': 101.71,
          'offer_me': false,
          'created_at': t0.subtract(age).toIso8601String(),
          'target_driver_ids': ['d1'],
          'targeted_until': t0.subtract(age).add(const Duration(seconds: 60)).toIso8601String(),
          ...extra,
        });

    Future<void> pump(WidgetTester tester, {Brightness brightness = Brightness.light}) async {
      SharedPreferences.setMockInitialValues({});
      _size(tester, const Size(360, 1600));
      now = t0;
      repo = _FakeMyRide();
      rows = StreamController<RideRequest>();
      addTearDown(rows.close);
      final router = GoRouter(
        initialLocation: '/ride',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('home')),
          ),
          GoRoute(
            path: '/ride',
            builder: (_, _) => const RideTrackingScreen(requestId: 'r1'),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            rideRepositoryProvider.overrideWithValue(_Rides()),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
            searchClockProvider.overrideWithValue(() => now),
            riderPositionStreamProvider.overrideWithValue(() => const Stream<LatLng>.empty()),
            fareCoinChoiceStoreProvider.overrideWithValue(FareCoinChoiceStore()),
            walletBalancesProvider.overrideWith((ref) async => const []),
            walletTxProvider.overrideWith((ref) async => const []),
            currentUserIdProvider.overrideWithValue('me'),
            myRideRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: ThemeData(brightness: brightness),
          ),
        ),
      );
    }

    Future<void> tick(WidgetTester tester, Duration by) async {
      now = now.add(by);
      await tester.pump(by);
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('counts down, then opens it to all nearby once', (tester) async {
      await pump(tester);
      rows.add(ride());
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(find.text('Offered to your drivers: Ali'), findsOneWidget);
      expect(find.text('Opens to all nearby drivers in 49s'), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-countdown')), findsOneWidget);
      await tick(tester, const Duration(seconds: 48));
      expect(repo.offers, isEmpty);
      await tick(tester, const Duration(seconds: 2));
      expect(repo.offers, ['r1']);
      expect(find.text('Now offered to all nearby drivers'), findsOneWidget);
      await tick(tester, const Duration(seconds: 3));
      rows.add(ride(age: const Duration(seconds: 65)));
      await tick(tester, const Duration(seconds: 1));
      expect(repo.offers, ['r1'], reason: 'once');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a fallback the server already pushed is not asked for again', (tester) async {
      await pump(tester);
      rows.add(ride(age: const Duration(seconds: 70), extra: {'fallback_pushed_at': t0.toIso8601String()}));
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(repo.offers, isEmpty);
      expect(find.text('Now offered to all nearby drivers'), findsOneWidget);
    });

    testWidgets('"Offer to all nearby" opens it at once', (tester) async {
      await pump(tester, brightness: Brightness.dark);
      rows.add(ride());
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      await tester.tap(find.byKey(const ValueKey('my-ride-offer-all')));
      await tick(tester, const Duration(seconds: 1));
      expect(repo.offers, ['r1']);
      expect(find.text('Now offered to all nearby drivers'), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-banner')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('adds a driver while searching', (tester) async {
      await pump(tester);
      rows.add(ride());
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      await tester.tap(find.byKey(const ValueKey('my-ride-add-target')));
      await tick(tester, const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('my-ride-pick-d1')), findsNothing, reason: 'already offered');
      expect(find.byKey(const ValueKey('my-ride-pick-d2')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('my-ride-pick-d2')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('my-ride-pick-done')));
      await tick(tester, const Duration(seconds: 1));
      expect(repo.added, [
        ['d2'],
      ]);
      expect(find.text('Offered to your drivers: Ali and Ben'), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-add-target')), findsNothing, reason: 'nobody left to add');
    });

    testWidgets('an ordinary request has no banner', (tester) async {
      await pump(tester);
      rows.add(ride(extra: {'target_driver_ids': null, 'targeted_until': null}));
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('my-ride-banner')), findsNothing);
      expect(find.byKey(const ValueKey('my-ride-opened')), findsNothing);
    });
  });
}

// ---- The home screen's confirm step -------------------------------------------------

const _eco = Place(name: 'Eco Majestic', address: 'Semenyih', point: LatLng(2.9300, 101.8300));
const _klcc = Place(name: 'KLCC', address: 'Kuala Lumpur', point: LatLng(2.9400, 101.8400));

class _Rides implements RideRepository {
  Map<Symbol, dynamic>? created;

  @override
  Future<List<RideRequest>> ridesOnTheGo() async => const [];

  @override
  Future<bool> biddingEnabledFor(LatLng pickup, Future<AreaInfo?> Function() area) async => false;

  @override
  Future<RegionPricing> pricingFor(LatLng pickup, Future<AreaInfo?> Function() area) async => RegionPricing.none;

  @override
  Future<String?> publicIp() async => null;

  @override
  Future<double> claimRideReward(RideRequest r) async => 0;

  @override
  Future<void> expireStaleOpen() async {}

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #createRequest) {
      created = i.namedArguments;
      return Future.value(RideRequest({'id': 'r9', 'rider_id': 'me', 'status': 'open', 'fare': 10}));
    }
    return super.noSuchMethod(i);
  }
}

class _NoAi implements RouteEstimateRepository {
  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

/// The home screen at its confirm step (pickup by dragging the map,
/// destination from the recent list), as test/home_confirm_test.dart does.
Future<void> _home(WidgetTester tester, _Rides rides, _FakeMyRide repo, MyRideSettingsStore store) async {
  SharedPreferences.setMockInitialValues({});
  _size(tester, const Size(400, 860));
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      rideRepositoryProvider.overrideWithValue(rides),
      routeEstimateRepositoryProvider.overrideWithValue(_NoAi()),
      geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
      coinTradeQuoteProvider.overrideWith((ref) => Future.error('offline')),
      serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
      rideServicesProvider.overrideWith((ref) async => const [RideService('Teksi', 'Metered taxi', 1, 4)]),
      recentPlacesProvider.overrideWith((ref) async => const [_eco, _klcc]),
      displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
      appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
      deviceBlockedProvider.overrideWith((ref) async => false),
      profileProvider.overrideWith((ref) async => null),
      fareTariffsProvider.overrideWith((ref) async => const []),
      meterLaunchSessionProvider.overrideWithValue(null),
      currentUserIdProvider.overrideWithValue('me'),
      myRideRepositoryProvider.overrideWithValue(repo),
      myRideSettingsStoreProvider.overrideWithValue(store),
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
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await _settle(tester, 5);
  final g = await tester.startGesture(const Offset(200, 150));
  for (var i = 0; i < 5; i++) {
    await g.moveBy(const Offset(0, 8));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await g.up();
  await _settle(tester, 10);
  await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, -300));
  await _settle(tester, 5);
  await tester.tap(find.text('KLCC').first);
  await _settle(tester, 10);
}
