import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/fare_offer.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart';
import 'package:get_ride/src/features/ride/fare_offer_controls.dart';
import 'package:get_ride/src/widgets/shake.dart';

String rm(double v) => 'RM ${v.toStringAsFixed(2)}';

void main() {
  group('rules', () {
    test('the keypad band is 70% to 400% of the recommended fare', () {
      expect(fareOfferRange(20), (min: 14.0, max: 80.0));
      expect(fareOfferRange(13), (min: 9.0, max: 52.0));
    });

    test('buttons step by 5 between 10 below and 20 above', () {
      expect(stepFareAdjustment(40, 0, 5), 5);
      expect(stepFareAdjustment(40, 20, 5), isNull);
      expect(stepFareAdjustment(40, -10, -5), isNull);
      expect(stepFareAdjustment(40, -5, -5), -10);
    });

    test('buttons never leave the 70% floor on a cheap trip', () {
      // RM 12 recommended: the floor is RM 8, so −5 (RM 7) is refused.
      expect(stepFareAdjustment(12, 0, -5), isNull);
      // Back to the recommended fare is always allowed.
      expect(stepFareAdjustment(30, -5, 5), 0);
    });

    test('typed offers name the limit they break', () {
      expect(fareOfferProblem(null, 20, rm), 'Enter your fare');
      expect(fareOfferProblem(13, 20, rm), 'Minimum fare is RM 14.00');
      expect(fareOfferProblem(81, 20, rm), 'Maximum fare is RM 80.00');
      expect(fareOfferProblem(14, 20, rm), isNull);
      expect(fareOfferProblem(80, 20, rm), isNull);
    });

    test('the offer only counts where bidding is on', () {
      expect(offeredFare(recommended: 20, adjust: 5, biddingOn: true), 25);
      expect(offeredFare(recommended: 20, adjust: 5, biddingOn: false), 20);
      expect(offeredFare(recommended: 4, adjust: -10, biddingOn: true), 0);
    });
  });

  group('controls', () {
    Future<List<double>> pump(WidgetTester tester, {double recommended = 20, double adjust = 0}) async {
      final changes = <double>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) => FareOfferRow(
                recommended: recommended,
                adjust: adjust,
                money: rm,
                onAdjust: (v) => setState(() {
                  changes.add(v);
                  adjust = v;
                }),
              ),
            ),
          ),
        ),
      );
      return changes;
    }

    testWidgets('+ and − move the offer and show the recommended fare', (tester) async {
      final changes = await pump(tester);
      expect(find.text('RM 20.00'), findsOneWidget);
      expect(find.textContaining('Recommended fare ·'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fare-raise')));
      await tester.pump();
      expect(changes, [5]);
      expect(find.text('RM 25.00'), findsOneWidget);
      expect(find.text('Recommended fare: RM 20.00'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fare-lower')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fare-lower')));
      await tester.pump();
      expect(changes, [5, 0, -5]);
    });

    testWidgets('a step past the limit says why and changes nothing', (tester) async {
      final changes = await pump(tester, recommended: 12);
      await tester.tap(find.byKey(const ValueKey('fare-lower')));
      await tester.pump();
      expect(changes, isEmpty);
      expect(find.text('Minimum fare is RM 8.00'), findsOneWidget);
    });

    testWidgets('typing an offer: limits named, Set fare applies it', (tester) async {
      final changes = await pump(tester);
      await tester.tap(find.text('RM 20.00'));
      await tester.pumpAndSettle();
      expect(find.text('Offer your fare'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('fare-offer-field')), '90');
      await tester.pump();
      expect(find.text('Maximum fare is RM 80.00'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Set fare')).onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('fare-offer-field')), '33');
      await tester.pump();
      await tester.tap(find.text('Set fare'));
      await tester.pumpAndSettle();
      expect(changes, [13]);
      expect(find.text('RM 33.00'), findsOneWidget);
    });

    testWidgets('Use recommended fare clears the offer', (tester) async {
      final changes = await pump(tester, adjust: 10);
      await tester.tap(find.text('RM 30.00'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use recommended fare'));
      await tester.pumpAndSettle();
      expect(changes, [0]);
    });
  });

  testWidgets('on the confirm sheet a step past the limit shakes the chosen card, with no note', (tester) async {
    final changes = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConfirmServiceCard(
            service: const RideService('Car', '', 1, 4),
            price: 'RM 12.00',
            selected: true,
            onTap: () {},
            fare: ConfirmFareSection(
              recommended: 12,
              adjust: 0,
              money: rm,
              bidding: true,
              onAdjust: changes.add,
            ),
          ),
        ),
      ),
    );
    final card = find.byKey(const ValueKey('service-Car'));
    final top = find.byKey(const ValueKey('service-card-top'));
    final x = tester.getTopLeft(card).dx;
    // The inner card's place inside the tray, at rest.
    final inset = tester.getTopLeft(top).dx - x;
    double inner() => tester.getTopLeft(top).dx - tester.getTopLeft(card).dx - inset;
    await tester.tap(find.byKey(const ValueKey('fare-lower')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.getTopLeft(card).dx, closeTo(x + 8, 0.5), reason: 'shaken 8 to the right first, as Expo');
    expect(inner(), closeTo(-4, 0.5), reason: 'the inner card swings the other way');
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.getTopLeft(card).dx, closeTo(x - 8, 0.5));
    expect(inner(), closeTo(4, 0.5));
    // Never out of the tray: within its 5 px padding all the way through.
    for (var i = 0; i < 6; i++) {
      expect(inner().abs(), lessThanOrEqualTo(4.01));
      expect(tester.getRect(top).left, greaterThan(tester.getRect(card).left));
      expect(tester.getRect(top).right, lessThan(tester.getRect(card).right));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(card).dx, x, reason: 'and back in place');
    expect(inner(), 0);
    expect(changes, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining('Minimum fare'), findsNothing);
  });

  test('a counter-shake goes the other way, never past its travel', () {
    expect(ShakeCounter.counter(8, 4), -4);
    expect(ShakeCounter.counter(-6, 4), 3);
    expect(ShakeCounter.counter(0, 4), 0);
    expect(ShakeCounter.counter(40, 4), -4);
  });
}
