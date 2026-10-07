// The home screen on phones: Expo's menu button and side menu, no tab bar.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/features/ride/home_screen.dart';
import 'package:get_ride/src/features/shell/app_side_menu.dart';
import 'package:get_ride/src/widgets/side_menu_host.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

RideRequest _ride(String status) => RideRequest({
  'id': 'r1',
  'rider_id': 'me',
  'status': status,
  'pickup_name': 'Eco Majestic',
  'drop_name': 'KLCC',
  'fare': 78.3,
  'currency': 'MYR',
});

class _FakeRides implements RideRepository {
  _FakeRides([this.rides]);
  final List<RideRequest>? rides;

  @override
  Future<RideRequest?> ongoingForRider() async => _ride('open');

  @override
  Future<List<RideRequest>> ridesOnTheGo() async => rides ?? [_ride('open')];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('phones: the menu button opens the side menu, and slides off while the map is dragged', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideRepositoryProvider.overrideWithValue(_FakeRides(const [])),
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
        ],
        child: const MaterialApp(home: SideMenuHost(menu: RiderSideMenu(), child: HomeScreen())),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    final menu = find.byKey(const ValueKey('home-menu'));
    expect(menu, findsOneWidget);
    final top = tester.getRect(menu).top;

    // Dragging the map: the sheet and the buttons slide out of sight.
    final g = await tester.startGesture(const Offset(200, 300));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.getRect(menu).bottom, lessThan(top), reason: 'slid up off the top');
    expect(tester.getRect(find.byKey(const ValueKey('map-sheet-handle'))).top, greaterThan(800));
    await g.up();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.getRect(menu).top, closeTo(top, 0.5), reason: 'back once the pin has dropped');
    expect(tester.getRect(find.byKey(const ValueKey('map-sheet-handle'))).top, lessThan(800));

    await tester.tap(menu);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('rider-side-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-partner-mode')), findsOneWidget);
    // The menu pushes the page aside rather than covering it.
    expect(tester.getTopLeft(find.byType(HomeScreen)).dx, SideMenuHost.widthFor(400));
  });

  testWidgets('no menu button without the side menu (wide screens have the rail)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideRepositoryProvider.overrideWithValue(_FakeRides(const [])),
          geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
          coinTradeQuoteProvider.overrideWith((ref) => Future.error('offline')),
          serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
          rideServicesProvider.overrideWith((ref) async => const [RideService('Teksi', 'Metered taxi', 1, 4)]),
          recentPlacesProvider.overrideWith((ref) async => const []),
          displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
          appDisplayProvider.overrideWith((ref) => Future.error('offline')),
          fareTariffsProvider.overrideWith((ref) async => const []),
          meterLaunchSessionProvider.overrideWithValue(null),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('home-menu')), findsNothing);
  });
}
