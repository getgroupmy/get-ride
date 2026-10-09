import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/connection_check.dart';
import 'package:get_ride/src/core/expo_routes.dart';
import 'package:get_ride/src/core/route_estimate.dart';
import 'package:get_ride/src/core/side_menu.dart';
import 'package:get_ride/src/widgets/connection_status_dialog.dart';
import 'package:get_ride/src/widgets/side_menu_tiles.dart';

void main() {
  test('the new switches read with their defaults', () {
    const d = AppDisplay();
    expect([d.recenterButton, d.showAiTollBooths, d.connectedPopup, d.connectionFailedPopup], everyElement(isTrue));
    final off = AppDisplay.fromSettings({
      'recenterButton': false,
      'showAiTollBooths': 'false',
      'connectedPopupEnabled': 0,
      'connectionFailedPopupEnabled': false,
    });
    expect([
      off.recenterButton,
      off.showAiTollBooths,
      off.connectedPopup,
      off.connectionFailedPopup,
    ], everyElement(isFalse));
  });

  group('toll booths', () {
    RouteEstimate? parse(List tolls, {int? count}) => parseRouteEstimate({
      'ok': true,
      'estimate': {'distance_km': 10, 'duration_min': 12, 'toll_count': count, 'tolls': tolls},
    });

    test('booths keep a usable position and drop a zero one', () {
      final e = parse([
        {'name': 'Sungai Besi', 'charge': 1.6, 'lat': 3.06, 'lng': 101.7},
        {'name': 'Bad', 'charge': 2, 'lat': 0, 'lng': 101.7},
      ])!;
      expect(e.tolls.first.located, isTrue);
      expect(e.tolls.last.located, isFalse);
      expect(tollMarks(e, const []), [(lat: 3.06, lng: 101.7, label: 'Sungai Besi')]);
      expect(tollBoothCount(e), 2);
    });

    test('tolls with no position mark the middle of the route once', () {
      final e = parse([
        {'charge': 2},
      ])!;
      final route = [(lat: 1.0, lng: 1.0), (lat: 2.0, lng: 2.0), (lat: 3.0, lng: 3.0)];
      expect(tollMarks(e, route), [(lat: 2.0, lng: 2.0, label: 'Toll road')]);
      expect(tollMarks(parse([], count: 0), route), isEmpty);
      expect(tollBoothCount(parse([], count: 3)), 3);
      expect(tollMarks(null, route), isEmpty);
    });
  });

  group('connection popups', () {
    const ok = ConnectionCheck(reachable: true, url: 'https://x.supabase.co', hasKey: true);
    const bad = ConnectionCheck(reachable: false, url: 'https://x.supabase.co', hasKey: true, httpStatus: 503);

    test('each popup follows its own switch', () {
      expect(connectionPopupFor(ok, connectedOn: true, failedOn: false), ConnectionPopup.connected);
      expect(connectionPopupFor(ok, connectedOn: false, failedOn: true), isNull);
      expect(connectionPopupFor(bad, connectedOn: false, failedOn: true), ConnectionPopup.failed);
      expect(connectionPopupFor(bad, connectedOn: true, failedOn: false), isNull);
      expect(bad.error, 'HTTP 503');
      expect(bad.details.first, ('URL host', 'x.supabase.co'));
    });

    test('the health ping', () async {
      final up = await checkBackend(
        'https://x',
        'k',
        client: MockClient((r) async {
          expect(r.url.path, '/auth/v1/health');
          expect(r.headers['apikey'], 'k');
          return http.Response('{}', 200);
        }),
      );
      expect(up.reachable, isTrue);
      final down = await checkBackend('https://x', 'k', client: MockClient((_) async => http.Response('', 500)));
      expect(down.reachable, isFalse);
      expect(down.httpStatus, 500);
      final none = await checkBackend('', '');
      expect(none.reachable, isFalse);
    });

    testWidgets('the failed popup shows the error and its details', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () => showConnectionStatus(c, ConnectionPopup.failed, bad),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Not Connected to server'), findsOneWidget);
      expect(find.text('HTTP 503'), findsOneWidget);
      await tester.tap(find.text('Show details'));
      await tester.pumpAndSettle();
      expect(find.text('x.supabase.co'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('connection-failed')), findsNothing);
    });
  });

  test('Expo links map onto this app', () {
    expect(flutterRouteFor('/teksi-ev'), '/ev');
    expect(flutterRouteFor('/safety'), '/account/safety');
    expect(flutterRouteFor('/wallet?mode=partner'), '/wallet');
    expect(flutterRouteFor('/admin-settings-display'), '/admin');
    expect(flutterRouteFor('/account/guide'), '/account/guide');
    expect(flutterRouteFor('/auth-diagnostics'), isNull);
    expect(flutterRouteFor('https://x'), isNull);
    expect(flutterRouteFor('//x'), isNull);
  });

  group('side menus', () {
    test('hidden, renamed, relinked, coming soon, custom and ordered', () {
      final menu = resolveSideMenu({
        'userMenu': {
          'renames': {'wallet': 'My wallet'},
          'routes': {'support': '/user-guide'},
          'hidden': ['city', 'freight'],
          'comingSoon': ['notifications'],
          'order': ['custom-1', 'wallet'],
          'customItems': [
            {'id': 'custom-1', 'label': 'Promos', 'iconName': 'Gift', 'route': '/referral-card'},
          ],
        },
      }, 'user');
      expect(menu.take(2).map((e) => e.id), ['custom-1', 'wallet']);
      expect(menu.first.route, '/account/referral');
      expect(menu[1].label, 'My wallet');
      expect(menu.map((e) => e.id), isNot(contains('city')));
      expect(menu.firstWhere((e) => e.id == 'notifications').comingSoon, isTrue);
      final support = menu.firstWhere((e) => e.id == 'support');
      expect((support.route, support.overridden), ('/account/guide', true));
      expect(menu.last.id, 'logout');
    });

    test('the mode button can be renamed or hidden', () {
      expect(sideMenuModeButton(const {}, 'user')!.label, 'Partner Mode');
      expect(
        sideMenuModeButton({
          'partnerMenu': {
            'renames': {'passenger-mode-button': 'Ride as passenger'},
          },
        }, 'partner')!.label,
        'Ride as passenger',
      );
      expect(
        sideMenuModeButton({
          'userMenu': {
            'hidden': ['partner-mode-button'],
          },
        }, 'user'),
        isNull,
      );
    });

    Future<GoRouter> pumpTile(WidgetTester tester, MenuEntry e, {bool builtIn = true}) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: SideMenuTile(entry: e, builtIn: (_, _) => builtIn),
            ),
          ),
          GoRoute(path: '/ev', builder: (_, _) => const Text('EV screen')),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      return router;
    }

    testWidgets('a linked item opens its screen', (tester) async {
      await pumpTile(tester, const MenuEntry(id: 'c', label: 'EV', custom: true, route: '/ev'));
      await tester.tap(find.text('EV'));
      await tester.pumpAndSettle();
      expect(find.text('EV screen'), findsOneWidget);
    });

    testWidgets('coming soon, and a custom item without a link, say so', (tester) async {
      await pumpTile(tester, const MenuEntry(id: 'n', label: 'News', custom: false, comingSoon: true));
      await tester.tap(find.text('News'));
      await tester.pumpAndSettle();
      expect(find.text(comingSoonBody), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await pumpTile(tester, const MenuEntry(id: 'x', label: 'Mine', custom: true));
      await tester.tap(find.text('Mine'));
      await tester.pumpAndSettle();
      expect(find.text(comingSoonTitle), findsOneWidget);
    });
  });

  test('Emergency contacts and Invite friends are admin menu items: listed, hidden, renamed', () {
    final ids = [for (final e in resolveSideMenu(const {}, 'user')) e.id];
    expect(ids, containsAllInOrder(['support', 'emergency-contacts', 'invite-friends', 'logout']));
    final hidden = resolveSideMenu({
      'userMenu': {
        'hidden': ['invite-friends'],
        'renames': {'emergency-contacts': 'SOS contacts'},
      },
    }, 'user');
    expect(hidden.any((e) => e.id == 'invite-friends'), isFalse);
    expect(hidden.firstWhere((e) => e.id == 'emergency-contacts').label, 'SOS contacts');
  });

  test("each menu's Profile header follows its Show and Coming Soon switches", () {
    expect(sideMenuProfile(const {}, 'partner'), (show: true, comingSoon: false));
    final s = {
      'partnerMenu': {'hidden': ['profile']},
      'userMenu': {'comingSoon': ['profile']},
    };
    expect(sideMenuProfile(s, 'partner').show, isFalse);
    expect(sideMenuProfile(s, 'user'), (show: true, comingSoon: true));
  });

  test('the traffic warning shows only when the AI fare service is on but gave nothing', () {
    for (final reason in ['no_keys', 'keys_cooling_down', 'all_keys_failed']) {
      expect(aiEstimateUnavailable({'ok': true, 'estimate': null, 'reason': reason}), isTrue, reason: reason);
    }
    expect(aiEstimateUnavailable({'ok': true, 'estimate': null, 'reason': 'service_disabled'}), isFalse);
    expect(aiEstimateUnavailable({'ok': true, 'estimate': {'distance_km': 5, 'duration_min': 9}}), isFalse);
    expect(aiEstimateUnavailable({'ok': false, 'error': 'bad'}), isFalse);
    expect(aiEstimateUnavailable(null), isFalse);
  });
}
