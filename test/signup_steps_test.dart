import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/account_repository.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/auth/set_pin_screen.dart';
import 'package:get_ride/src/features/auth/signup_photo_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

class _FakeAuth implements AuthRepository {
  final pins = <String>[];

  @override
  Future<void> setPin(String pin) async => pins.add(pin);

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
    GoRoute(path: '/set-pin', builder: (_, _) => const SetPinScreen()),
    GoRoute(
      path: '/signup/photo',
      builder: (_, s) => photo ?? SignupPhotoScreen(next: s.uri.queryParameters['next'] ?? '/'),
    ),
  ],
);

void main() {
  test('Driver lands on Drive; anything else on the map', () {
    expect(signupLanding('driver'), '/drive');
    expect(signupLanding('passenger'), '/');
    expect(signupLanding(null), '/');
  });

  group('new account', () {
    Future<void> pump(WidgetTester tester, Map<String, dynamic> profile, _FakeAccount account) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authRepositoryProvider.overrideWithValue(_FakeAuth()),
            accountRepositoryProvider.overrideWithValue(account),
            profileProvider.overrideWith((ref) async => Profile(profile)),
          ],
          child: MaterialApp.router(routerConfig: _router('/set-pin')),
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

    testWidgets('chooses passenger or driver and is offered the photo step', (tester) async {
      final account = _FakeAccount();
      await pump(tester, {'id': 'me'}, account);
      expect(find.text('Are you a passenger or a driver?'), findsOneWidget);
      await tester.tap(find.text('Driver'));
      await tester.pumpAndSettle();
      await save(tester, name: 'Ali');
      expect(account.names, ['Ali']);
      expect(find.text('Add a profile photo'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(find.text('drive'), findsOneWidget);
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
                pickPhoto: (_) async {
                  profile = {...profile, 'avatar_url': 'https://example.com/a.png'};
                  return (bytes: Uint8List(10), name: 'me.png', ext: 'png', contentType: 'image/png');
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

      await tester.tap(find.text('Choose photo'));
      await tester.pump();
      await tester.pump();
      expect(account.uploads, ['png']);
      expect(find.text('Change photo'), findsOneWidget);
      expect(cont().onPressed, isNotNull);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('drive'), findsOneWidget);
    });
  });
}
