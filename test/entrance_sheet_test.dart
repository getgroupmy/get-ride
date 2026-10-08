// "Set entrance" (inDrive's): a phone keypad under the number and Done.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart';

void main() {
  for (final b in Brightness.values) {
    testWidgets('typing, deleting and Done; the keys carry their letters ($b)', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: b),
          home: Scaffold(
            body: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      final result = showEntranceSheet(ctx, '');
      await tester.pumpAndSettle();
      expect(find.text('ABC'), findsOneWidget);
      expect(find.text('WXYZ'), findsOneWidget);
      for (final k in ['1', '2', '3']) {
        await tester.tap(find.byKey(ValueKey('entrance-key-$k')));
      }
      await tester.tap(find.byKey(const ValueKey('entrance-key-back')));
      await tester.pump();
      expect(
        find.descendant(of: find.byKey(const ValueKey('entrance-value')), matching: find.text('12')),
        findsOneWidget,
      );
      // Done sits above the keypad, as inDrive's.
      expect(
        tester.getRect(find.byKey(const ValueKey('entrance-done'))).bottom,
        lessThan(tester.getRect(find.byKey(const ValueKey('entrance-keypad'))).top),
      );
      await tester.tap(find.byKey(const ValueKey('entrance-done')));
      await tester.pumpAndSettle();
      expect(await result, '12');
    });
  }

  testWidgets('the round close leaves it as it was', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final result = showEntranceSheet(ctx, '7');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('entrance-close')));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });
}
