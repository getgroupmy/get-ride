import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/shell/app_shell.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/features/shell/rider_side_menu.dart';
import 'package:get_ride/src/widgets/side_menu_host.dart';
import 'package:go_router/go_router.dart';

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

  test('the rider menu applies on phones outside driver mode', () {
    expect(RiderSideMenuHost.appliesAt('/wallet', 400), isTrue);
    expect(RiderSideMenuHost.appliesAt('/account/settings', 400), isTrue);
    expect(RiderSideMenuHost.appliesAt('/drive', 400), isFalse);
    expect(RiderSideMenuHost.appliesAt('/driver-guide', 400), isTrue);
    expect(RiderSideMenuHost.appliesAt('/wallet', 900), isFalse);
  });

  routerTests();

  testWidgets("the panel: profile with stars, plain rows, driver mode, social links", (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        ShellRoute(
          builder: (_, state, child) => RiderSideMenuHost(location: state.uri.path, child: child),
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
    expect(find.byKey(const ValueKey('menu-rating')), findsOneWidget);
    expect(find.text('5.0'), findsOneWidget);
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
          builder: (_, state, child) => RiderSideMenuHost(location: state.uri.path, child: child),
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

    router.go('/drive');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('side-menu-button')), findsNothing, reason: 'driver mode has its own menu');

    router.go('/wallet');
    await tester.pumpAndSettle();
    router.push('/ride/1');
    await tester.pumpAndSettle();
    expect(find.text('ride'), findsOneWidget);
    await tester.dragFrom(const Offset(5, 400), const Offset(250, 0));
    await tester.pumpAndSettle();
    expect(find.byType(RiderSideMenu), findsOneWidget, reason: 'every rider page swipes it open');
  });
}
