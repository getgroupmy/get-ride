import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/auth_utils.dart';
import 'package:get_ride/src/data/account_repository.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/auth/set_pin_screen.dart';
import 'package:get_ride/src/features/auth/signup_photo_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/live_selfie.dart' show LiveSelfie;
import 'package:go_router/go_router.dart';

class _FakeAuth implements AuthRepository {
  _FakeAuth({this.device = DeviceRegistration.unknown});
  final DeviceRegistration device;
  final pins = <String>[];
  final roles = <String?>[];

  @override
  Future<DeviceRegistration> deviceRegistration() async => device;

  @override
  Future<void> setPin(String pin, {String? role}) async {
    pins.add(pin);
    roles.add(role);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAccount implements AccountRepository {
  final uploads = <String>[];
  final names = <String>[];

  @override
  Future<void> updateProfile({String? name, String? email, Map<String, String?>? identity}) async {
    if (name != null) names.add(name);
  }

  @override
  Future<String> uploadAvatar(Uint8List bytes, {required String ext, required String contentType}) async {
    uploads.add(ext);
    return 'https://example.com/a.$ext';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

GoRouter _router(String initial, {Widget? photo}) => GoRouter(
  initialLocation: initial,
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => const Scaffold(body: Text('map')),
    ),
    GoRoute(
      path: '/drive',
      builder: (_, _) => const Scaffold(body: Text('drive')),
    ),
    GoRoute(
      path: '/drive/onboarding',
      builder: (_, _) => const Scaffold(body: Text('partner registration')),
    ),
    GoRoute(path: '/set-pin', builder: (_, _) => const SetPinScreen()),
    GoRoute(
      path: '/signup/photo',
      builder: (_, s) => photo ?? SignupPhotoScreen(next: s.uri.queryParameters['next'] ?? '/'),
    ),
  ],
);

void main() {
  test('Driver goes straight into partner registration; anything else on the map', () {
    expect(signupLanding('driver'), '/drive/onboarding');
    expect(signupLanding('passenger'), '/');
    expect(signupLanding(null), '/');
    expect(signupPhotoNext('/drive/onboarding'), '/drive/onboarding');
    expect(signupPhotoNext('/drive'), '/drive/onboarding', reason: 'older links meant Driver');
    expect(signupPhotoNext('/admin'), '/', reason: 'never an arbitrary route');
    expect(signupPhotoNext(null), '/');
  });

  group('new account', () {
    Future<void> pump(
      WidgetTester tester,
      Map<String, dynamic> profile,
      _FakeAccount account, {
      _FakeAuth? auth,
      Brightness brightness = Brightness.light,
      AppDisplay display = const AppDisplay(),
    }) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authRepositoryProvider.overrideWithValue(auth ?? _FakeAuth()),
            accountRepositoryProvider.overrideWithValue(account),
            profileProvider.overrideWith((ref) async => Profile(profile)),
            appDisplayProvider.overrideWith((ref) async => display),
          ],
          child: MaterialApp.router(theme: ThemeData(brightness: brightness), routerConfig: _router('/set-pin')),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> save(WidgetTester tester, {String? name}) async {
      if (name != null) await tester.enterText(find.widgetWithText(TextField, 'Your name'), name);
      await tester.enterText(find.widgetWithText(TextField, 'New PIN'), '123456');
      await tester.enterText(find.widgetWithText(TextField, 'Confirm PIN'), '123456');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save PIN'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save PIN'));
      await tester.pumpAndSettle();
    }

    testWidgets('chooses driver: photo step, then Skip goes straight into partner registration', (tester) async {
      final account = _FakeAccount();
      final auth = _FakeAuth();
      await pump(tester, {'id': 'me'}, account, auth: auth);
      expect(find.text('Are you a passenger or a driver?'), findsOneWidget);
      await tester.tap(find.text('Driver'));
      await tester.pumpAndSettle();
      await save(tester, name: 'Ali');
      expect(account.names, ['Ali']);
      expect(auth.roles, ['driver'], reason: 'the server checks the role it signs up as');
      expect(find.text('Add a profile photo'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(find.text('partner registration'), findsOneWidget);
    });

    testWidgets('a passenger lands on the map, as before', (tester) async {
      final auth = _FakeAuth();
      await pump(tester, {'id': 'me'}, _FakeAccount(), auth: auth);
      await save(tester, name: 'Ali');
      expect(auth.roles, ['passenger']);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(find.text('map'), findsOneWidget);
    });

    testWidgets('a driver who already has a photo goes straight into partner registration', (tester) async {
      await pump(tester, {'id': 'me', 'avatar_url': 'https://example.com/a.png'}, _FakeAccount());
      await tester.tap(find.text('Driver'));
      await tester.pumpAndSettle();
      await save(tester, name: 'Ali');
      expect(find.text('partner registration'), findsOneWidget);
    });

    for (final b in Brightness.values) {
      testWidgets('passenger sign-up paused: only Driver, with a note (${b.name})', (tester) async {
        final auth = _FakeAuth();
        await pump(tester, {'id': 'me'}, _FakeAccount(),
            auth: auth, brightness: b, display: const AppDisplay(passengerRegistrationEnabled: false));
        expect(find.text('Passenger'), findsNothing);
        expect(find.text('Driver'), findsOneWidget);
        expect(find.text(passengerSignUpPausedNote), findsOneWidget);
        expect(find.text(driverSignupNote), findsOneWidget, reason: 'Driver is the choice');
        await save(tester, name: 'Ali');
        expect(auth.roles, ['driver']);
        expect(tester.takeException(), isNull);
      });

      testWidgets('driver sign-up paused: only Passenger, with a note (${b.name})', (tester) async {
        final auth = _FakeAuth();
        await pump(tester, {'id': 'me'}, _FakeAccount(),
            auth: auth, brightness: b, display: const AppDisplay(driverRegistrationEnabled: false));
        expect(find.text('Driver'), findsNothing);
        expect(find.text('Passenger'), findsOneWidget);
        expect(find.text(driverSignUpPausedNote), findsOneWidget);
        await save(tester, name: 'Ali');
        expect(auth.roles, ['passenger']);
        expect(tester.takeException(), isNull);
      });
    }

    test('signupRoles follows the switches', () {
      expect(signupRoles(const AppDisplay()), ['passenger', 'driver']);
      expect(signupRoles(const AppDisplay(passengerRegistrationEnabled: false)), ['driver']);
      expect(signupRoles(const AppDisplay(driverRegistrationEnabled: false)), ['passenger']);
      expect(signupRoles(const AppDisplay(registrationEnabled: false)), ['passenger', 'driver'],
          reason: 'both closed: the server has the last word');
    });

    for (final b in Brightness.values) {
      testWidgets('Driver picked says what comes after; no em dash in the PIN line (${b.name})', (tester) async {
        await pump(tester, {'id': 'me'}, _FakeAccount(), brightness: b);
        expect(find.text('Use this 6-digit PIN to sign in on any device. No SMS needed.'), findsOneWidget);
        expect(find.byKey(const ValueKey('signup-driver-note')), findsNothing, reason: 'a passenger needs no note');
        await tester.tap(find.text('Driver'));
        await tester.pumpAndSettle();
        expect(find.text(driverSignupNote), findsOneWidget);
        // Right under the Passenger/Driver control.
        final control = tester.getRect(find.byKey(const ValueKey('signup-role')));
        final note = tester.getRect(find.text(driverSignupNote));
        expect(note.top, greaterThan(control.bottom));
        expect(note.top - control.bottom, lessThan(48));
        for (final w in tester.widgetList<Text>(find.byType(Text))) {
          expect(w.data ?? '', isNot(contains('—')), reason: 'no em dash on Set PIN: "${w.data}"');
        }
        await tester.tap(find.text('Passenger'));
        await tester.pumpAndSettle();
        expect(find.text(driverSignupNote), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a new account must give its name, which is tidied', (tester) async {
      final auth = _FakeAuth();
      final account = _FakeAccount();
      await pump(tester, {'id': 'me'}, account, auth: auth);
      await save(tester);
      expect(find.text('Please enter your name.'), findsOneWidget);
      expect(auth.pins, isEmpty);
      await save(tester, name: '  siti   aminah ');
      expect(auth.pins, ['123456']);
      expect(account.names, ['Siti Aminah']);
    });

    testWidgets('the device guard is asked first and its reason shown', (tester) async {
      final auth = _FakeAuth(device: const DeviceRegistration(allowed: false, emulatorBlocked: true));
      await pump(tester, {'id': 'me'}, _FakeAccount(), auth: auth);
      await save(tester, name: 'Ali');
      expect(find.text(deviceGuardMessage(emulator: true)), findsOneWidget);
      expect(auth.pins, isEmpty);
      expect(find.text('Add a profile photo'), findsNothing);
    });

    testWidgets('passenger is the default and lands on the map', (tester) async {
      await pump(tester, {'id': 'me'}, _FakeAccount());
      await save(tester, name: 'Ali');
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(find.text('map'), findsOneWidget);
    });

    testWidgets('an account that already has a photo skips the photo step', (tester) async {
      await pump(tester, {'id': 'me', 'avatar_url': 'https://example.com/me.png'}, _FakeAccount());
      await save(tester, name: 'Ali');
      expect(find.text('Add a profile photo'), findsNothing);
      expect(find.text('map'), findsOneWidget);
    });

    testWidgets('an existing account re-setting its PIN sees neither step', (tester) async {
      await pump(tester, {'id': 'me', 'name': 'Ali'}, _FakeAccount());
      expect(find.text('Are you a passenger or a driver?'), findsNothing);
      await save(tester);
      expect(find.text('Add a profile photo'), findsNothing);
      expect(find.text('map'), findsOneWidget);
    });
  });

  group('photo step', () {
    testWidgets('Continue waits for a photo, which is uploaded on pick', (tester) async {
      final account = _FakeAccount();
      var profile = <String, dynamic>{'id': 'me', 'name': 'Ali'};
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountRepositoryProvider.overrideWithValue(account),
            profileProvider.overrideWith((ref) async => Profile(profile)),
          ],
          child: MaterialApp.router(
            routerConfig: _router(
              '/signup/photo',
              photo: SignupPhotoScreen(
                next: '/drive',
                takeSelfie: (_) async {
                  profile = {...profile, 'avatar_url': 'https://example.com/a.png'};
                  return LiveSelfie(bytes: Uint8List(10), name: 'me.png', liveness: 'passed', detail: 'turn');
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      FilledButton cont() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'));
      expect(cont().onPressed, isNull);
      expect(find.text('A'), findsOneWidget);

      await tester.tap(find.text('Take a selfie'));
      await tester.pump();
      await tester.pump();
      expect(account.uploads, ['png']);
      expect(find.text('Take a new selfie'), findsOneWidget);
      expect(cont().onPressed, isNotNull);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('drive'), findsOneWidget);
    });
  });
}
