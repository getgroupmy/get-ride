import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/duo_fold.dart';
import 'package:get_ride/src/core/window_class.dart';
import 'package:get_ride/src/widgets/duo_fold_scope.dart';

void main() {
  testWidgets('a simulated fold reaches windowMetricsFor through MediaQuery', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1200);
    addTearDown(tester.view.reset);
    addTearDown(() => duoFoldSimulation.value = null);

    late WindowMetrics seen;
    await tester.pumpWidget(
      MaterialApp(
        home: DuoFoldScope(
          child: Builder(
            builder: (context) {
              seen = windowMetricsFor(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    expect(seen.hasSeparatingFold, isFalse, reason: 'no fold until one is simulated or reported');

    duoFoldSimulation.value = simulatedBookFold(const Size(1000, 1200));
    await tester.pump();
    expect(seen.hasSeparatingFold, isTrue);
    expect(seen.fold!.vertical, isTrue, reason: 'a book fold is a vertical seam');
    expect(verticalSplitFor(seen), isNotNull);

    // Turning the simulation off restores the plain window.
    duoFoldSimulation.value = null;
    await tester.pump();
    expect(seen.hasSeparatingFold, isFalse);
  });

  testWidgets('without a fold the child is passed straight through', (tester) async {
    addTearDown(() => duoFoldSimulation.value = null);
    await tester.pumpWidget(
      const MaterialApp(home: DuoFoldScope(child: Text('hi', textDirection: TextDirection.ltr))),
    );
    expect(find.text('hi'), findsOneWidget);
  });
}
