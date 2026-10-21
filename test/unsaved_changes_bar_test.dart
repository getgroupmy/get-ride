import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/geo/airport_editor.dart';
import 'package:get_ride/src/app.dart';

void main() {
  for (final b in Brightness.values) {
    testWidgets('the unsaved-changes bar reads on one line with Save showing (${b.name})', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var saved = false;
      await tester.pumpWidget(MaterialApp(
        theme: appTheme(b),
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Expanded(child: SizedBox()),
              UnsavedChangesBar(saving: false, onDiscard: () {}, onSave: () => saved = true),
            ],
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      final label = tester.getSize(find.text('Unsaved changes'));
      expect(label.height, lessThan(30), reason: 'one line, not a letter a line');
      final save = find.byKey(const ValueKey('airport-settings-save'));
      expect(tester.getSize(save).width, lessThan(200));
      expect(tester.getRect(save).right, lessThanOrEqualTo(1400));
      await tester.tap(save);
      expect(saved, isTrue);
    });
  }
}
