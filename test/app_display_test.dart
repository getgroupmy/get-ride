import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/auth_utils.dart' show SignInPhone, signInStepPhone;
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/features/auth/passkey_sign_in_button.dart';
import 'package:get_ride/src/features/auth/phone_screen.dart';
import 'package:get_ride/src/features/auth/welcome_screen.dart';
import 'package:get_ride/src/features/auth/registration_closed_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

class _Auth implements AuthRepository {
  _Auth({required this.hasProfile, this.otpRefused = false});
  final bool hasProfile;

  /// The server's sign-up hook refuses the code (0287).
  final bool otpRefused;
  final otps = <String>[];
  final created = <bool>[];

  @override
  Future<PhoneLookup> lookupPhone(String phone) async =>
      PhoneLookup(hasProfile: hasProfile, hasPin: false, isDeleted: false);

  @override
  Future<void> sendOtp(String phone, {required bool createUser}) async {
    if (otpRefused) {
      throw const AuthException('REGISTRATION_CLOSED: There is no account for this number, and new sign-ups are closed.');
    }
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

    test('per-role switches: missing ones are on, the old switch off closes both', () {
      final open = AppDisplay.fromSettings(const {});
      expect([open.passengerSignUpOpen, open.driverSignUpOpen, open.anySignUpOpen], [true, true, true]);
      final noPassenger = AppDisplay.fromSettings(const {'passengerRegistrationEnabled': false});
      expect([noPassenger.passengerSignUpOpen, noPassenger.driverSignUpOpen, noPassenger.anySignUpOpen],
          [false, true, true]);
      final noDriver = AppDisplay.fromSettings(const {'driverRegistrationEnabled': 'off'});
      expect([noDriver.passengerSignUpOpen, noDriver.driverSignUpOpen], [true, false]);
      final both = AppDisplay.fromSettings(const {'passengerRegistrationEnabled': false, 'driverRegistrationEnabled': false});
      expect(both.anySignUpOpen, isFalse);
      final legacy = AppDisplay.fromSettings(const {
        'registrationEnabled': false,
        'passengerRegistrationEnabled': true,
        'driverRegistrationEnabled': true,
      });
      expect([legacy.passengerSignUpOpen, legacy.driverSignUpOpen], [false, false]);
      expect(mayContinueSignIn(hasAccount: false, display: noPassenger), isTrue);
      expect(mayContinueSignIn(hasAccount: false, display: both), isFalse);
      expect(isRegistrationClosed('REGISTRATION_CLOSED:driver'), isTrue);
      expect(isRegistrationClosed('DEVICE_LIMIT:2/2'), isFalse);
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
    AppDisplay? display,
    bool otpRefused = false,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1400);
    addTearDown(tester.view.reset);
    final auth = _Auth(hasProfile: hasProfile, otpRefused: otpRefused);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceBlockedProvider.overrideWith((ref) async => false),
          authRepositoryProvider.overrideWithValue(auth),
          appDisplayProvider.overrideWith(
            (ref) async => display ?? AppDisplay(registrationEnabled: open, showSignInLogo: logo),
          ),
        ],
        child: MaterialApp.router(
          theme: ThemeData(brightness: brightness),
          routerConfig: GoRouter(
            initialLocation: '/login',
            routes: [
              GoRoute(
                path: '/login',
                builder: (_, _) => const PhoneScreen(),
                routes: [
                  GoRoute(
                    path: 'closed',
                    builder: (_, s) => RegistrationClosedScreen(phone: signInStepPhone(s.uri.queryParameters)),
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
    await tester.tap(find.widgetWithText(FilledButton, 'Next'));
    await tester.pumpAndSettle();
    return auth;
  }

  for (final b in Brightness.values) {
    testWidgets('both sign-ups closed: a new number gets the No account modal, no code (${b.name})', (tester) async {
      final auth = await pumpPhone(
        tester,
        hasProfile: false,
        open: true,
        brightness: b,
        display: const AppDisplay(passengerRegistrationEnabled: false, driverRegistrationEnabled: false),
      );
      expect(auth.otps, isEmpty);
      expect(find.byKey(const ValueKey('no-account')), findsOneWidget);
      expect(find.text(noAccountTitle), findsOneWidget);
      expect(find.text(noAccountMessage), findsOneWidget);
      expect(find.text('+60123456789'), findsOneWidget);
      expect(find.byKey(const ValueKey('registration-closed')), findsNothing, reason: 'no page of its own any more');
      expect(find.byKey(const ValueKey('signup-send-code')), findsNothing, reason: 'not offered sign-up');
      await tester.tap(find.text('Try another number'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('no-account')), findsNothing);
      expect(find.byType(PhoneScreen), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the old single switch off does the same', (tester) async {
    final auth = await pumpPhone(tester, hasProfile: false, open: false);
    expect(auth.otps, isEmpty);
    expect(find.byKey(const ValueKey('no-account')), findsOneWidget);
  });

  testWidgets('one role closed: a new number is still offered sign-up and gets its code', (tester) async {
    for (final d in const [
      AppDisplay(passengerRegistrationEnabled: false),
      AppDisplay(driverRegistrationEnabled: false),
    ]) {
      final auth = await pumpPhone(tester, hasProfile: false, open: true, display: d, submit: false);
      await _next(tester);
      expect(find.byKey(const ValueKey('no-account')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('signup-send-code')));
      await _frames(tester);
      expect(auth.otps, ['+60123456789']);
      expect(auth.created, [true]);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('closed since the page read the settings: the server refuses the code, the modal says so',
      (tester) async {
    final auth = await pumpPhone(tester, hasProfile: false, open: true, otpRefused: true, submit: false);
    await _next(tester);
    await tester.tap(find.byKey(const ValueKey('signup-send-code')));
    await _frames(tester);
    expect(auth.otps, isEmpty);
    expect(find.byKey(const ValueKey('no-account')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final b in Brightness.values) {
    testWidgets('/login/closed reloaded (no number in memory) still explains itself (${b.name})', (tester) async {
      SignInPhone.value = null; // a reload empties memory
      await tester.pumpWidget(
        MaterialApp.router(
          theme: ThemeData(brightness: b),
          routerConfig: GoRouter(
            initialLocation: '/login/closed',
            routes: [
              GoRoute(
                path: '/login',
                builder: (_, _) => const Text('welcome'),
                routes: [
                  GoRoute(path: 'phone', builder: (_, _) => const Text('number page')),
                  GoRoute(
                    path: 'closed',
                    builder: (_, s) => RegistrationClosedScreen(phone: signInStepPhone(s.uri.queryParameters)),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(registrationClosedTitle), findsOneWidget);
      expect(find.text(registrationClosedNoNumberMessage), findsOneWidget);
      expect(find.text(registrationClosedMessage), findsNothing, reason: 'no "this number" with no number');
      await tester.tap(find.text('Sign in with your number'));
      await tester.pumpAndSettle();
      expect(find.text('number page'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets("the sign-in country-code button is named by its country, not its flag", (tester) async {
    final handle = tester.ensureSemantics();
    await pumpPhone(tester, hasProfile: true, open: true, submit: false);
    expect(find.bySemanticsLabel('Country code +60, Malaysia'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the logo on the welcome page follows its switch', (tester) async {
    for (final logo in [true, false]) {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDisplayProvider.overrideWith((ref) async => AppDisplay(showSignInLogo: logo)),
            passkeyOfferedHereProvider.overrideWith((ref) async => false),
          ],
          child: const MaterialApp(home: WelcomeScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sign-in-logo')), logo ? findsOneWidget : findsNothing);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('an existing account still gets its code while registration is closed', (tester) async {
    final auth = await pumpPhone(tester, hasProfile: true, open: false);
    expect(auth.otps, hasLength(1));
    // Signing in never creates an account.
    expect(auth.created, [false]);
  });
}

/// Types a number and taps Next; the "Create a new account?" sheet keeps
/// Next spinning, so frames for a moment instead of settling.
Future<void> _next(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), '123456789');
  await tester.tap(find.widgetWithText(FilledButton, 'Next'));
  await _frames(tester);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
