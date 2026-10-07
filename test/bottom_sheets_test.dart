// Every bottom sheet: rounded top corners and a handle to drag it by.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/widgets/map_sheet_layout.dart';

void main() {
  test('both app themes give every bottom sheet rounded top corners and a drag handle', () {
    for (final b in Brightness.values) {
      final s = appTheme(b).bottomSheetTheme;
      expect(s.showDragHandle, isTrue);
      expect(s.shape, const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))));
    }
  });

  testWidgets('a modal sheet opens rounded, with a handle, and drags down to close', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => const SizedBox(height: 200, child: Center(child: Text('SHEET'))),
            ),
            child: const Text('OPEN'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.enableDrag, isTrue);
    expect(find.bySemanticsLabel('Dismiss'), findsWidgets, reason: 'the drag handle');
    final material = tester.widget<Material>(
      find.descendant(of: find.byType(BottomSheet), matching: find.byType(Material)).first,
    );
    expect(material.shape, appBottomSheetTheme.shape);

    await tester.drag(find.text('SHEET'), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text('SHEET'), findsNothing);
  });

  testWidgets('the map sheet drags up over the map', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapSheetLayout(
            map: const ColoredBox(
              color: Colors.green,
              child: SizedBox.expand(key: ValueKey('map')),
            ),
            sheet: Column(children: [for (var i = 0; i < 30; i++) ListTile(title: Text('row $i'))]),
          ),
        ),
      ),
    );
    final handle = find.byKey(const ValueKey('map-sheet-handle'));
    final mapHeight = tester.getSize(find.byKey(const ValueKey('map'))).height;
    final before = tester.getTopLeft(handle).dy;
    await tester.drag(find.text('row 0'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(handle).dy, lessThan(before - 150));
    expect(
      tester.getSize(find.byKey(const ValueKey('map'))).height,
      lessThan(mapHeight),
      reason: 'the map keeps to the space above the sheet',
    );
  });
}
