// Controls that show they are working: a spinner while the action runs,
// and no second action until it is done.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/widgets/busy.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  testWidgets('a button spins while its action runs and takes no second tap', (tester) async {
    final done = Completer<void>();
    var taps = 0;
    await _pump(
      tester,
      BusyButton.filled(
        onPressed: () {
          taps++;
          return done.future;
        },
        child: const Text('Save'),
      ),
    );
    final width = tester.getSize(find.byType(FilledButton)).width;
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(find.byKey(const ValueKey('busy-spinner')), findsOneWidget);
    expect(tester.getSize(find.byType(FilledButton)).width, width, reason: 'keeps its size');
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    await tester.pump();
    expect(taps, 1, reason: 'no duplicate');
    done.complete();
    await tester.pump();
    expect(find.byKey(const ValueKey('busy-spinner')), findsNothing);
    await tester.tap(find.byType(FilledButton));
    expect(taps, 2, reason: 'usable again once done');
  });

  testWidgets('a synchronous action never shows a spinner', (tester) async {
    var taps = 0;
    await _pump(tester, BusyButton.outlined(onPressed: () => taps++, child: const Text('Close')));
    await tester.tap(find.byType(OutlinedButton));
    await tester.pump();
    expect(taps, 1);
    expect(find.byKey(const ValueKey('busy-spinner')), findsNothing);
  });

  testWidgets('a failed action still frees the button', (tester) async {
    await _pump(tester, BusyButton.text(onPressed: () => Future<void>.error('offline'), child: const Text('Retry')));
    await tester.tap(find.byType(TextButton));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), 'offline');
    expect(find.byKey(const ValueKey('busy-spinner')), findsNothing);
    expect(tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNotNull);
  });

  testWidgets('a switch row spins until the change is saved', (tester) async {
    final saved = Completer<void>();
    var value = false;
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => BusySwitchListTile(
              value: value,
              secondary: const Icon(Icons.wifi),
              title: const Text('Online'),
              onChanged: (v) async {
                changes.add(v);
                await saved.future;
                setState(() => value = v);
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Online'));
    await tester.pump();
    expect(find.byKey(const ValueKey('busy-spinner')), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged, isNull, reason: 'locked while saving');
    await tester.tap(find.text('Online'), warnIfMissed: false);
    expect(changes, [true]);
    saved.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('busy-spinner')), findsNothing);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);
  });

  testWidgets('an icon button and a row spin too', (tester) async {
    final a = Completer<void>(), b = Completer<void>();
    await _pump(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BusyIconButton(onPressed: () => a.future, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
          SizedBox(
            width: 300,
            child: BusyListTile(onTap: () => b.future, title: const Text('Sync'), trailing: const Icon(Icons.sync)),
          ),
        ],
      ),
    );
    await tester.tap(find.byTooltip('Refresh'));
    await tester.tap(find.text('Sync'));
    await tester.pump();
    expect(find.byKey(const ValueKey('busy-spinner')), findsNWidgets(2));
    a.complete();
    b.complete();
    await tester.pump();
    expect(find.byKey(const ValueKey('busy-spinner')), findsNothing);
  });

  testWidgets('a floating button spins while its action runs', (tester) async {
    final done = Completer<void>();
    var taps = 0;
    await _pump(
      tester,
      BusyFab(
        tooltip: 'Meter',
        onPressed: () {
          taps++;
          return done.future;
        },
        child: const Icon(Icons.speed),
      ),
    );
    await tester.tap(find.byTooltip('Meter'));
    await tester.pump();
    expect(find.byKey(const ValueKey('busy-spinner')), findsOneWidget);
    await tester.tap(find.byTooltip('Meter'), warnIfMissed: false);
    expect(taps, 1);
    done.complete();
    await tester.pump();
    expect(find.byIcon(Icons.speed), findsOneWidget);
  });
}
