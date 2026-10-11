import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_cancel.dart';
import 'package:get_ride/src/core/search_stage.dart';
import 'package:get_ride/src/features/ride/searching_parts.dart';

SearchOfferView _offer(String key, {double progress = 1}) => SearchOfferView(
  key: key,
  price: 'RM$key',
  yourFare: false,
  progress: progress,
  name: 'Driver $key',
  onAccept: () {},
  onDecline: () {},
  cardKey: ValueKey('card-$key'),
);

void main() {
  test('the headline cycles through the stages', () {
    expect(searchStageAt(Duration.zero).title, 'Searching for drivers');
    expect(searchStageAt(const Duration(seconds: 5)).title, 'Offering your fare');
    expect(searchStageAt(const Duration(seconds: 10)).title, 'Waiting for responses');
    expect(searchStageAt(const Duration(seconds: 15)).title, 'Searching further');
    expect(searchStageAt(const Duration(seconds: 20)).id, 'searching');
    expect(searchStageAt(const Duration(seconds: -3)).id, 'searching');
  });

  test('a fixed-fare request never talks about offers or choosing a driver', () {
    final seen = {for (var s = 0; s < 40; s += 5) searchStageAt(Duration(seconds: s), bidding: false).title};
    expect(seen, {'Searching for drivers', 'Sending your request', 'Searching further'});
    expect(searchStageAt(Duration.zero, bidding: false).id, 'searching');
  });

  test('the stepper never goes under the fare and caps a raise', () {
    expect(stepSearchFare(current: 20, target: 20, step: 5, quoted: 20), 25);
    expect(stepSearchFare(current: 20, target: 25, step: -5, quoted: 20), 20);
    expect(stepSearchFare(current: 20, target: 22, step: -5, quoted: 20), 20);
    expect(stepSearchFare(current: 20, target: 78, step: 5, quoted: 20), 80);
  });

  test('search cancel reasons read back as labels', () {
    expect(cancelReasonLabel('high_fares'), 'High fares');
    expect(searchCancelReasons, hasLength(6));
  });

  double angleOf(WidgetTester tester, String key) {
    final rotate = tester.widget<Transform>(
      find.ancestor(of: find.byKey(ValueKey('card-$key')), matching: find.byType(Transform)).first,
    );
    // The z-rotation of the card's transform.
    return math.atan2(rotate.transform.entry(1, 0), rotate.transform.entry(0, 0));
  }

  Widget host(List<SearchOfferView> offers) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: OfferStack(offers: offers)),
    ),
  );

  testWidgets('offers fly in from the right, tilted, and tilt off to the left', (tester) async {
    await tester.pumpWidget(host([_offer('1')]));
    await tester.pump(const Duration(milliseconds: 80));
    final coming = tester.getTopLeft(find.byKey(const ValueKey('card-1')));
    expect(angleOf(tester, '1'), greaterThan(0.05), reason: 'tilted as it comes in');
    await tester.pump(const Duration(milliseconds: 500));
    final settled = tester.getTopLeft(find.byKey(const ValueKey('card-1')));
    expect(coming.dx, greaterThan(settled.dx), reason: 'came in from the right');
    expect(angleOf(tester, '1'), closeTo(0, 0.001), reason: 'level once landed');

    await tester.pumpWidget(host([_offer('1'), _offer('2')]));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('card-2')), findsOneWidget);

    await tester.pumpWidget(host([_offer('2')]));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.getTopLeft(find.byKey(const ValueKey('card-1'))).dx, lessThan(settled.dx), reason: 'going left');
    expect(angleOf(tester, '1'), lessThan(-0.05), reason: 'tilting as it goes');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('card-1')), findsNothing);
    expect(find.byKey(const ValueKey('card-2')), findsOneWidget);
  });

  testWidgets('a card swiped left declines it; a short swipe springs back', (tester) async {
    var declined = 0;
    SearchOfferView offer() => SearchOfferView(
      key: '1',
      price: 'RM1',
      yourFare: false,
      progress: 1,
      onAccept: () {},
      onDecline: () => declined++,
      cardKey: const ValueKey('card-1'),
    );
    await tester.pumpWidget(host([offer()]));
    await tester.pumpAndSettle();
    final home = tester.getTopLeft(find.byKey(const ValueKey('card-1')));

    // A little way: it follows and tilts, then springs back.
    final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('card-1'))));
    await g.moveBy(const Offset(-30, 0));
    await g.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(const ValueKey('card-1'))).dx, lessThan(home.dx));
    expect(angleOf(tester, '1'), lessThan(0), reason: 'tilts with the finger');
    await g.up();
    await tester.pumpAndSettle();
    expect(declined, 0);
    expect(tester.getTopLeft(find.byKey(const ValueKey('card-1'))).dx, closeTo(home.dx, 0.5));

    // To the right: nothing to do there, it stays put.
    await tester.drag(find.byKey(const ValueKey('card-1')), const Offset(200, 0));
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(const ValueKey('card-1'))).dx, closeTo(home.dx, 0.5));
    await tester.pumpAndSettle();
    expect(declined, 0);

    // Far enough left: declined, and it flies on off.
    await tester.drag(find.byKey(const ValueKey('card-1')), const Offset(-500, 0));
    await tester.pump();
    expect(declined, 1);
    await tester.pumpWidget(host(const []));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-1')), findsNothing);
  });

  testWidgets('the Accept key drains with the offer window', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: OfferAcceptButton(progress: 0.25, onPressed: () {}, timerKey: const ValueKey('t')),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(const ValueKey('t'))).width, closeTo(50, 0.5));
    expect(find.text('Accept'), findsOneWidget);
  });
}
