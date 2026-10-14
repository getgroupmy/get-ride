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
import 'package:get_ride/src/providers.dart';

class _Auth implements AuthRepository {
  int passkeySignIns = 0;
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

  group('sign-in screen', () {
    Future<_Auth> pump(WidgetTester tester, {required bool offered, Brightness b = Brightness.light}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 1100);
      addTearDown(tester.view.reset);
      final auth = _Auth();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceBlockedProvider.overrideWith((ref) async => false),
            authRepositoryProvider.overrideWithValue(auth),
            appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
            passkeyOfferedHereProvider.overrideWith((ref) async => offered),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: b),
            home: const PhoneScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return auth;
    }

    tearDown(() => signedOutElsewhere.value = false);

    testWidgets('no passkey button until the admin turns it on for this surface', (tester) async {
      await pump(tester, offered: false);
      expect(find.byKey(const ValueKey('passkey-sign-in')), findsNothing);
    });

    for (final b in Brightness.values) {
      testWidgets('the passkey button signs in; closing the prompt says nothing (${b.name})', (tester) async {
        final auth = await pump(tester, offered: true, b: b);
        expect(find.text('Sign in with a passkey'), findsOneWidget);
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
