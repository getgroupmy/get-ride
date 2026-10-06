import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/auth_utils.dart';
import 'package:get_ride/src/core/phone_input.dart';

void main() {
  test('a leading 0 is dropped, the rest kept', () {
    expect(withoutTrunkZero('0123456789'), '123456789');
    expect(withoutTrunkZero(' 012 345 6789'), '12 345 6789');
    expect(withoutTrunkZero('00123'), '123');
    expect(withoutTrunkZero('123406789'), '123406789');
    expect(withoutTrunkZero('0'), '');
    expect(composePhone('+60', withoutTrunkZero('0123456789')), '+60123456789');
  });

  testWidgets('the field drops a 0 typed or pasted first', (tester) async {
    final c = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            controller: c,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d\s-]')), const NoTrunkZeroFormatter()],
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '0');
    expect(c.text, '');
    await tester.enterText(find.byType(TextField), '0123456789');
    expect(c.text, '123456789');
    expect(c.selection.baseOffset, 9);
    await tester.enterText(find.byType(TextField), '1023');
    expect(c.text, '1023');
  });
}
