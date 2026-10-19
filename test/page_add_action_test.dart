// Web round 40 (180-182): a page's "Add …" floats over its list on a phone
// and is an app-bar action from 600 wide; the list keeps room for it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/widgets/page_add_action.dart';

void main() {
  for (final dark in [false, true]) {
    for (final size in const [Size(360, 640), Size(599, 800), Size(600, 800), Size(915, 412)]) {
      testWidgets('Add at ${size.width.toInt()}x${size.height.toInt()} (${dark ? 'dark' : 'light'})', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var taps = 0;
        late double bottom;
        final add = PageAddAction(key: const ValueKey('add'), onPressed: () => taps++, label: const Text('Add thing'));
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
          home: Builder(builder: (context) {
            bottom = addActionListBottomPadding(context);
            return Scaffold(
              appBar: AppBar(title: const Text('Things'), actions: pageAddActions(context, add)),
              floatingActionButton: pageAddFab(context, add),
              body: ListView(padding: EdgeInsets.only(bottom: bottom), children: [
                for (var i = 0; i < 30; i++) ListTile(title: Text('Row $i')),
              ]),
            );
          }),
        ));
        final wide = size.width >= 600;
        expect(find.byType(FloatingActionButton), wide ? findsNothing : findsOneWidget);
        expect(find.descendant(of: find.byType(AppBar), matching: find.byKey(const ValueKey('add'))),
            wide ? findsOneWidget : findsNothing);
        expect(bottom, wide ? 16 : greaterThanOrEqualTo(56 + 16));
        await tester.tap(find.byKey(const ValueKey('add')));
        expect(taps, 1);
        if (!wide) {
          // Scrolled to the end, the last row stands clear of the button.
          await tester.drag(find.byType(ListView), const Offset(0, -5000));
          await tester.pumpAndSettle();
          final fab = tester.getRect(find.byType(FloatingActionButton));
          expect(tester.getRect(find.text('Row 29')).bottom, lessThanOrEqualTo(fab.top));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
