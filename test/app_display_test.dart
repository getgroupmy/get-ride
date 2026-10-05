import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/features/auth/phone_screen.dart';
import 'package:get_ride/src/providers.dart';

class _Auth implements AuthRepository {
  _Auth({required this.hasProfile});
  final bool hasProfile;
  final otps = <String>[];

  @override
  Future<PhoneLookup> lookupPhone(String phone) async =>
      PhoneLookup(hasProfile: hasProfile, hasPin: false, isDeleted: false);

  @override
  Future<void> sendOtp(String phone) async => otps.add(phone);

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
      }
    });

    test('reads the admin switches, tolerating stored spellings', () {
      final d = AppDisplay.fromSettings({
        'serviceEnabled': false,
        'registrationEnabled': 'false',
        'showAiTollCharges': 0,
        'rcBackVertical': 12,
      });
      expect(d.serviceEnabled, isFalse);
      expect(d.registrationEnabled, isFalse);
      expect(d.showAiTollCharges, isFalse);
      expect(AppDisplay.fromSettings({'serviceEnabled': 'nonsense'}).serviceEnabled, isTrue);
    });

    test('closed registration only stops numbers with no account', () {
      const closed = AppDisplay(registrationEnabled: false);
      expect(mayContinueSignIn(hasAccount: true, display: closed), isTrue);
      expect(mayContinueSignIn(hasAccount: false, display: closed), isFalse);
      expect(mayContinueSignIn(hasAccount: false, display: const AppDisplay()), isTrue);
    });
  });

  Future<_Auth> pumpPhone(WidgetTester tester, {required bool hasProfile, required bool open}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1400);
    addTearDown(tester.view.reset);
    final auth = _Auth(hasProfile: hasProfile);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceBlockedProvider.overrideWith((ref) async => false),
          authRepositoryProvider.overrideWithValue(auth),
          appDisplayProvider.overrideWith((ref) async => AppDisplay(registrationEnabled: open)),
        ],
        child: const MaterialApp(home: PhoneScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456789');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return auth;
  }

  testWidgets('a new number is refused while registration is closed', (tester) async {
    final auth = await pumpPhone(tester, hasProfile: false, open: false);
    expect(auth.otps, isEmpty);
    expect(find.text(registrationClosedMessage), findsOneWidget);
  });

  testWidgets('an existing account still gets its code while registration is closed', (tester) async {
    final auth = await pumpPhone(tester, hasProfile: true, open: false);
    expect(auth.otps, hasLength(1));
  });
}
