import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/pin_change.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/features/settings/change_pin_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

class _FakeAuth implements AuthRepository {
  _FakeAuth({this.hasPin = true, this.locked, this.synced = true});

  static const current = '111111';
  final bool hasPin;
  final String? locked;
  final bool synced;
  final checked = <String>[];
  final saved = <String>[];
  final otps = <(String, bool)>[];
  final codes = <String>[];

  @override
  Future<bool> hasPinSet() async => hasPin;

  @override
  String? get currentPhone => '+60123456789';

  @override
  Future<String?> checkCurrentPin(String pin) async {
    checked.add(pin);
    if (locked != null) return locked;
    return pin == current ? null : 'Incorrect PIN. Please try again.';
  }

  @override
  Future<bool> changePin(String pin, {Duration retryAfter = Duration.zero}) async {
    saved.add(pin);
    return synced;
  }

  @override
  Future<void> sendOtp(String phone, {required bool createUser}) async => otps.add((phone, createUser));

  @override
  Future<void> verifyOtp(String phone, String code) async {
    if (code != '654321') throw StateError('Invalid code.');
    codes.add(code);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('pure', () {
    test('an account without a PIN starts by choosing one', () {
      expect(firstPinChangeStep(hasPin: true), PinChangeStep.verify);
      expect(firstPinChangeStep(hasPin: false), PinChangeStep.create);
    });

    test('back walks the steps, then leaves', () {
      expect(previousPinChangeStep(PinChangeStep.confirm, hasPin: true), PinChangeStep.create);
      expect(previousPinChangeStep(PinChangeStep.create, hasPin: true), PinChangeStep.verify);
      expect(previousPinChangeStep(PinChangeStep.code, hasPin: true), PinChangeStep.verify);
      expect(previousPinChangeStep(PinChangeStep.verify, hasPin: true), isNull);
      expect(previousPinChangeStep(PinChangeStep.create, hasPin: false), isNull);
    });

    test('the new PIN must be 6 digits, typed twice, and new', () {
      expect(newPinProblem('12345', '12345'), 'PIN must be 6 digits.');
      expect(newPinProblem('123456', '123457'), 'PINs do not match. Please try again.');
      expect(newPinProblem('123456', '123456', current: '123456'), 'New PIN must be different from current PIN.');
      expect(newPinProblem('123456', '123456', current: '111111'), isNull);
      expect(newPinProblem('123456', '123456'), isNull);
    });
  });

  Future<void> pump(WidgetTester tester, _FakeAuth auth, {Brightness brightness = Brightness.light}) async {
    final router = GoRouter(
      initialLocation: '/account/settings',
      routes: [
        GoRoute(
          path: '/account/settings',
          builder: (_, _) => const Scaffold(body: Text('settings')),
          routes: [GoRoute(path: 'pin', builder: (_, _) => const ChangePinScreen())],
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(auth)],
        child: MaterialApp.router(
          theme: ThemeData(brightness: brightness),
          routerConfig: router,
        ),
      ),
    );
    router.push('/account/settings/pin');
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String code) async {
    await tester.enterText(find.byType(TextField), code);
    await tester.pumpAndSettle();
  }

  String title(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('pin-step-title'))).data!;

  for (final b in Brightness.values) {
    testWidgets('current PIN, new PIN, again, then the success popup (${b.name})', (tester) async {
      final auth = _FakeAuth();
      await pump(tester, auth, brightness: b);
      expect(find.text('Change PIN'), findsOneWidget);
      expect(title(tester), 'Enter your current PIN');

      await type(tester, '222222');
      expect(find.text('Incorrect PIN. Please try again.'), findsOneWidget);
      expect(title(tester), 'Enter your current PIN');

      await type(tester, _FakeAuth.current);
      expect(title(tester), 'Create your new PIN');
      await type(tester, '123456');
      expect(title(tester), 'Confirm your new PIN');
      await type(tester, '123457');
      expect(find.text('PINs do not match. Please try again.'), findsOneWidget);
      expect(title(tester), 'Confirm your new PIN');
      await type(tester, '123456');

      expect(auth.saved, ['123456']);
      expect(find.text('New PIN Has Been Updated'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsOneWidget);
    });
  }

  testWidgets('the same PIN again is sent back to choose a new one', (tester) async {
    final auth = _FakeAuth();
    await pump(tester, auth);
    await type(tester, _FakeAuth.current);
    await type(tester, _FakeAuth.current);
    await type(tester, _FakeAuth.current);
    expect(find.text('New PIN must be different from current PIN.'), findsOneWidget);
    expect(title(tester), 'Create your new PIN');
    expect(auth.saved, isEmpty);
  });

  testWidgets('a lockout is told as it is', (tester) async {
    final auth = _FakeAuth(locked: 'Too many incorrect attempts. Try again in 15 minutes.');
    await pump(tester, auth);
    await type(tester, _FakeAuth.current);
    expect(find.text('Too many incorrect attempts. Try again in 15 minutes.'), findsOneWidget);
    expect(title(tester), 'Enter your current PIN');
  });

  testWidgets('an account without a PIN sets one without proving the old', (tester) async {
    final auth = _FakeAuth(hasPin: false);
    await pump(tester, auth, brightness: Brightness.dark);
    expect(find.text('Set PIN'), findsOneWidget);
    expect(title(tester), 'Create your PIN');
    expect(find.byKey(const ValueKey('pin-forgot')), findsNothing);
    await type(tester, '123456');
    await type(tester, '123456');
    expect(auth.checked, isEmpty);
    expect(auth.saved, ['123456']);
    expect(find.text('Your PIN Has Been Set'), findsOneWidget);
  });

  testWidgets('forgot PIN proves the phone by SMS, never creating an account', (tester) async {
    final auth = _FakeAuth();
    await pump(tester, auth);
    await tester.tap(find.byKey(const ValueKey('pin-forgot')));
    await tester.pumpAndSettle();
    expect(auth.otps, [('+60123456789', false)]);
    expect(title(tester), 'Enter the code');
    expect(find.textContaining('+60123456789'), findsOneWidget);

    await type(tester, '000000');
    expect(find.text('Invalid code.'), findsOneWidget);
    await type(tester, '654321');
    expect(title(tester), 'Create your new PIN');
    // The old PIN isn't known, so it may be chosen again.
    await type(tester, _FakeAuth.current);
    await type(tester, _FakeAuth.current);
    expect(auth.saved, [_FakeAuth.current]);
    expect(auth.checked, isEmpty);
  });

  testWidgets('a password that lags still reports the PIN changed', (tester) async {
    await pump(tester, _FakeAuth(synced: false));
    await type(tester, _FakeAuth.current);
    await type(tester, '123456');
    await type(tester, '123456');
    expect(find.text('New PIN Has Been Updated'), findsOneWidget);
    expect(find.textContaining('text you a code once'), findsOneWidget);
  });

  testWidgets('back steps through, then leaves', (tester) async {
    await pump(tester, _FakeAuth());
    await type(tester, _FakeAuth.current);
    await type(tester, '123456');
    expect(title(tester), 'Confirm your new PIN');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(title(tester), 'Create your new PIN');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(title(tester), 'Enter your current PIN');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('settings'), findsOneWidget);
  });
}
