import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/features/auth/pin_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

class _FakeAuth implements AuthRepository {
  _FakeAuth(this.result);
  final PinSignInResult result;
  final sent = <String>[];

  @override
  Future<PinSignInResult> signInWithPin(String phone, String pin) async => result;

  @override
  Future<void> sendOtp(String phone, {required bool createUser}) async => sent.add(phone);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<List<String>> _pump(WidgetTester tester, _FakeAuth auth) async {
  final opened = <String>[];
  final router = GoRouter(
    initialLocation: '/pin',
    routes: [
      GoRoute(
        path: '/pin',
        builder: (_, _) => const PinScreen(phone: '+60123456789'),
      ),
      GoRoute(
        path: '/login/otp',
        builder: (_, s) {
          opened.add(s.uri.toString());
          return const Scaffold(body: Text('otp'));
        },
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authRepositoryProvider.overrideWithValue(auth)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.enterText(find.byType(TextField).first, '111111');
  await tester.pumpAndSettle();
  return opened;
}

void main() {
  testWidgets('a locked PIN offers signing in with an SMS code, keeping the PIN', (tester) async {
    final auth = _FakeAuth(const PinSignInError('Too many incorrect attempts. Try again in 15 minutes.', locked: true));
    final opened = await _pump(tester, auth);
    expect(find.textContaining('Too many incorrect attempts'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pin-sms-unlock')));
    await tester.pumpAndSettle();
    expect(auth.sent, ['+60123456789']);
    expect(opened.single, contains('next=unlock'));
  });

  testWidgets('a wrong PIN does not offer the SMS sign-in', (tester) async {
    final opened = await _pump(tester, _FakeAuth(const PinSignInError('Incorrect PIN. Please try again.')));
    expect(find.text('Incorrect PIN. Please try again.'), findsOneWidget);
    expect(find.byKey(const ValueKey('pin-sms-unlock')), findsNothing);
    expect(opened, isEmpty);
  });
}
