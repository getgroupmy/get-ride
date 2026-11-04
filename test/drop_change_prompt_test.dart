import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/widgets/drop_change_prompt.dart';

void main() {
  testWidgets('DropChangeRequestDialog shows the new drop, both fares and the buttons', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DropChangeRequestDialog(
            newAddress: 'Pavilion KL',
            oldFare: 18,
            newFare: 24,
            fareText: (v) => 'RM${(v ?? 0).toStringAsFixed(0)}',
          ),
        ),
      ),
    );

    expect(find.text('Change drop-off?'), findsOneWidget);
    expect(find.text('Pavilion KL'), findsOneWidget);
    expect(find.text('RM18'), findsOneWidget); // old, struck through
    expect(find.text('RM24'), findsOneWidget); // new
    expect(find.text('+RM6'), findsOneWidget); // delta
    expect(find.byKey(const ValueKey('drop-change-accept')), findsOneWidget);
    expect(find.byKey(const ValueKey('drop-change-reject')), findsOneWidget);
  });

  testWidgets('DropChangeRequestDialog omits the fare row when a fare is unknown', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DropChangeRequestDialog(
            newAddress: 'Somewhere',
            oldFare: null,
            newFare: null,
            fareText: (v) => 'RM${(v ?? 0).toStringAsFixed(0)}',
          ),
        ),
      ),
    );
    expect(find.text('Somewhere'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward), findsNothing);
  });
}
