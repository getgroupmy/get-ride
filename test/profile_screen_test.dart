import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/expo_routes.dart';
import 'package:get_ride/src/core/referral.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/profile/profile_screen.dart';
import 'package:get_ride/src/features/profile/referral_screen.dart';
import 'package:get_ride/src/features/settings/change_pin_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

void main() {
  test('ID numbers show only their last four', () {
    expect(maskIdNumber('900101-14-5678'), '••••••••••5678');
    expect(maskIdNumber('A1234567'), '••••4567');
    expect(maskIdNumber('123'), '123');
  });

  test('Expo /profile opens the profile page', () {
    expect(flutterRouteFor('/profile'), '/account/profile');
  });

  Future<void> pump(WidgetTester tester, Profile profile, {MyReferrer? referrer}) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/account/profile',
      routes: [
        GoRoute(path: '/account/profile', builder: (_, _) => const ProfileScreen()),
        GoRoute(path: '/account/edit', builder: (_, _) => const Text('editor')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileProvider.overrideWith((_) async => profile),
          myReferrerProvider.overrideWith((_) async => referrer),
          pinSetProvider.overrideWith((_) async => true),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows who the account is, masked ID, the referrer, and opens the editor', (tester) async {
    await pump(
      tester,
      Profile({
        'id': 'u1',
        'display_id': 'AB12CD34',
        'name': 'Aisyah Rahman',
        'phone': '+60123456789',
        'email': '',
        'nationality': 'Malaysia',
        'ic': '900101145678',
        'total_rides': 3,
      }),
      referrer: const MyReferrer(name: 'Ahmad A.'),
    );
    expect(find.byKey(const ValueKey('profile-name')), findsOneWidget);
    expect(find.text('Aisyah Rahman'), findsOneWidget);
    expect(find.text('+60 12-345 6789'), findsOneWidget);
    expect(find.text('Referred by Ahmad A.'), findsOneWidget);
    expect(find.text('3 rides'), findsOneWidget);
    expect(find.text('••••••••5678'), findsOneWidget);
    expect(find.text('900101145678'), findsNothing);
    expect(find.text('Not set'), findsWidgets);
    expect(find.text('Change sign-in PIN'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('profile-edit-button')));
    await tester.pumpAndSettle();
    expect(find.text('editor'), findsOneWidget);
  });

  testWidgets('no referrer, no badge', (tester) async {
    await pump(tester, Profile({'id': 'u1', 'name': 'Lee'}));
    expect(find.byKey(const ValueKey('profile-referred')), findsNothing);
  });
}
