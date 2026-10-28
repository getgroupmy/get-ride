// Every user (rider) side-menu item opens its page in this app, as the
// admin's menu settings arrange it: the built-in action, or the page the
// admin linked instead.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/core/side_menu.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/features/profile/account_screen.dart' show riderMenuAction;
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/side_menu_tiles.dart';
import 'package:go_router/go_router.dart';

class _Auth implements AuthRepository {
  int signOuts = 0;

  @override
  Future<void> signOut() async => signOuts++;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  const pages = [
    '/', '/ev', '/trips', '/wallet', '/account/safety', '/account/settings', '/account/guide', '/account/support', '/account/help',
    '/account/emergency', '/account/referral', '/account/my-ride', '/account/my-qr', '/account/family', '/account/notifications',
    '/trips/scheduled', '/freight', '/courier',
  ];

  /// Taps [id]'s row as [settings] arrange the menu; the page on top after,
  /// and whether "coming soon" showed.
  Future<(String, bool)> tap(WidgetTester tester, String id, {Map<String, dynamic> settings = const {}, _Auth? auth}) async {
    final entry = resolveSideMenu(settings, 'user').firstWhere((e) => e.id == id);
    final router = GoRouter(
      initialLocation: '/start',
      routes: [
        GoRoute(
          path: '/start',
          builder: (_, _) => Consumer(
            builder: (c, ref, _) => Material(
              child: SideMenuTile(entry: entry, builtIn: (c, id) => riderMenuAction(c, ref, id)),
            ),
          ),
        ),
        for (final p in pages) GoRoute(path: p, builder: (_, _) => Text('page $p')),
      ],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [authRepositoryProvider.overrideWithValue(auth ?? _Auth())],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.tap(find.byKey(ValueKey('menu-$id')));
    await tester.pumpAndSettle();
    final shown = pages.where((p) => find.text('page $p').evaluate().isNotEmpty).toList();
    return (shown.isEmpty ? '/start' : shown.last, find.text(comingSoonTitle).evaluate().isNotEmpty);
  }

  group('built-in actions (no admin settings)', () {
    const expected = {
      'teksi-ev': '/ev',
      'request-history': '/trips',
      'scheduled-rides': '/trips/scheduled',
      myRideMenuItemId: '/account/my-ride',
      myQrMenuItemId: '/account/my-qr',
      familyMenuItemId: '/account/family',
      'wallet': '/wallet',
      'notifications': '/account/notifications',
      'safety': '/account/safety',
      'settings': '/account/settings',
      'user-guide': '/account/guide',
      'support': '/account/support',
      'help-assistant': '/account/help',
      emergencyContactsMenuItemId: '/account/emergency',
      inviteFriendsMenuItemId: '/account/referral',
      'freight': '/freight',
      'courier': '/courier',
    };
    for (final MapEntry(key: id, value: page) in expected.entries) {
      testWidgets('$id opens $page', (tester) async {
        final (at, soon) = await tap(tester, id);
        expect(soon, isFalse);
        expect(at, page);
      });
    }

    testWidgets('logout asks first, then signs out', (tester) async {
      final auth = _Auth();
      await tap(tester, 'logout', auth: auth);
      expect(find.text('Sign out?'), findsOneWidget);
      expect(auth.signOuts, 0);
      await tester.tap(find.byKey(const ValueKey('sign-out-confirm')));
      await tester.pumpAndSettle();
      expect(auth.signOuts, 1);
    });

    testWidgets('cancelling logout keeps the rider signed in', (tester) async {
      final auth = _Auth();
      await tap(tester, 'logout', auth: auth);
      await tester.tap(find.byKey(const ValueKey('sign-out-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('Sign out?'), findsNothing);
      expect(auth.signOuts, 0);
    });

    // City and the services without a page yet: "coming soon", never a
    // jump to home (or, on a desktop, to Drive).
    for (final id in ['city', 'grocery', 'insurance']) {
      testWidgets('$id says coming soon', (tester) async {
        final (_, soon) = await tap(tester, id);
        expect(soon, isTrue);
      });
    }

    test('every default user item is covered', () {
      expect(
          {...expected.keys, 'city', 'logout', ...serviceMenuItemIds},
          {for (final d in defaultUserMenuItems) d.$1});
    });
  });

  group('as the live admin settings arrange it', () {
    const live = {
      'userMenu': {
        'hidden': ['teksi-ev', 'freight', 'user-guide'],
        'routes': {'city': '/', 'settings': '/settings'},
        'comingSoon': ['notifications'],
      },
    };

    test('hidden items are not listed', () {
      final ids = [for (final e in resolveSideMenu(live, 'user')) e.id];
      expect(ids, isNot(contains('teksi-ev')));
      expect(ids, isNot(contains('freight')));
      expect(ids, isNot(contains('user-guide')));
    });

    testWidgets("City linked home by the admin goes home", (tester) async {
      expect(await tap(tester, 'city', settings: live), ('/', false));
    });

    testWidgets("Settings follows the admin's link (Expo /settings) to this app's settings", (tester) async {
      expect((await tap(tester, 'settings', settings: live)).$1, '/account/settings');
    });

    testWidgets('Notifications says coming soon', (tester) async {
      final (at, soon) = await tap(tester, 'notifications', settings: live);
      expect(soon, isTrue);
      expect(at, '/start');
    });
  });
}
