import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/features/partner/driver_online.dart';
import 'package:get_ride/src/features/shell/app_shell.dart';
import 'package:get_ride/src/widgets/common.dart';
import 'package:go_router/go_router.dart';

GoRouter _router() => GoRouter(routes: [
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(shell: shell),
        branches: [
          for (final p in ['/', '/trips', '/wallet', '/drive', '/account'])
            StatefulShellBranch(routes: [GoRoute(path: p, builder: (_, _) => Text('page $p'))]),
        ],
      ),
    ]);

Future<ProviderContainer> _pumpAt(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: MaterialApp.router(routerConfig: _router())),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('phones get a bottom navigation bar', (tester) async {
    await _pumpAt(tester, const Size(400, 800));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    await tester.tap(find.text('Wallet'));
    await tester.pumpAndSettle();
    expect(find.text('page /wallet'), findsOneWidget);
  });

  testWidgets('a driver online cannot open Ride until they go offline', (tester) async {
    final container = await _pumpAt(tester, const Size(400, 800));
    await tester.tap(find.text('Drive'));
    await tester.pumpAndSettle();
    container.read(driverOnlineProvider.notifier).set(true);
    await tester.pump();
    expect(
      tester.widget<NavigationDestination>(find.byKey(const ValueKey('nav-ride'))).enabled,
      isFalse,
      reason: 'greyed out',
    );
    await tester.tap(find.text('Ride'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('page /drive'), findsOneWidget);

    container.read(driverOnlineProvider.notifier).set(false);
    await tester.pump();
    await tester.tap(find.text('Ride'));
    await tester.pumpAndSettle();
    expect(find.text('page /'), findsOneWidget);
  });

  testWidgets('desktop: the rail greys out Ride too', (tester) async {
    final container = await _pumpAt(tester, const Size(1280, 800));
    container.read(driverOnlineProvider.notifier).set(true);
    await tester.pump();
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.destinations.first.disabled, isTrue);
    expect(rail.destinations.skip(1).every((d) => !d.disabled), isTrue);
  });

  testWidgets('desktop and web get a navigation rail', (tester) async {
    await _pumpAt(tester, const Size(1280, 800));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('EmptyState renders title and message', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: EmptyState(icon: Icons.info, title: 'Hello', message: 'World')),
    ));
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('World'), findsOneWidget);
  });
}
