import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/picked_contact.dart';
import 'package:get_ride/src/data/account_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/profile/emergency_contacts_screen.dart';
import 'package:get_ride/src/providers.dart';

class _FakeAccount implements AccountRepository {
  final saved = <String>[];

  @override
  Future<List<EmergencyContact>> emergencyContacts() async => const [];

  @override
  Future<void> saveEmergencyContact({String? id, required String name, required String phone}) async =>
      saved.add('$name|$phone');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a picked contact fills the name and the chosen number, cleaned', () {
    expect(pickedContact(fullName: ' Aina Rahman ', selected: '+60 12-345 6789'), (
      name: 'Aina Rahman',
      phone: '+60123456789',
    ));
    expect(pickedContact(fullName: 'Ali', numbers: ['', '(03) 2111 2222', '012']), (name: 'Ali', phone: '0321112222'));
    expect(pickedContact(fullName: '  ', numbers: const []), (name: null, phone: null));
    expect(pickedContact(selected: 'abc', numbers: ['+6012']), (name: null, phone: '+6012'));
  });

  Future<_FakeAccount> pump(WidgetTester tester, Future<PickedContact?> Function()? picker) async {
    final account = _FakeAccount();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(account),
          contactPickerProvider.overrideWithValue(picker),
        ],
        child: const MaterialApp(home: EmergencyContactsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add contact'));
    await tester.pumpAndSettle();
    return account;
  }

  testWidgets('picking from the phone fills the form, which saves as usual', (tester) async {
    final account = await pump(tester, () async => (name: 'Aina', phone: '+60123456789'));
    await tester.tap(find.byKey(const ValueKey('contact-pick')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Aina'), findsOneWidget);
    expect(find.widgetWithText(TextField, '+60123456789'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(account.saved, ['Aina|+60123456789']);
  });

  testWidgets('a contact without a number says so and keeps the form open', (tester) async {
    await pump(tester, () async => (name: 'Ali', phone: null));
    await tester.tap(find.byKey(const ValueKey('contact-pick')));
    await tester.pump();
    expect(find.text('The selected contact has no phone number.'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Ali'), findsOneWidget);
  });

  testWidgets('no picker on this platform, no button', (tester) async {
    await pump(tester, null);
    expect(find.byKey(const ValueKey('contact-pick')), findsNothing);
  });
}
