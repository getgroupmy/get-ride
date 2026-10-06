import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/auth/set_pin_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

class _FakeAuth implements AuthRepository {
  _FakeAuth({this.locked});

  static const current = '111111';
  final String? locked;
  final checked = <String>[];
  final saved = <String>[];

  @override
  Future<String?> checkCurrentPin(String pin) async {
    checked.add(pin);
    if (locked != null) return locked;
    return pin == current ? null : 'Incorrect PIN. Please try again.';
  }

  @override
  Future<void> setPin(String pin) async => saved.add(pin);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> pump(WidgetTester tester, _FakeAuth auth, {bool changing = true}) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/account/settings',
          builder: (_, _) => const Scaffold(body: Text('settings')),
        ),
        GoRoute(
          path: '/set-pin',
          builder: (_, _) => SetPinScreen(changing: changing),
        ),
      ],
      initialLocation: '/set-pin',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(auth),
          profileProvider.overrideWith((ref) async => Profile({'id': 'me', 'name': 'Ali'})),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> fill(WidgetTester tester, {required String current, required String pin, String? confirm}) async {
    await tester.enterText(find.byKey(const ValueKey('current-pin')), current);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(1), pin);
    await tester.enterText(fields.at(2), confirm ?? pin);
    await tester.tap(find.text('Save PIN'));
    await tester.pumpAndSettle();
  }

  testWidgets('changing asks for the current PIN; setting a first one does not', (tester) async {
    await pump(tester, _FakeAuth());
    expect(find.text('Current PIN'), findsOneWidget);
    await pump(tester, _FakeAuth(), changing: false);
    expect(find.text('Current PIN'), findsNothing);
  });

  testWidgets('the right current PIN changes it', (tester) async {
    final auth = _FakeAuth();
    await pump(tester, auth);
    await fill(tester, current: '111111', pin: '222222');
    expect(auth.checked, ['111111']);
    expect(auth.saved, ['222222']);
    expect(find.text('settings'), findsOneWidget);
    expect(find.text('PIN updated'), findsOneWidget);
  });

  testWidgets('a wrong current PIN changes nothing', (tester) async {
    final auth = _FakeAuth();
    await pump(tester, auth);
    await fill(tester, current: '999999', pin: '222222');
    expect(auth.saved, isEmpty);
    expect(find.text('Incorrect PIN. Please try again.'), findsOneWidget);
    expect(find.text('Change PIN'), findsOneWidget);
  });

  testWidgets('a locked-out check is reported and changes nothing', (tester) async {
    final auth = _FakeAuth(locked: 'Too many attempts. Try again in 5 minutes.');
    await pump(tester, auth);
    await fill(tester, current: '111111', pin: '222222');
    expect(auth.saved, isEmpty);
    expect(find.text('Too many attempts. Try again in 5 minutes.'), findsOneWidget);
  });

  testWidgets('the new PIN must differ from the current one', (tester) async {
    final auth = _FakeAuth();
    await pump(tester, auth);
    await fill(tester, current: '111111', pin: '111111');
    expect(auth.checked, isEmpty);
    expect(auth.saved, isEmpty);
    expect(find.text('New PIN must be different from current PIN.'), findsOneWidget);
  });

  testWidgets('the current PIN must be entered in full', (tester) async {
    final auth = _FakeAuth();
    await pump(tester, auth);
    await fill(tester, current: '11', pin: '222222');
    expect(auth.checked, isEmpty);
    expect(find.text('Enter your current 6-digit PIN.'), findsOneWidget);
  });
}
