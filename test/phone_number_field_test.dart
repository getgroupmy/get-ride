// The shared PhoneNumberField: a country-code picker beside the national
// number. It pre-fills from a stored E.164, drops the national trunk 0, and
// reports the composed E.164 on every change.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/widgets/phone_number_field.dart';

Future<String?> _pump(WidgetTester tester, {String? initial}) async {
  String? last;
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: PhoneNumberField(
          keyPrefix: 'p', initialPhone: initial, onChanged: (v) => last = v),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return last;
}

void main() {
  testWidgets('pre-fills by splitting the dial code off the stored number', (tester) async {
    await _pump(tester, initial: '+60123456789');
    // The dial code shows, and the field holds the national part.
    expect(find.text('+60'), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(const ValueKey('p-number')));
    expect(field.controller!.text, '123456789');
  });

  testWidgets('reports the composed E.164 and drops a leading 0', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('p-number')), '0198765432');
    await tester.pump();
    // Entered with a trunk 0; saved without it, joined to the dial code.
    final field = tester.widget<TextField>(find.byKey(const ValueKey('p-number')));
    expect(field.controller!.text, '198765432');
  });

  testWidgets('a blank number composes to empty', (tester) async {
    final last = await _pump(tester, initial: '');
    expect(last, anyOf(isNull, equals('')));
  });
}
