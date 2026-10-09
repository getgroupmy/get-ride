import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/features/auth/phone_screen.dart';
import 'package:get_ride/src/features/auth/registration_closed_screen.dart';
import 'package:get_ride/src/providers.dart';

class _Auth implements AuthRepository {
  _Auth({required this.hasProfile});
  final bool hasProfile;
  final otps = <String>[];
  final created = <bool>[];

  @override
  Future<PhoneLookup> lookupPhone(String phone) async =>
      PhoneLookup(hasProfile: hasProfile, hasPin: false, isDeleted: false);

  @override
  Future<void> sendOtp(String phone, {required bool createUser}) async {
    otps.add(phone);
    created.add(createUser);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('AppDisplay.fromSettings', () {
    test('defaults keep the service on', () {
      for (final raw in [null, 'x', <String, dynamic>{}]) {
        final d = AppDisplay.fromSettings(raw);
        expect(d.serviceEnabled, isTrue);
        expect(d.registrationEnabled, isTrue);
        expect(d.showAiTollCharges, isTrue);
        expect(d.showSignInLogo, isTrue);
      }
    });

    test('reads the admin switches, tolerating stored spellings', () {
      final d = AppDisplay.fromSettings({
        'serviceEnabled': false,
        'registrationEnabled': 'false',
        'showAiTollCharges': 0,
        'rcBackVertical': 12,
        'signInLogo': false,
      });
      expect(d.showSignInLogo, isFalse);
      expect(d.serviceEnabled, isFalse);
      expect(d.registrationEnabled, isFalse);
      expect(d.showAiTollCharges, isFalse);
      expect(AppDisplay.fromSettings({'serviceEnabled': 'nonsense'}).serviceEnabled, isTrue);
    });

    test('closed registration only stops numbers with no account', () {
      const closed = AppDisplay(registrationEnabled: false);
      expect(mayContinueSignIn(hasAccount: true, display: closed), isTrue);
      expect(mayContinueSignIn(hasAccount: false, display: closed), isFalse);
      expect(mayContinueSignIn(hasAccount: false, display: const AppDisplay()), isTrue);
    });
  });

  Future<_Auth> pumpPhone(
    WidgetTester tester, {
    required bool hasProfile,
    required bool open,
    bool logo = true,
    bool submit = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1400);
    addTearDown(tester.view.reset);
    final auth = _Auth(hasProfile: hasProfile);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceBlockedProvider.overrideWith((ref) async => false),
          authRepositoryProvider.overrideWithValue(auth),
          appDisplayProvider.overrideWith((ref) async => AppDisplay(registrationEnabled: open, showSignInLogo: logo)),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            initialLocation: '/login',
            routes: [
              GoRoute(
                path: '/login',
                builder: (_, _) => const PhoneScreen(),
                routes: [
                  GoRoute(
                    path: 'closed',
                    builder: (_, s) => RegistrationClosedScreen(phone: s.uri.queryParameters['phone'] ?? ''),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (!submit) return auth;
    await tester.enterText(find.byType(TextField), '123456789');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    return auth;
  }

  testWidgets('a new number gets the registration-closed page, and back returns', (tester) async {
    final auth = await pumpPhone(tester, hasProfile: false, open: false);
    expect(auth.otps, isEmpty);
    expect(find.byKey(const ValueKey('registration-closed')), findsOneWidget);
    expect(find.text(registrationClosedMessage), findsOneWidget);
    expect(find.text('+60123456789'), findsOneWidget);
    await tester.tap(find.text('Use a different number'));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneScreen), findsOneWidget);
  });

  testWidgets('the logo follows its switch', (tester) async {
    await pumpPhone(tester, hasProfile: true, open: true, submit: false);
    expect(find.byKey(const ValueKey('sign-in-logo')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await pumpPhone(tester, hasProfile: true, open: true, logo: false, submit: false);
    expect(find.byKey(const ValueKey('sign-in-logo')), findsNothing);
  });

  testWidgets('an existing account still gets its code while registration is closed', (tester) async {
    final auth = await pumpPhone(tester, hasProfile: true, open: false);
    expect(auth.otps, hasLength(1));
    // Signing in never creates an account.
    expect(auth.created, [false]);
  });
}
