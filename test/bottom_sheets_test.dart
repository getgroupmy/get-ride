// Every bottom sheet: rounded top corners and a handle to drag it by.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
            map: Builder(
              builder: (context) => Stack(
                children: [
                  const ColoredBox(
                    color: Colors.green,
                    child: SizedBox.expand(key: ValueKey('map')),
                  ),
                  MapBottomInset.listen(
                    context,
                    (inset) => Positioned(
                      right: 12,
                      bottom: 12 + inset,
                      child: const SizedBox(key: ValueKey('map-button'), width: 40, height: 40),
                    ),
                  ),
                ],
              ),
            ),
            sheet: Column(children: [for (var i = 0; i < 30; i++) ListTile(title: Text('row $i'))]),
          ),
        ),
      ),
    );
    final handle = find.byKey(const ValueKey('map-sheet-handle'));
    final map = find.byKey(const ValueKey('map'));
    final button = find.byKey(const ValueKey('map-button'));
    final screen = tester.getSize(find.byType(MapSheetLayout));
    expect(tester.getSize(map), screen, reason: 'the map fills the screen, the sheet floats over it');
    final before = tester.getTopLeft(handle).dy;
    expect(tester.getBottomLeft(button).dy, lessThan(before), reason: "the map's buttons sit above the sheet");
    await tester.drag(find.text('row 0'), const Offset(0, -100));
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(handle).dy;
    expect(after, lessThan(before - 60));
    expect(tester.getSize(map), screen, reason: 'the map stays put under the sheet');
    expect(tester.getBottomLeft(button).dy, lessThan(after), reason: 'and its buttons follow the sheet up');
  });

  testWidgets('the handle stays at the top of the sheet while its content scrolls', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapSheetLayout(
            map: const SizedBox.expand(),
            sheet: Column(children: [for (var i = 0; i < 40; i++) ListTile(title: Text('row $i'))]),
          ),
        ),
      ),
    );
    final sheet = find.byKey(const ValueKey('map-sheet'));
    // Up to full height, then scroll the content in a second gesture.
    await tester.drag(find.text('row 0'), const Offset(0, -600));
    await tester.pumpAndSettle();
    final handleTop = tester.getTopLeft(find.byKey(const ValueKey('map-sheet-handle'))).dy;
    final sheetTop = tester.getTopLeft(find.descendant(of: sheet, matching: find.byType(Material)).first).dy;
    final rowTop = tester.getTopLeft(find.text('row 3')).dy;
    await tester.drag(find.text('row 3'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('row 3')).dy, lessThan(rowTop - 200), reason: 'the content scrolled');
    expect(tester.getTopLeft(find.byKey(const ValueKey('map-sheet-handle'))).dy, handleTop, reason: 'the handle did not');
    expect(handleTop - sheetTop, lessThan(20), reason: 'it sits on the top edge');
  });

  testWidgets('all the way down the sheet bounces, not its content; a wheel moves the sheet', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS; // bouncing by default
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapSheetLayout(
            // Something on the sheet's top edge (the promo bar, the back
            // button) placed by the inset.
            map: Builder(
              builder: (c) => MapBottomInset.listen(
                c,
                (inset) => Stack(children: [
                  Positioned(
                    left: 0,
                    bottom: inset,
                    child: const SizedBox(key: ValueKey('on-sheet-top'), width: 10, height: 10),
                  ),
                ]),
              ),
            ),
            initial: 0.2,
            sheet: Column(children: [for (var i = 0; i < 40; i++) ListTile(title: Text('row $i'))]),
          ),
        ),
      ),
    );
    final row = find.text('row 0');
    final handle = find.byKey(const ValueKey('map-sheet-handle'));
    final top = tester.getTopLeft(row).dy;
    final handleTop = tester.getTopLeft(handle).dy;
    final markTop = tester.getBottomLeft(find.byKey(const ValueKey('on-sheet-top'))).dy;
    // Pulled down when it can go no lower: the SHEET rubber-bands (with
    // resistance), its content doesn't scroll inside it, and it springs back.
    final g = await tester.startGesture(tester.getCenter(row));
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(0, 20));
      await tester.pump();
    }
    final pulled = tester.getTopLeft(handle).dy - handleTop;
    expect(pulled, greaterThan(20), reason: 'the sheet gives');
    expect(tester.getBottomLeft(find.byKey(const ValueKey('on-sheet-top'))).dy - markTop, closeTo(pulled, 0.5),
        reason: 'what sits on the sheet goes down with it');
    expect(pulled, lessThan(160), reason: 'with resistance');
    expect(tester.getTopLeft(row).dy - tester.getTopLeft(handle).dy, closeTo(top - handleTop, 0.5),
        reason: 'the content moves with the sheet, not inside it');
    await g.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(handle).dy, closeTo(handleTop, 0.5), reason: 'it springs back');
    expect(tester.getBottomLeft(find.byKey(const ValueKey('on-sheet-top'))).dy, closeTo(markTop, 0.5),
        reason: 'and springs back with it');
    expect(tester.getTopLeft(row).dy, closeTo(top, 0.5));

    // A wheel over it raises the sheet rather than scrolling the content.
    final before = tester.getTopLeft(handle).dy;
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(p.hover(tester.getCenter(row)));
    await tester.sendEventToBinding(p.scroll(const Offset(0, 200)));
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(handle).dy;
    expect(after, lessThan(before - 150), reason: 'the sheet rose');
    expect(tester.getTopLeft(row).dy - after, closeTo(top - before, 1), reason: 'its content did not scroll');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the chosen item is scrolled whole above the pinned footer, and kept there', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var chosen = 6;
    late StateSetter set;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              set = setState;
              return MapSheetLayout(
                map: const SizedBox.expand(),
                initial: 0.5,
                min: 0.5,
                footer: const SizedBox(height: 150, width: double.infinity),
                sheet: Column(children: [
                  for (var i = 0; i < 12; i++)
                    i == chosen
                        ? MapSheetReveal(child: SizedBox(key: ValueKey('item-$i'), height: 120))
                        : SizedBox(key: ValueKey('item-$i'), height: 60),
                ]),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    const footerTop = 800 - 150.0;
    double bottomOf(int i) => tester.getBottomLeft(find.byKey(ValueKey('item-$i'))).dy;
    double handle() => tester.getBottomLeft(find.byKey(const ValueKey('map-sheet-handle'))).dy;
    expect(bottomOf(6), lessThanOrEqualTo(footerTop), reason: 'not hidden behind the footer');
    expect(tester.getTopLeft(find.byKey(const ValueKey('item-6'))).dy, greaterThan(handle()));

    // Another chosen: that one is brought into view.
    set(() => chosen = 9);
    await tester.pumpAndSettle();
    expect(bottomOf(9), lessThanOrEqualTo(footerTop));
    expect(tester.getTopLeft(find.byKey(const ValueKey('item-9'))).dy, greaterThan(handle()));

    // Dragged to a new height: still whole.
    await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(handle(), lessThan(400), reason: 'the sheet rose');
    expect(bottomOf(9), lessThanOrEqualTo(footerTop));
    expect(tester.getTopLeft(find.byKey(const ValueKey('item-9'))).dy, greaterThan(handle()));

    // And back down, by the content: a drag still moves the sheet.
    await tester.drag(find.byKey(const ValueKey('item-9')), const Offset(0, 150));
    await tester.pumpAndSettle();
    expect(handle(), greaterThan(405), reason: 'the sheet went down');
    expect(bottomOf(9), lessThanOrEqualTo(footerTop));
    expect(tester.getTopLeft(find.byKey(const ValueKey('item-9'))).dy, greaterThan(handle()));
  });

  testWidgets('choosing anew brings a raised sheet down and shows the choice whole above the footer', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    var chosen = 1;
    late StateSetter set;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              set = setState;
              return MapSheetLayout(
                map: const SizedBox.expand(),
                initial: 0.5,
                min: 0.5,
                footer: const SizedBox(height: 150, width: double.infinity),
                sheet: Column(children: [
                  for (var i = 0; i < 12; i++)
                    i == chosen
                        ? MapSheetReveal(child: SizedBox(key: ValueKey('item-$i'), height: 120))
                        : SizedBox(key: ValueKey('item-$i'), height: 60),
                ]),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    double handle() => tester.getBottomLeft(find.byKey(const ValueKey('map-sheet-handle'))).dy;
    final lowest = handle();
    // Raised by hand.
    await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(handle(), lessThan(lowest - 100));

    // A vehicle chosen: down it comes, the choice whole just above the footer.
    set(() => chosen = 8);
    await tester.pumpAndSettle();
    expect(handle(), closeTo(lowest, 2), reason: 'back at its lowest');
    const footerTop = 800 - 150.0;
    final card = tester.getRect(find.byKey(const ValueKey('item-8')));
    expect(card.bottom, lessThanOrEqualTo(footerTop));
    expect(card.top, greaterThan(handle()));
    // The ones before it are pushed up out of the way.
    expect(tester.getRect(find.byKey(const ValueKey('item-1'))).bottom, lessThan(handle()));
  });
}
