import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/auth_utils.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/settings/change_phone_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

class _FakeAuth implements AuthRepository {
  _FakeAuth({this.taken = false, this.badCode = false});
  final bool taken;
  final bool badCode;
  final calls = <String>[];

  @override
  Future<PhoneLookup> lookupPhone(String phone) async {
    calls.add('lookup $phone');
    return PhoneLookup(hasProfile: taken, hasPin: taken, isDeleted: false);
  }

  @override
  Future<void> requestPhoneChange(String phone) async => calls.add('request $phone');

  @override
  Future<void> confirmPhoneChange(String phone, String code) async {
    calls.add('confirm $phone $code');
    if (badCode) throw const AuthException('Token has expired or is invalid');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('phoneChangeProblem', () {
    expect(phoneChangeProblem('+60123', null, takenByAnother: false), 'Enter a valid phone number.');
    expect(phoneChangeProblem('+60123456789', '60123456789', takenByAnother: false), 'That is already your number.');
    expect(phoneChangeProblem('+60129999999', '60123456789', takenByAnother: true), contains('another account'));
    expect(phoneChangeProblem('+60129999999', '60123456789', takenByAnother: false), isNull);
  });

  Future<_FakeAuth> pump(WidgetTester tester, _FakeAuth auth) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(auth),
          profileProvider.overrideWith((ref) async => Profile({'id': 'me', 'phone': '60123456789'})),
        ],
        child: const MaterialApp(home: ChangePhoneScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return auth;
  }

  testWidgets('sends a code to the new number and confirms it', (tester) async {
    final auth = await pump(tester, _FakeAuth());
    expect(find.text('Current number: +60123456789'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('new-phone')), '0129999999');
    await tester.tap(find.byKey(const ValueKey('change-phone-go')));
    await tester.pumpAndSettle();
    expect(auth.calls, ['lookup +60129999999', 'request +60129999999']);
    expect(find.text('Enter the 6-digit code sent to +60129999999.'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('change-code')), '123456');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('change-phone-go')));
    await tester.pumpAndSettle();
    expect(auth.calls.last, 'confirm +60129999999 123456');
    expect(find.text('Your phone number is now +60129999999.'), findsOneWidget);
  });

  testWidgets('a number held by another account is refused before any code is sent', (tester) async {
    final auth = await pump(tester, _FakeAuth(taken: true));
    await tester.enterText(find.byKey(const ValueKey('new-phone')), '129999999');
    await tester.tap(find.byKey(const ValueKey('change-phone-go')));
    await tester.pumpAndSettle();
    expect(find.text('This number is already linked to another account.'), findsOneWidget);
    expect(auth.calls.where((c) => c.startsWith('request')), isEmpty);
  });

  testWidgets('a wrong code is shown and the number is unchanged', (tester) async {
    final auth = await pump(tester, _FakeAuth(badCode: true));
    await tester.enterText(find.byKey(const ValueKey('new-phone')), '129999999');
    await tester.tap(find.byKey(const ValueKey('change-phone-go')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('change-code')), '000000');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('change-phone-go')));
    await tester.pumpAndSettle();
    expect(find.textContaining('expired or is invalid'), findsOneWidget);
    expect(find.byKey(const ValueKey('change-code')), findsOneWidget);
    expect(auth.calls.last, startsWith('confirm'));
  });
}
