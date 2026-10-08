// "Who's riding?": the passenger can be picked from the contacts, where the
// phone or browser offers a picker, and is typed in otherwise.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/book_for.dart';
import 'package:get_ride/src/features/profile/emergency_contacts_screen.dart';
import 'package:get_ride/src/features/ride/book_for_sheet.dart';

/// Pumps a page, opens the sheet over it and hands back what it will return.
Future<Future<BookedFor?>> _open(WidgetTester tester, Future<PickedContact?> Function()? picker) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [contactPickerProvider.overrideWithValue(picker)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    ),
  );
  final result = showBookForSheet(ctx);
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('choose from contacts fills in the name and phone', (tester) async {
    final opened = await _open(tester, () async => (name: 'Mak Siti', phone: '+60123456789'));
    expect(find.text('Choose from contacts'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('book-for-contact')));
    await tester.pumpAndSettle();
    expect(find.text('Mak Siti'), findsOneWidget);
    expect(find.text('+60123456789'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('book-for-done')));
    await tester.pumpAndSettle();
    final r = await opened;
    expect(r?.name, 'Mak Siti');
  });

  testWidgets('a contact without a number says so and leaves the phone to type', (tester) async {
    await _open(tester, () async => (name: 'Ali', phone: null));
    await tester.tap(find.byKey(const ValueKey('book-for-contact')));
    await tester.pumpAndSettle();
    expect(find.text('Ali'), findsOneWidget);
    expect(find.text('That contact has no phone number.'), findsOneWidget);
  });

  testWidgets('no picker (a browser without one): no button, just the fields', (tester) async {
    await _open(tester, null);
    expect(find.byKey(const ValueKey('book-for-contact')), findsNothing);
    expect(find.byKey(const ValueKey('book-for-name')), findsOneWidget);
  });
}
