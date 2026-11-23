import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/drop_change.dart' show DropChangeKind;
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

  // The passenger's review before sending a change: the fare and whether the
  // driver is asked are the server's (0437).
  Future<void> pumpReview(WidgetTester tester, {required double oldFare, required double newFare, required DropChangeKind kind}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DropChangeReviewDialog(
              oldLabel: 'Mid Valley',
              newLabel: 'Pavilion KL',
              oldFare: oldFare,
              newFare: newFare,
              fareText: (v) => 'RM${(v ?? 0).toStringAsFixed(2)}',
              kind: kind,
            ),
          ),
        ),
      );

  testWidgets('DropChangeReviewDialog shows both fares and that a change applies at once', (tester) async {
    await pumpReview(tester, oldFare: 20, newFare: 9.05, kind: DropChangeKind.instant);

    expect(find.text('Pavilion KL'), findsOneWidget);
    expect(find.text('was Mid Valley'), findsOneWidget);
    expect(find.text('RM20.00'), findsOneWidget); // old, struck through
    expect(find.text('RM9.05'), findsOneWidget); // new
    expect(find.text('−RM10.95'), findsOneWidget); // delta
    expect(find.text('This applies straight away.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Change drop-off'), findsOneWidget);
    expect(find.byKey(const ValueKey('drop-change-review-cancel')), findsOneWidget);
  });

  testWidgets('DropChangeReviewDialog says when the driver has to accept the new fare', (tester) async {
    await pumpReview(tester, oldFare: 20, newFare: 35, kind: DropChangeKind.needsDriver);

    expect(find.text('RM20.00'), findsOneWidget);
    expect(find.text('RM35.00'), findsOneWidget);
    expect(find.text('+RM15.00'), findsOneWidget);
    expect(find.text('Your driver needs to accept the new drop-off and fare first.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Request change'), findsOneWidget);
  });

  testWidgets('DropChangeReviewDialog shows the one fare when it stays as it is', (tester) async {
    await pumpReview(tester, oldFare: 20, newFare: 20, kind: DropChangeKind.needsDriver);

    expect(find.text('RM20.00'), findsOneWidget); // once: nothing struck through
    expect(find.byIcon(Icons.arrow_forward), findsNothing);
    expect(find.text('+RM0.00'), findsNothing);
    expect(find.text('The fare stays the same. Your driver needs to accept the new drop-off first.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Request change'), findsOneWidget);

    await pumpReview(tester, oldFare: 20, newFare: 20, kind: DropChangeKind.instant);
    expect(find.text('The fare stays the same. This applies straight away.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Change drop-off'), findsOneWidget);
  });
}
