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

  testWidgets('offers rise in from below and slide out to the left', (tester) async {
    Widget host(List<SearchOfferView> offers) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: OfferStack(offers: offers)),
      ),
    );
    await tester.pumpWidget(host([_offer('1')]));
    await tester.pump(const Duration(milliseconds: 100));
    final rising = tester.getTopLeft(find.byKey(const ValueKey('card-1')));
    await tester.pump(const Duration(milliseconds: 400));
    final settled = tester.getTopLeft(find.byKey(const ValueKey('card-1')));
    expect(rising.dy, greaterThan(settled.dy), reason: 'came up from below');
    expect(rising.dx, settled.dx);

    await tester.pumpWidget(host([_offer('1'), _offer('2')]));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('card-2')), findsOneWidget);

    await tester.pumpWidget(host([_offer('2')]));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getTopLeft(find.byKey(const ValueKey('card-1'))).dx, lessThan(settled.dx), reason: 'going left');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('card-1')), findsNothing);
    expect(find.byKey(const ValueKey('card-2')), findsOneWidget);
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
