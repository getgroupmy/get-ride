// A deep link opened signed out (#73): /drive/statements → /login?next= →
// Continue with phone → the PIN → signed in, and the app opens the page
// that was asked for, not home. The page rides along the steps' addresses
// (`to`) so a reload on any of them keeps it, and is still checked by
// signInNextPath.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show routerProvider;
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/auth_utils.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/features/auth/passkey_sign_in_button.dart';
import 'package:get_ride/src/features/auth/phone_screen.dart';
import 'package:get_ride/src/features/auth/welcome_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _settle(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A session the client takes as signed in (never sent anywhere).
String _session() {
  String part(Map<String, Object> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final exp = DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000;
  final jwt = '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part({'sub': 'u1', 'exp': exp, 'role': 'authenticated'})}.sig';
  return jsonEncode({
    'access_token': jwt,
    'token_type': 'bearer',
    'expires_in': 86400,
    'expires_at': exp,
    'refresh_token': 'r',
    'user': {
      'id': 'u1',
      'aud': 'authenticated',
      'role': 'authenticated',
      'created_at': '2026-01-01T00:00:00Z',
      'app_metadata': <String, Object>{},
      'user_metadata': <String, Object>{},
    },
  });
}

class _QuietLive extends LiveTables {
  @override
  Map<String, int> build() => const {};
}

void main() {
  late SupabaseClient db;
  late GoRouter router;

  Future<void> start(WidgetTester tester, String at) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.reset);
    PendingSignInRoute.path = null;
    db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        supabaseProvider.overrideWithValue(db),
        deviceBlockedProvider.overrideWith((ref) async => false),
        appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
        passkeyOfferedHereProvider.overrideWith((ref) async => false),
        currentUserIdProvider.overrideWithValue(null),
        partnerProvider.overrideWith((ref) async => null),
        profileProvider.overrideWith((ref) async => null),
        // No realtime socket in a test.
        liveTablesProvider.overrideWith(_QuietLive.new),
      ],
    );
    addTearDown(container.dispose);
    router = container.read(routerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: MaterialApp.router(routerConfig: router)),
    );
    await _settle(tester);
    router.go(at);
    await _settle(tester);
  }

  Uri location() => router.routerDelegate.currentConfiguration.uri;

  testWidgets('the page asked for rides through every step and opens once signed in', (tester) async {
    await start(tester, '/drive/statements');
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(location().toString(), '/login?next=%2Fdrive%2Fstatements');

    // Continue with phone: the number page carries it.
    await tester.tap(find.text('Continue with phone'));
    await _settle(tester);
    expect(find.byType(PhoneScreen), findsOneWidget);
    // The pushed page's own address, as the browser shows it.
    final phone = GoRouterState.of(tester.element(find.byType(PhoneScreen))).uri;
    expect(phone.path, '/login/phone');
    expect(phone.queryParameters[signInTargetKey], '/drive/statements');

    // A reload there (memory gone) keeps it, from the address.
    PendingSignInRoute.path = null;
    router.go(phone.toString());
    await _settle(tester);
    expect(PendingSignInRoute.path, '/drive/statements');

    // The PIN step's address carries it too.
    final pin = signInStepPath('/login/pin', '+60123456789');
    expect(Uri.parse(pin).queryParameters[signInTargetKey], '/drive/statements');
    router.go(pin);
    await _settle(tester);
    expect(location().path, '/login/pin');

    // Signed in by the PIN: the router takes over and opens the page.
    await db.auth.recoverSession(_session());
    await _settle(tester, 12);
    expect(location().path, '/drive/statements');
    expect(PendingSignInRoute.path, isNull, reason: 'used once');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  test('a step that sends home after signing in goes to the page instead', () {
    PendingSignInRoute.path = '/wallet/history';
    expect(signInLanding(), '/wallet/history');
    expect(signInAddress('/login/set-pin'), '/login/set-pin?to=%2Fwallet%2Fhistory');
    PendingSignInRoute.path = null;
    expect(signInLanding(), '/');
    expect(signInAddress('/login/set-pin'), '/login/set-pin');
  });

  test('a carried page is checked like next=', () {
    PendingSignInRoute.path = null;
    rememberSignInTarget('/login/pin', const {'to': '//evil.example/x'});
    expect(PendingSignInRoute.path, isNull);
    rememberSignInTarget('/login/otp', const {'next': 'resync', 'to': '/trips'});
    expect(PendingSignInRoute.path, '/trips', reason: "otp's own next is not the page");
    PendingSignInRoute.path = null;
    rememberSignInTarget('/login', const {'next': '/wallet'});
    expect(PendingSignInRoute.path, '/wallet');
    PendingSignInRoute.path = null;
  });
}
