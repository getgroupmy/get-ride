// Demo riders and demo drivers (Admin → Display Settings → Demo / Mockup
// Data): the switches say the demo is on, the lists say for whom. A listed
// rider's Find driver books a request on the phone alone, which the demo
// drivers answer; nobody else ever sees demo content, and nothing demo
// reaches the server.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/screens/meterapp/demo_accounts.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_store.dart';
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/demo_mode.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/route_estimate_repository.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/features/ride/demo_ride.dart';
import 'package:get_ride/src/features/ride/home_screen.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'quiet_live.dart';
import 'notice.dart';

const _eco = Place(name: 'Eco Majestic', address: 'Semenyih', point: LatLng(2.9300, 101.8300));
const _klcc = Place(name: 'KLCC', address: 'Kuala Lumpur', point: LatLng(2.9400, 101.8400));

/// Every call that would reach the server with a ride: a demo id must never
/// be among them.
class _Rides implements RideRepository {
  final calls = <String>[];
  Map<Symbol, dynamic>? created;

  @override
  Future<List<RideRequest>> ridesOnTheGo() async => const [];

  @override
  Future<bool> biddingEnabledFor(LatLng pickup, Future<AreaInfo?> Function() area) async => true;

  @override
  Future<RegionPricing> pricingFor(LatLng pickup, Future<AreaInfo?> Function() area) async => RegionPricing.none;

  @override
  Future<String?> publicIp() async => null;

  @override
  dynamic noSuchMethod(Invocation i) {
    final name = i.memberName.toString().replaceAll('Symbol("', '').replaceAll('")', '');
    calls.add(name);
    if (i.memberName == #createRequest) {
      created = i.namedArguments;
      final ride = RideRequest({'id': 'r9', 'rider_id': 'me', 'status': 'open', 'fare': 10});
      return Future<Booked>.value((now: ride, later: null));
    }
    return super.noSuchMethod(i);
  }
}

class _NoAi implements RouteEstimateRepository {
  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Map<String, dynamic> _display({bool offers = true, List<String> riders = const []}) => {
      'userMockEnabled': offers,
      demoRiderIdsKey: riders,
    };

/// The home screen at its confirm step, signed in as `me`, then Find a driver.
Future<(ProviderContainer, _Rides)> _book(WidgetTester tester, Map<String, dynamic> display, Brightness b) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final rides = _Rides();
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
      displaySettingsBlobProvider.overrideWith((ref) async => display),
      appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
      deviceBlockedProvider.overrideWith((ref) async => false),
      profileProvider.overrideWith((ref) async => null),
      fareTariffsProvider.overrideWith((ref) async => const []),
      meterLaunchSessionProvider.overrideWithValue(null),
      currentUserIdProvider.overrideWithValue('me'),
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
      child: MaterialApp.router(theme: appTheme(b), routerConfig: router),
    ),
  );
  await _settle(tester, 5);
  final g = await tester.startGesture(const Offset(200, 150));
  for (var i = 0; i < 5; i++) {
    await g.moveBy(const Offset(0, 8));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await g.up();
  await _settle(tester);
  await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, -300));
  await _settle(tester, 5);
  await tester.tap(find.text('KLCC').first);
  await _settle(tester);
  await tester.tap(find.byKey(const ValueKey('book')));
  await _settle(tester);
  return (container, rides);
}

// ---- The searching screen on a demo request ---------------------------------------

final _t0 = DateTime.utc(2026, 10, 19, 9);

Future<(ProviderContainer, _Rides, String)> _search(WidgetTester tester, Brightness b, {bool listed = true}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  var now = _t0;
  final rides = _Rides();
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      rideRepositoryProvider.overrideWithValue(rides),
      searchClockProvider.overrideWithValue(() => now),
      riderPositionStreamProvider.overrideWithValue(() => const Stream<LatLng>.empty()),
      fareCoinChoiceStoreProvider.overrideWithValue(FareCoinChoiceStore()),
      walletBalancesProvider.overrideWith((ref) async => const []),
      walletTxProvider.overrideWith((ref) async => const []),
      displaySettingsBlobProvider.overrideWith((ref) async => _display(riders: listed ? const ['me'] : const [])),
      geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
      currentUserIdProvider.overrideWithValue('me'),
    ],
  );
  addTearDown(container.dispose);
  await container.read(displaySettingsBlobProvider.future);
  final ride = container.read(demoRidesProvider.notifier).create({
    'rider_id': 'me',
    'fare': 20.0,
    'currency': 'MYR',
    'offer_me': true,
    'pickup_name': 'KLCC',
    'pickup_lat': 3.1579,
    'pickup_lng': 101.7116,
    'drop_name': 'KL Sentral',
    'drop_lat': 3.1345,
    'drop_lng': 101.6869,
  }, now: _t0);
  final router = GoRouter(
    initialLocation: '/ride/${ride.id}',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('home'))),
      GoRoute(path: '/ride/demo', builder: (_, s) => Text('demo trip with ${(s.extra! as DemoTripArgs).offer.name}')),
      GoRoute(path: '/ride/:id', builder: (_, s) => RideTrackingScreen(requestId: s.pathParameters['id']!)),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: appTheme(b), routerConfig: router),
    ),
  );
  for (var i = 0; i < 8; i++) {
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }
  await tester.pump(const Duration(milliseconds: 400));
  return (container, rides, ride.id);
}

