// The side menus' buttons follow the app's theme accent, not a colour of
// their own.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show brandAccent;
import 'package:get_ride/src/widgets/side_menu_style.dart';

void main() {
  test('the menu button colour is the theme accent', () {
    expect(SideMenuStyle.button, brandAccent);
  });

  testWidgets('the mode button at the foot is filled with the accent', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SideMenuFrame(
          rows: const [],
          buttonLabel: 'Partner Mode',
          buttonKey: const ValueKey('mode'),
          onButton: () {},
        ),
      ),
    ));
    final style = tester.widget<FilledButton>(find.byKey(const ValueKey('mode'))).style!;
    expect(style.backgroundColor!.resolve({}), brandAccent);
    expect(style.foregroundColor!.resolve({}), Colors.white);
  });
}
