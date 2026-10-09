// Every built-in driver menu item opens its page in this app, or answers
// false ("coming soon") when there is none.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/features/partner/partner_menu.dart';
import 'package:go_router/go_router.dart';

void main() {
  const pages = [
    '/ev', '/drive', '/wallet', '/trips', '/drive/vehicles', '/meter/vehicle', '/drive/onboarding',
    '/account/support', '/account/help', '/account/settings',
  ];

  Future<(String, bool?)> tap(WidgetTester tester, String id) async {
    bool? handled;
    final router = GoRouter(
      initialLocation: '/start',
      routes: [
        GoRoute(
          path: '/start',
          builder: (_, _) => Consumer(
            builder: (c, ref, _) => TextButton(
              onPressed: () => handled = partnerMenuAction(c, ref, id, close: () {}),
              child: const Text('tap'),
            ),
          ),
        ),
        for (final p in pages) GoRoute(path: p, builder: (_, _) => Text('page $p')),
      ],
    );
    await tester.pumpWidget(ProviderScope(child: MaterialApp.router(routerConfig: router)));
    await tester.tap(find.text('tap'));
    await tester.pumpAndSettle();
    // The page on top, pushed or gone to.
    final shown = pages.where((p) => find.text('page $p').evaluate().isNotEmpty).toList();
    return (shown.isEmpty ? '/start' : shown.last, handled);
  }

  const expected = {
    'teksi-ev': '/ev',
    'dashboard': '/drive',
    'wallet': '/wallet',
    'trip-history': '/trips',
    'vehicle': '/drive/vehicles',
    vehicleInfoMenuItemId: '/meter/vehicle',
    'documents': '/drive/onboarding',
    'support': '/account/support',
    'help-assistant': '/account/help',
    'settings': '/account/settings',
  };

  for (final MapEntry(key: id, value: page) in expected.entries) {
    testWidgets('$id opens $page', (tester) async {
      final (at, handled) = await tap(tester, id);
      expect(handled, isTrue);
      expect(at, page);
    });
  }

  for (final id in ['earnings', 'notifications']) {
    testWidgets('$id has no page here: "coming soon"', (tester) async {
      final (at, handled) = await tap(tester, id);
      expect(handled, isFalse);
      expect(at, '/start');
    });
  }

  testWidgets('sign-out asks first', (tester) async {
    final (_, handled) = await tap(tester, 'sign-out');
    expect(handled, isTrue);
    expect(find.text('Sign out?'), findsOneWidget);
  });

  test('every default driver item is covered', () {
    expect(
      {...expected.keys, 'earnings', 'notifications', 'sign-out'},
      {for (final d in defaultPartnerMenuItems) d.$1},
    );
  });
}
