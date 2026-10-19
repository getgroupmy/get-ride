import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/shell/app_shell.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/features/shell/app_side_menu.dart';
import 'package:get_ride/src/widgets/side_menu_host.dart';
import 'package:get_ride/src/widgets/side_menu_tiles.dart' show SideMenuTile;
import 'package:go_router/go_router.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/app.dart' show appTheme;

import 'text_contrast.dart';

class _Page extends StatelessWidget {
  const _Page();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(leading: sideMenuLeading(context), title: const Text('Wallet')),
    body: const Center(child: Text('page')),
  );
}

Future<void> _pump(WidgetTester tester, {bool enabled = true}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: SideMenuHost(
        enabled: enabled,
        menu: const ColoredBox(key: ValueKey('menu'), color: Colors.white, child: SizedBox.expand()),
        child: const _Page(),
      ),
    ),
  );
}

void main() {
  final width = SideMenuHost.widthFor(400);

  testWidgets('the menu button replaces the back arrow and pushes the page aside', (tester) async {
    await _pump(tester);
    expect(find.byKey(const ValueKey('side-menu-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('side-menu-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('menu'))).dx, 0);
    expect(tester.getTopLeft(find.byType(_Page)).dx, width, reason: 'pushed right, not covered');

    // A tap on the dimmed page closes it.
    await tester.tapAt(const Offset(380, 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu')), findsNothing);
    expect(tester.getTopLeft(find.byType(_Page)).dx, 0);
  });

  testWidgets('the dimmed page is one labelled "Close menu" button to a screen reader', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('side-menu-button')));
    await tester.pumpAndSettle();
    final node = tester.getSemantics(find.byKey(const ValueKey('side-menu-scrim')));
    expect(node.label, 'Close menu');
    expect(node.flagsCollection.isButton, isTrue);
    // No unlabelled node under it.
    var children = 0;
    node.visitChildren((_) {
      children++;
      return true;
    });
    expect(children, 0);
    semantics.dispose();
  });

  testWidgets('a swipe in from the left edge opens it, and one back closes it', (tester) async {
    await _pump(tester);
    await tester.dragFrom(const Offset(5, 400), const Offset(250, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(_Page)).dx, width);

    await tester.dragFrom(const Offset(350, 400), const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(_Page)).dx, 0);

    // A swipe that starts mid-page is the page's own.
    await tester.dragFrom(const Offset(150, 400), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(_Page)).dx, 0);
  });

  testWidgets('a page opened from a tab keeps its back arrow', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: SideMenuHost(
          menu: const ColoredBox(key: ValueKey('menu'), color: Colors.white, child: SizedBox.expand()),
          // A tab's own navigator, inside the menu, as the app's branches are.
          child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                appBar: AppBar(leading: sideMenuLeading(context), title: const Text('Account')),
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const _Page())),
                  child: const Text('settings'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('side-menu-button')), findsOneWidget, reason: 'the tab itself has the menu');
    await tester.tap(find.text('settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('side-menu-back')), findsOneWidget);
    expect(find.byKey(const ValueKey('side-menu-button')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('side-menu-back')));
    await tester.pumpAndSettle();
    expect(find.text('settings'), findsOneWidget);
  });

  testWidgets('system back closes an open menu first', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('side-menu-button')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu')), findsNothing);
  });

  testWidgets('off (driver mode, wide screens): no menu button, no edge swipe', (tester) async {
    await _pump(tester, enabled: false);
    expect(find.byKey(const ValueKey('side-menu-button')), findsNothing);
    await tester.dragFrom(const Offset(5, 400), const Offset(250, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu')), findsNothing);
  });

  test('each mode has its menu; shared pages keep the mode that led there', () {
    const rider = SideMenuMode.rider, partner = SideMenuMode.partner;
    expect(sideMenuModeAt('/', partner), rider);
    expect(sideMenuModeAt('/trips/r1', partner), rider);
    expect(sideMenuModeAt('/ride/r1', partner), rider);
    expect(sideMenuModeAt('/drive', rider), partner);
    expect(sideMenuModeAt('/drive/vehicles', rider), partner);
    expect(sideMenuModeAt('/wallet', partner), partner, reason: 'the wallet opened from the driver menu');
    expect(sideMenuModeAt('/account/settings', rider), rider);
    expect(sideMenuModeAt('/driver-guide', rider), rider, reason: 'not under /drive');
    expect(AppSideMenuHost.appliesAt(400), isTrue);
    expect(AppSideMenuHost.appliesAt(900), isFalse, reason: 'the rail');
  });

  routerTests();
  narrowContrastTests();

  testWidgets("the panel: profile with stars, plain rows, driver mode, social links", (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        ShellRoute(
          builder: (_, state, child) => AppSideMenuHost(location: state.uri.path, child: child),
          routes: [
            GoRoute(path: '/', builder: (_, _) => const _Page()),
            GoRoute(
              path: '/drive',
              builder: (_, _) => const Scaffold(body: Text('drive')),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileProvider.overrideWith((ref) async => Profile({'id': 'u1', 'name': 'Kabeer'})),
          adminAccessProvider.overrideWith((ref) => Future.error('offline')),
          displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('side-menu-button')));
    await tester.pumpAndSettle();

    expect(find.text('Kabeer'), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-rating')), findsNothing, reason: 'no rating kept yet: no made-up stars');
    expect(find.text('New'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget, reason: 'only the profile row has a chevron');
    expect(find.byKey(const ValueKey('menu-request-history')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-social')), findsOneWidget);

    // Driver mode closes the menu and leaves for driver mode.
    await tester.tap(find.byKey(const ValueKey('menu-partner-mode')));
    await tester.pumpAndSettle();
    expect(find.text('drive'), findsOneWidget);
    expect(find.byType(RiderSideMenu), findsNothing);
  });
}

/// At 360 px, light and dark: every word in the user and driver menus
/// (an admin's, so the Admin panel button shows) reads on the panel.
void narrowContrastTests() {
  for (final b in Brightness.values) {
    testWidgets('home and drive menus read at 360 px (${b.name})', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          ShellRoute(
            builder: (_, state, child) => AppSideMenuHost(location: state.uri.path, child: child),
            routes: [
              GoRoute(path: '/', builder: (_, _) => const _Page()),
              GoRoute(path: '/drive', builder: (_, _) => const _Page()),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            profileProvider.overrideWith((ref) async => Profile({'id': 'u1', 'name': 'Kabeer', 'rider_rating': 4.8})),
            adminAccessProvider.overrideWith((ref) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
            displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
          ],
          child: MaterialApp.router(theme: appTheme(b), routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      for (final (path, menu) in [('/', RiderSideMenu), ('/drive', PartnerSideMenu)]) {
        router.go(path);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('side-menu-button')));
        await tester.pumpAndSettle();
        expect(find.byType(menu), findsOneWidget);
        expect(find.byKey(const ValueKey('menu-admin')), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(menu)), isEmpty, reason: '$menu at 360 px');
        await tester.tapAt(const Offset(350, 400));
        await tester.pumpAndSettle();
      }
    });
  }
}

/// The app's nesting: the side menu around the tab shell and the pages
/// pushed over it, with dialogs still able to cover the whole screen.
void routerTests() {
  testWidgets('the side menu wraps the tab shell and pages pushed over it', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        ShellRoute(
          builder: (_, state, child) => AppSideMenuHost(location: state.uri.path, child: child),
          routes: [
            StatefulShellRoute.indexedStack(
              builder: (_, _, shell) => AppShell(shell: shell),
              branches: [
                for (final p in ['/', '/trips', '/wallet', '/drive', '/account'])
                  StatefulShellBranch(
                    routes: [GoRoute(path: p, builder: (_, _) => const _Page())],
                  ),
              ],
            ),
            GoRoute(
              path: '/ride/:id',
              builder: (_, _) => const Scaffold(body: Text('ride')),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(ProviderScope(child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('side-menu-button')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('side-menu-button')));
    await tester.pumpAndSettle();
    expect(find.byType(RiderSideMenu), findsOneWidget);
    // Log out is set apart by a line right above it.
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('menu-logout-divider')),
      find.byType(RiderSideMenu),
      const Offset(0, -200),
    );
    final line = tester.getRect(find.byKey(const ValueKey('menu-logout-divider')));
    final logout = tester.getRect(find.ancestor(of: find.text('Logout'), matching: find.byType(SideMenuTile)).first);
    expect(logout.top, closeTo(line.bottom, 1));
    await tester.tapAt(const Offset(380, 400));
    await tester.pumpAndSettle();

    // Driver mode: the same side menu, with the driver's rows.
    router.go('/drive');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('side-menu-button')));
    await tester.pumpAndSettle();
    expect(find.byType(PartnerSideMenu), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-passenger-mode')), findsOneWidget);
    await tester.tapAt(const Offset(380, 400));
    await tester.pumpAndSettle();

    router.go('/wallet');
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(5, 400), const Offset(250, 0));
    await tester.pumpAndSettle();
    expect(find.byType(PartnerSideMenu), findsOneWidget, reason: 'the wallet was opened in driver mode');
    await tester.tapAt(const Offset(380, 400));
    await tester.pumpAndSettle();

    router.push('/ride/1');
    await tester.pumpAndSettle();
    expect(find.text('ride'), findsOneWidget);
    await tester.dragFrom(const Offset(5, 400), const Offset(250, 0));
    await tester.pumpAndSettle();
    expect(find.byType(RiderSideMenu), findsOneWidget, reason: 'every page swipes it open; a ride is user mode');
  });
}
