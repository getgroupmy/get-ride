import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/auth_utils.dart';
import 'package:get_ride/src/core/dial_countries.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/features/auth/phone_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

class _Auth implements AuthRepository {
  _Auth({this.lookup});

  /// Null: the lookup fails.
  final PhoneLookup? lookup;
  final looked = <String>[];
  final otps = <(String, bool)>[];

  @override
  Future<PhoneLookup> lookupPhone(String phone) async {
    looked.add(phone);
    final l = lookup;
    if (l == null) throw const PhoneLookupFailed();
    return l;
  }

  @override
  Future<void> sendOtp(String phone, {required bool createUser}) async => otps.add((phone, createUser));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _new = PhoneLookup(hasProfile: false, hasPin: false, isDeleted: false);

void main() {
  group('pure', () {
    test('a dial code typed again in the number is dropped, a short number kept', () {
      expect(composePhone('+60', '60123456789'), '+60123456789');
      expect(composePhone('+60', '0123456789'), '+60123456789');
      expect(composePhone('+60', '123456789'), '+60123456789');
      expect(composePhone('+1', '1 415 555 0100'), '+14155550100');
      // Too short to be the dial code repeated: kept as typed.
      expect(composePhone('+60', '6012345'), '+606012345');
    });

    test('names are required, capped and tidied', () {
      expect(signupNameProblem('  '), 'Please enter your name.');
      expect(signupNameProblem('a' * 51), contains('50'));
      expect(signupNameProblem('Ali'), isNull);
      expect(capitaliseName('  siti   aminah binti ali '), 'Siti Aminah Binti Ali');
      expect(capitaliseName("o'neil"), "O'neil");
    });

    test('the device guard answer reads both refusals and fails open', () {
      expect(DeviceRegistration.fromRpc(null).allowed, isTrue);
      expect(DeviceRegistration.fromRpc(const []).problem, isNull);
      final limit = DeviceRegistration.fromRpc([
        {'allowed': false, 'is_emulator': false, 'block_emulators': true},
      ]);
      expect(limit.problem, deviceGuardMessage(emulator: false));
      final emu = DeviceRegistration.fromRpc({'allowed': false, 'is_emulator': true, 'block_emulators': true});
      expect(emu.problem, deviceGuardMessage(emulator: true));
    });

    test('countries are found by name, code or dial code', () {
      expect(dialCountries.length, greaterThanOrEqualTo(30));
      expect(searchDialCountries('mal').map((c) => c.code), ['MY']);
      expect(searchDialCountries('sg').single.name, 'Singapore');
      expect(searchDialCountries('+65').single.code, 'SG');
      expect(searchDialCountries('1').map((c) => c.code), containsAll(['US', 'CA']));
      expect(dialCountryFor('+60').code, 'MY');
      expect(dialCountryFor('+999').dialCode, '+999');
    });
  });

  Future<_Auth> pump(WidgetTester tester, _Auth auth, Brightness brightness) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceBlockedProvider.overrideWith((ref) async => false),
          authRepositoryProvider.overrideWithValue(auth),
          appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
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
                    path: 'otp',
                    builder: (_, s) => Scaffold(body: Text('otp ${s.uri.query}')),
                  ),
                  GoRoute(
                    path: 'pin',
                    builder: (_, _) => const Scaffold(body: Text('pin')),
                  ),
                ],
              ),
              GoRoute(
                path: '/diagnostics',
                builder: (_, _) => const Scaffold(body: Text('diagnostics')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return auth;
  }

  // The Continue button keeps spinning while its sheet is open, so these
  // pump a while rather than wait for everything to settle.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> submit(WidgetTester tester, String number) async {
    await tester.enterText(find.byType(TextField), number);
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await settle(tester);
  }

  for (final b in Brightness.values) {
    testWidgets('a new number is asked before any code is sent (${b.name})', (tester) async {
      final auth = await pump(tester, _Auth(lookup: _new), b);
      await submit(tester, '60123456789');
      expect(auth.looked, ['+60123456789']);
      expect(find.text('Create a new account?'), findsOneWidget);
      expect(find.byKey(const ValueKey('signup-phone')), findsOneWidget);
      expect(auth.otps, isEmpty);

      await tester.tap(find.text('Use a different number'));
      await settle(tester);
      expect(auth.otps, isEmpty);
      expect(find.byType(PhoneScreen), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('signup-send-code')));
      await settle(tester);
      expect(auth.otps, [('+60123456789', true)]);
      expect(find.textContaining('new=1'), findsOneWidget);
    });
  }

  testWidgets('a lookup that fails says so and sends nothing', (tester) async {
    final auth = await pump(tester, _Auth(), Brightness.light);
    await submit(tester, '123456789');
    expect(find.text('Could not verify number. Please try again.'), findsOneWidget);
    expect(auth.otps, isEmpty);
    expect(find.text('Create a new account?'), findsNothing);
  });

  testWidgets('an account without a PIN gets its code without creating one', (tester) async {
    final auth = await pump(
      tester,
      _Auth(lookup: const PhoneLookup(hasProfile: true, hasPin: false, isDeleted: false)),
      Brightness.light,
    );
    await submit(tester, '123456789');
    expect(find.text('Create a new account?'), findsNothing);
    expect(auth.otps, [('+60123456789', false)]);
  });

  testWidgets('the country picker searches and sets the dial code', (tester) async {
    final auth = await pump(
      tester,
      _Auth(lookup: const PhoneLookup(hasProfile: true, hasPin: true, isDeleted: false)),
      Brightness.dark,
    );
    await tester.tap(find.byKey(const ValueKey('dial-country')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('country-search')), 'singa');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Singapore'));
    await tester.pumpAndSettle();
    expect(find.text('+65'), findsOneWidget);
    await submit(tester, '81234567');
    expect(auth.looked, ['+6581234567']);
    expect(find.text('pin'), findsOneWidget);
  });

  testWidgets('diagnostics is a tap away', (tester) async {
    await pump(tester, _Auth(lookup: _new), Brightness.light);
    await tester.tap(find.byKey(const ValueKey('phone-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.text('diagnostics'), findsOneWidget);
  });
}
