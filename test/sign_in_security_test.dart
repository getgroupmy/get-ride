// ignore_for_file: experimental_member_use
// `Passkey` (gotrue) is @experimental: passkeys are a beta Supabase feature.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/sign_in_security.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/session_guard.dart';
import 'package:get_ride/src/features/auth/passkey/passkey.dart' as pk;
import 'package:get_ride/src/features/auth/passkey_sign_in_button.dart';
import 'package:get_ride/src/features/auth/phone_screen.dart';
import 'package:get_ride/src/features/auth/welcome_screen.dart';
import 'package:get_ride/src/features/settings/passkeys_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Passkey;

class _Auth implements AuthRepository {
  int passkeySignIns = 0;
  int passkeySaves = 0;

  @override
  Future<List<Passkey>> passkeys() async => const [];

  @override
  Future<pk.PasskeyResult> savePasskey() async {
    passkeySaves++;
    return (outcome: pk.PasskeyOutcome.cancelled, message: null);
  }

  pk.PasskeyResult next = (outcome: pk.PasskeyOutcome.cancelled, message: null);

  @override
  Future<pk.PasskeyResult> signInWithPasskey() async {
    passkeySignIns++;
    return next;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _token(Map<String, dynamic> claims) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part(claims)}.sig';
}

void main() {
  group('switches', () {
    test('ship off and read only true', () {
      expect(SignInConfig.fromJson(null), SignInConfig.off);
      expect(SignInConfig.fromJson('nope'), SignInConfig.off);
      final c = SignInConfig.fromJson({'passkeyIos': true, 'passkeyAndroid': 'true', 'oneDevice': 1});
      expect(c.passkeyIos, isTrue);
      expect(c.passkeyAndroid, isTrue);
      expect(c.oneDevice, isFalse, reason: 'only true or "true" turns a switch on');
      expect(SignInConfig.fromJson(c.toJson()), c);
    });

    test('each surface has its own passkey switch; desktop is never offered one', () {
      const ios = SignInConfig(passkeyIos: true);
      expect(passkeyOffered(ios, signInSurface(isWeb: false, platform: TargetPlatform.iOS)), isTrue);
      expect(passkeyOffered(ios, signInSurface(isWeb: false, platform: TargetPlatform.android)), isFalse);
      expect(passkeyOffered(ios, signInSurface(isWeb: true, platform: TargetPlatform.iOS)), isFalse);
      const all = SignInConfig(passkeyWeb: true, passkeyAndroid: true, passkeyIos: true);
      expect(passkeyOffered(all, signInSurface(isWeb: false, platform: TargetPlatform.macOS)), isFalse);
      expect(passkeyOffered(all, signInSurface(isWeb: true, platform: TargetPlatform.windows)), isTrue);
    });
  });

  group('wrong address', () {
    test('passkeys work only on https://www.getride.my; anywhere else is sent there, same page', () {
      expect(passkeyAddressFix(Uri.parse('https://www.getride.my/account/settings/passkeys')), isNull);
      expect(
        passkeyAddressFix(Uri.parse('http://getride.my/account/settings?x=1#top')),
        Uri.parse('https://www.getride.my/account/settings?x=1#top'),
      );
      expect(passkeyAddressFix(Uri.parse('http://www.getride.my/login')), Uri.parse('https://www.getride.my/login'));
      expect(passkeyAddressFix(Uri.parse('https://getride.my')), Uri.parse('https://www.getride.my/'));
      expect(
        passkeyAddressFix(Uri.parse('https://get-ride-abc.vercel.app/login')),
        Uri.parse('https://www.getride.my/login'),
      );
      expect(
        passkeyAddressFix(Uri.parse('http://localhost:8080/login')),
        Uri.parse('https://www.getride.my/login'),
        reason: 'the port is not carried over',
      );
    });

    test('says where passkeys work and why not here', () {
      final insecure = passkeyWrongAddressMessage(Uri.parse('http://getride.my/account'));
      expect(insecure, contains('only work at www.getride.my'));
      expect(insecure, contains('open at getride.my without a secure (https) connection'));
      final other = passkeyWrongAddressMessage(Uri.parse('https://getride.my/account'));
      expect(other, contains('open at getride.my,'));
      expect(other, isNot(contains('https) connection')));
    });
  });

  group("the browser's reason", () {
    test('a dismissal or timeout says nothing', () {
      for (final n in ['NotAllowedError', 'AbortError', '']) {
        expect(pk.webPasskeyRefusal(n, creating: true), isNull, reason: n);
        expect(pk.webPasskeyRefusal(n, creating: false), isNull, reason: n);
      }
    });

    test("a site whose passkey setting doesn't match its address is named, as a site setting", () {
      final m = pk.webPasskeyRefusal('SecurityError', creating: true);
      expect(m, pk.passkeySiteMismatch);
      expect(m, contains("passkey setting doesn't match"));
      expect(pk.passkeyNotSetUpHere(m), isTrue, reason: 'shown as a plain note, not a red error');
      expect(pk.passkeyNotSetUpHere(pk.passkeyDomainNotAssociated), isTrue);
      expect(pk.passkeyNotSetUpHere('Something else'), isFalse);
    });

    test('other refusals say what to do', () {
      expect(pk.webPasskeyRefusal('InvalidStateError', creating: true), contains('already saved on this device'));
      expect(pk.webPasskeyRefusal('NotSupportedError', creating: true), contains("can't save a passkey"));
      expect(pk.webPasskeyRefusal('NotSupportedError', creating: false), contains("can't use a passkey"));
      expect(pk.webPasskeyRefusal('ConstraintError', creating: true), contains('screen lock'));
      expect(pk.webPasskeyRefusal('UnknownError', creating: false), contains('(UnknownError)'));
      expect(pk.webPasskeyRefusal('InvalidStateError', creating: false), contains('(InvalidStateError)'));
    });
  });

  group('one device', () {
    test("a token's session id is read from its claims", () {
      expect(sessionIdOf(_token({'sub': 'u', 'session_id': 's-1'})), 's-1');
      expect(sessionIdOf(_token({'sub': 'u'})), isNull);
      expect(sessionIdOf('not.a.token'), isNull);
      expect(sessionIdOf(null), isNull);
    });

    test('replaced only by a row naming another session', () {
      expect(replacedBy({'session_id': 'other'}, 'mine'), isTrue);
      expect(replacedBy({'session_id': 'mine'}, 'mine'), isFalse);
      expect(replacedBy({}, 'mine'), isFalse, reason: 'a deleted row (switched off) is not a replacement');
      expect(replacedBy({'session_id': 'other'}, null), isFalse);
    });

    test("the server's refusal is recognised in any error", () {
      expect(isSignedInElsewhere(Exception('PostgrestException(message: signed_in_elsewhere, code: PT401)')), isTrue);
      expect(isSignedInElsewhere(Exception('JWT expired')), isFalse);
      expect(isSignedInElsewhere(null), isFalse);
    });

    test("the admin's device line", () {
      final row = {
        'device_label': 'iPhone',
        'platform': 'ios',
        'app_version': '1.4.8',
        'claimed_at': '2026-10-14T01:12:00Z',
      };
      expect(activeDeviceLine(row), 'iPhone · ios · app 1.4.8');
      expect(activeDeviceLine(row, when: (_) => 'today'), 'iPhone · ios · app 1.4.8 · since today');
      expect(activeDeviceLine({'claimed_at': '2026-10-14T01:12:00Z'}), 'Signed out everywhere');
    });
  });

  group('welcome page', () {
    Future<_Auth> pump(
      WidgetTester tester, {
      required bool offered,
      Brightness b = Brightness.light,
      Uri? fix,
      Size size = const Size(500, 1100),
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final auth = _Auth();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceBlockedProvider.overrideWith((ref) async => false),
            authRepositoryProvider.overrideWithValue(auth),
            appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
            passkeyOfferedHereProvider.overrideWith((ref) async => offered),
            passkeyAddressFixProvider.overrideWithValue(fix),
          ],
          child: MaterialApp.router(
            theme: ThemeData(brightness: b),
            routerConfig: GoRouter(
              initialLocation: '/login',
              routes: [
                GoRoute(
                  path: '/login',
                  builder: (_, _) => const WelcomeScreen(),
                  routes: [GoRoute(path: 'phone', builder: (_, _) => const PhoneScreen())],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return auth;
    }

    tearDown(() => signedOutElsewhere.value = false);

    // Web round 36 (170): "Continue with phone" is the filled primary
    // button (as Next and Sign in); a passkey is the outlined second way.
    for (final b in Brightness.values) {
      for (final size in const [Size(360, 640), Size(640, 360)]) {
        for (final passkey in ['none', 'here', 'www']) {
          testWidgets('170: Continue with phone is the primary filled button, passkey $passkey, '
              '${size.width.toInt()}x${size.height.toInt()} at 1.3x (${b.name})', (tester) async {
            tester.platformDispatcher.textScaleFactorTestValue = 1.3;
            addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
            await pump(
              tester,
              offered: passkey != 'none',
              b: b,
              size: size,
              fix: passkey == 'www' ? Uri.parse('https://www.getride.my/login') : null,
            );
            final phone = find.byKey(const ValueKey('continue-with-phone'));
            final button = tester.widget<FilledButton>(phone);
            final scheme = Theme.of(tester.element(phone)).colorScheme;
            final bg = (button.style?.backgroundColor?.resolve({}) ??
                FilledButtonTheme.of(tester.element(phone)).style?.backgroundColor?.resolve({}) ??
                scheme.primary);
            expect(bg, scheme.primary, reason: 'the primary colour, not grey tonal or inverse');
            if (passkey == 'here') {
              expect(tester.widget(find.byKey(const ValueKey('passkey-sign-in'))), isA<OutlinedButton>());
            }
            if (passkey == 'www') {
              expect(tester.widget(find.byKey(const ValueKey('passkey-open-www'))), isA<OutlinedButton>());
            }
            expect(find.byType(FilledButton), findsOneWidget, reason: 'one primary action on the page');
            expect(tester.takeException(), isNull);
          });
        }
      }
    }

    testWidgets('passkeys off: only Continue with phone', (tester) async {
      await pump(tester, offered: false);
      expect(find.byKey(const ValueKey('passkey-sign-in')), findsNothing);
      expect(find.text('Continue with phone'), findsOneWidget);
      expect(find.byKey(const ValueKey('welcome-terms')), findsOneWidget);
    });

    for (final b in Brightness.values) {
      testWidgets('continue with passkey signs in; closing the prompt says nothing (${b.name})', (tester) async {
        final auth = await pump(tester, offered: true, b: b);
        expect(find.text('Continue with passkey'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('passkey-sign-in')));
        await tester.pumpAndSettle();
        expect(auth.passkeySignIns, 1);
        expect(find.byType(SnackBar), findsNothing);

        auth.next = (outcome: pk.PasskeyOutcome.failed, message: 'There is no passkey saved on this device.');
        await tester.tap(find.byKey(const ValueKey('passkey-sign-in')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('There is no passkey saved on this device.'), findsOneWidget);
      });

      testWidgets('on the wrong address it offers www.getride.my instead of a passkey (${b.name})', (tester) async {
        final auth = await pump(tester, offered: true, b: b, fix: Uri.parse('https://www.getride.my/login'));
        expect(find.byKey(const ValueKey('passkey-sign-in')), findsNothing);
        expect(find.byKey(const ValueKey('passkey-open-www')), findsOneWidget);
        expect(find.text('Use a passkey at www.getride.my'), findsOneWidget);
        expect(find.text('Continue with phone'), findsOneWidget);
        expect(auth.passkeySignIns, 0);
      });

      testWidgets('Settings → Passkeys on the wrong address says where they work (${b.name})', (tester) async {
        final auth = _Auth();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authRepositoryProvider.overrideWithValue(auth),
              passkeyPageProvider.overrideWithValue(Uri.parse('http://getride.my/account/settings/passkeys')),
              passkeyAddressFixProvider.overrideWithValue(
                Uri.parse('https://www.getride.my/account/settings/passkeys'),
              ),
            ],
            child: MaterialApp(theme: ThemeData(brightness: b), home: const PasskeysScreen()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('passkeys-wrong-address')), findsOneWidget);
        expect(find.textContaining('This page is open at getride.my without a secure'), findsOneWidget);
        expect(find.byKey(const ValueKey('passkeys-open-www')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('passkeys-save')));
        await tester.pump();
        expect(auth.passkeySaves, 0, reason: 'the browser would refuse it here');
      });

      testWidgets('Settings → Passkeys on www.getride.my saves as before (${b.name})', (tester) async {
        final auth = _Auth();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authRepositoryProvider.overrideWithValue(auth),
              passkeyAddressFixProvider.overrideWithValue(null),
            ],
            child: MaterialApp(theme: ThemeData(brightness: b), home: const PasskeysScreen()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('passkeys-wrong-address')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('passkeys-save')));
        await tester.pumpAndSettle();
        expect(auth.passkeySaves, 1);
      });

      testWidgets('continue with phone opens the number page, and back returns (${b.name})', (tester) async {
        await pump(tester, offered: true, b: b);
        await tester.tap(find.byKey(const ValueKey('continue-with-phone')));
        await tester.pumpAndSettle();
        expect(find.text('Join us via phone number'), findsOneWidget);
        expect(find.byKey(const ValueKey('dial-country')), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('phone-number')), '123');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('phone-clear')));
        await tester.pump();
        expect(find.byKey(const ValueKey('phone-clear')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('sign-in-back')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('welcome')), findsOneWidget);
      });

      testWidgets('a device signed out by a newer sign-in says why (${b.name})', (tester) async {
        signedOutElsewhere.value = true;
        await pump(tester, offered: false, b: b);
        expect(find.byKey(const ValueKey('signed-out-elsewhere')), findsOneWidget);
        expect(find.text(signedOutElsewhereMessage), findsOneWidget);
        await tester.tap(find.byTooltip('Dismiss'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('signed-out-elsewhere')), findsNothing);
      });
    }
  });
}
