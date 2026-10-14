// Pairing (migration 0190): the code typed once, the key kept, no sign-in.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getride_gateway/src/app.dart';
import 'package:getride_gateway/src/pair_screen.dart';
import 'package:getride_gateway/src/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final b in Brightness.values) {
    testWidgets('the code goes to pairing once it is whole, and a refusal is shown (${b.name})', (tester) async {
      final tried = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: gatewayTheme(b),
          home: PairScreen(
            pair: (code) async {
              tried.add(code);
              return 'That code is wrong or has expired.';
            },
          ),
        ),
      );
      final button = find.byKey(const ValueKey('pair-submit'));
      await tester.enterText(find.byKey(const ValueKey('pair-code')), 'abcd-234');
      await tester.pump();
      expect(tester.widget<FilledButton>(button).onPressed, isNull, reason: 'not a whole code yet');
      await tester.enterText(find.byKey(const ValueKey('pair-code')), 'abcd-2345');
      await tester.pump();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(tried, ['abcd-2345']);
      expect(find.text('That code is wrong or has expired.'), findsOneWidget);
    });
  }

  test('the device key is kept until the phone is unpaired', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await GatewaySettings.load();
    expect(settings.paired, isFalse);
    settings.gatewayKey = 'k' * 64;
    expect((await GatewaySettings.load()).paired, isTrue);
    settings.gatewayKey = null;
    expect((await GatewaySettings.load()).gatewayKey, isNull);
  });
}