// ---- The admin's lists ---------------------------------------------------------------

class _Admin implements AdminRepository {
  final people = {
    'u1': {'id': 'u1', 'name': 'Aminah', 'phone': '60111', 'email': null, 'display_id': 'A1'},
    'u2': {'id': 'u2', 'name': 'Badrul', 'phone': '60122', 'email': null, 'display_id': 'B2'},
  };

  @override
  Future<List<Map<String, dynamic>>> searchPeople(String query, {int limit = 20}) async => [
        for (final p in people.values)
          if ('${p['name']}'.toLowerCase().contains(query.toLowerCase())) p,
      ];

  @override
  Future<Map<String, Map<String, dynamic>>> peopleByIds(List<String> ids) async => {
        for (final id in ids)
          if (people[id] != null) id: people[id]!,
      };

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Display extends DisplaySettingsController {
  _Display(this.initial);
  final Map<String, dynamic> initial;

  @override
  Future<Map<String, dynamic>> build() async => initial;

  @override
  Future<void> apply(DisplayEdit edit) async => state = AsyncData(edit(state.value!));
}

void main() {
  group('who gets the demo', () {
    test('a switch on reaches only the accounts listed; an empty list reaches nobody', () {
      final on = DemoSettings.fromSettings({
        'userMockEnabled': true,
        'partnerMockEnabled': true,
        demoRiderIdsKey: ['u1', ' u2 ', '', 7, 'u1'],
        demoDriverIdsKey: ['d1'],
      });
      expect(on.riders, {'u1', 'u2'});
      expect(on.offersFor('u1'), isTrue);
      expect(on.offersFor('u3'), isFalse);
      expect(on.offersFor(null), isFalse);
      expect(on.requestsFor('d1'), isTrue);
      expect(on.requestsFor('u1'), isFalse);

      final empty = DemoSettings.fromSettings(const {'userMockEnabled': true, 'partnerMockEnabled': true});
      expect(empty.offersFor('u1'), isFalse);
      expect(empty.requestsFor('d1'), isFalse);

      final off = DemoSettings.fromSettings({
        demoRiderIdsKey: ['u1'],
        demoDriverIdsKey: ['d1'],
      });
      expect(off.offersFor('u1'), isFalse, reason: 'listed, but the switch is off');
      expect(off.requestsFor('d1'), isFalse);
    });

    test('accounts are added once and removed', () {
      var s = <String, dynamic>{'userMockEnabled': true};
      s = addDemoAccount(s, demoRiderIdsKey, 'u1');
      s = addDemoAccount(s, demoRiderIdsKey, 'u1');
      s = addDemoAccount(s, demoRiderIdsKey, 'u2');
      expect(s[demoRiderIdsKey], ['u1', 'u2']);
      s = removeDemoAccount(s, demoRiderIdsKey, 'u1');
      expect(s[demoRiderIdsKey], ['u2']);
      expect(s['userMockEnabled'], isTrue);
    });

    test('a fixed-fare demo request is offered at its fare', () {
      expect(demoOffers(20, bidding: false).map((o) => o.$2.price), [20, 20, 20]);
    });

    test('demo incoming requests reach only the listed drivers', () {
      bool driver(String uid, DemoSettings s) {
        final c = ProviderContainer(overrides: [
          demoSettingsProvider.overrideWithValue(s),
          currentUserIdProvider.overrideWithValue(uid),
        ]);
        addTearDown(c.dispose);
        return c.read(demoDriverProvider);
      }

      const on = DemoSettings(partnerRequests: true, drivers: {'d1'});
      expect(driver('d1', on), isTrue);
      expect(driver('d2', on), isFalse);
      expect(driver('d1', const DemoSettings(partnerRequests: true)), isFalse, reason: 'nobody listed');
      expect(driver('d1', const DemoSettings(drivers: {'d1'})), isFalse, reason: 'switch off');
    });

    test('demo ids are told apart', () {
      expect(isDemoRideId('demo-1'), isTrue);
      expect(isDemoRideId('demo-job-3'), isTrue);
      expect(isDemoRideId('8f14e45f-ceea-467f-a8f0-1a2b3c4d5e6f'), isFalse);
    });
  });

  for (final b in Brightness.values) {
    group('rider (${b.name})', () {
      testWidgets('a listed rider books a demo request on the phone: nothing is inserted', (tester) async {
        final (container, rides) = await _book(tester, _display(riders: const ['me']), b);
        expect(rides.created, isNull);
        expect(rides.calls, isNot(contains('createRequest')));
        final demo = container.read(demoRidesProvider);
        expect(demo.keys, ['demo-1']);
        final r = demo['demo-1']!;
        expect(r.status, RideStatus.open);
        expect(r.offerMe, isTrue);
        expect(r.pickupLabel, isNotEmpty);
        expect(r.dropLabel, 'KLCC');
        expect(r.fare, greaterThan(0));
        expect(find.text('ride demo-1'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('an unlisted rider books a real request', (tester) async {
        final (container, rides) = await _book(tester, _display(riders: const ['someone-else']), b);
        expect(rides.created, isNotNull);
        expect(container.read(demoRidesProvider), isEmpty);
        expect(find.text('ride r9'), findsOneWidget);
      });

      testWidgets('with nobody listed, nobody gets the demo', (tester) async {
        final (container, rides) = await _book(tester, _display(), b);
        expect(rides.created, isNotNull);
        expect(container.read(demoRidesProvider), isEmpty);
      });

      testWidgets('listed but the switch off: a real request', (tester) async {
        final (container, rides) = await _book(tester, _display(offers: false, riders: const ['me']), b);
        expect(rides.created, isNotNull);
        expect(container.read(demoRidesProvider), isEmpty);
      });

      testWidgets('the demo request gets the demo offers, marked DEMO, and one leads into the demo trip',
          (tester) async {
        final (_, rides, id) = await _search(tester, b);
        expect(id, 'demo-1');
        expect(find.byKey(const ValueKey('demo-viewers')), findsOneWidget);
        expect(find.byKey(const ValueKey('demo-offer-demo-1')), findsOneWidget);
        expect(find.byKey(const ValueKey('demo-offer-demo-2')), findsOneWidget);
        expect(find.text('DEMO'), findsWidgets);
        expect(find.byKey(const ValueKey('share-ride')), findsNothing, reason: 'nothing to share with the server');
        await tester.tap(find.byKey(const ValueKey('demo-accept-demo-2')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('demo trip with Mellier'), findsOneWidget);
        expect(rides.calls, isEmpty, reason: 'nothing about a demo request reaches the server');
        expect(tester.takeException(), isNull);
      });

      testWidgets('raising and cancelling a demo request stay on the phone', (tester) async {
        final (container, rides, id) = await _search(tester, b);
        await tester.tap(find.byKey(const ValueKey('search-fare-raise')).first);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('search-fare-confirm')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(container.read(demoRidesProvider)[id]!.fare, greaterThan(20));
        await closeNotice(tester);
        await tester.tap(find.byKey(const ValueKey('cancel-request')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const ValueKey('cancel-reason-high_fares')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const ValueKey('cancel-confirm')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final cancelled = container.read(demoRidesProvider)[id]!;
        expect(cancelled.status, RideStatus.cancelled);
        expect(cancelled.cancelReason, 'high_fares');
        expect(find.text('home'), findsOneWidget);
        expect(rides.calls, isEmpty);
      });

      testWidgets('a demo request whose rider is taken off the list gets no demo offers', (tester) async {
        final (_, rides, _) = await _search(tester, b, listed: false);
        expect(find.byKey(const ValueKey('demo-offer-demo-1')), findsNothing);
        expect(find.text('DEMO'), findsNothing);
        expect(rides.calls, isEmpty);
      });
    });

    testWidgets('admin: demo riders are added from a search and removed (${b.name})', (tester) async {
      tester.view.physicalSize = const Size(500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...quietLiveOverrides,
            adminRepositoryProvider.overrideWithValue(_Admin()),
            adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: true)])),
            displaySettingsProvider.overrideWith(() => _Display(const {'userMockEnabled': true})),
          ],
          child: MaterialApp(
            theme: appTheme(b),
            home: Scaffold(
              body: Consumer(
                builder: (_, ref, _) {
                  final s = ref.watch(displaySettingsProvider).value ?? const <String, dynamic>{};
                  return ListView(children: [
                    DemoAccountsSection(
                      settings: s,
                      listKey: demoRiderIdsKey,
                      title: 'Demo riders',
                      help: 'help',
                      canEdit: true,
                    ),
                  ]);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('demo-empty-$demoRiderIdsKey')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('demo-add-$demoRiderIdsKey')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('demo-account-search')), 'ami');
      await tester.tap(find.byKey(const ValueKey('demo-account-find')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('demo-pick-u1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('demo-account-$demoRiderIdsKey-u1')), findsOneWidget);
      expect(find.text('Aminah'), findsOneWidget);
      expect(find.text('Demo riders (1)'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('demo-remove-$demoRiderIdsKey-u1')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('demo-account-$demoRiderIdsKey-u1')), findsNothing);
      expect(find.byKey(ValueKey('demo-empty-$demoRiderIdsKey')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
