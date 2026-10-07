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
  testWidgets('phones get no tab bar: the home screen menu opens the rest, and back returns home', (tester) async {
    await _pumpAt(tester, const Size(400, 800));
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(NavigationRail), findsNothing);
    final router = GoRouter.of(tester.element(find.text('page /')));
    router.go('/wallet');
    await tester.pumpAndSettle();
    expect(find.text('page /wallet'), findsOneWidget);
    // System back from a page off the home screen goes home, not out of the app.
    await tester.binding.handlePopRoute();
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
