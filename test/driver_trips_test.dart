// The driver's completed trips next to the rating (migration 0237): on the
// rider's offer card and on the accepted driver's card, in both themes, on a
// 412 px phone at 1.3x text and on a 360 px one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ride_bidding.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/driver_card.dart' show DriverCardHeader;
import 'package:get_ride/src/features/ride/searching_parts.dart';

class _Phone {
  const _Phone(this.name, this.width, this.scale);
  final String name;
  final double width;
  final double scale;
  @override
  String toString() => name;
}

const _phones = [
  _Phone('412 px @1.3', 412, 1.3),
  _Phone('360 px', 360, 1.0),
  _Phone('360 px @1.3', 360, 1.3),
];

Future<void> _pump(WidgetTester tester, _Phone phone, Brightness b, Widget child) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(phone.width, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(b),
    builder: (c, w) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(phone.scale)),
      child: w!,
    ),
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: Column(children: [child])),
    ),
  ));
  await tester.pump();
}

SearchOfferView _offer({String? name = 'Muhammad Hafiz bin Abdullah', double? rating = 4.9, int? trips}) =>
    SearchOfferView(
      key: 'o1',
      price: 'RM 23.50',
      yourFare: false,
      progress: 0.6,
      name: name,
      rating: rating,
      trips: trips,
      vehicle: 'White Perodua Myvi · WXY 1234',
      etaMin: 4,
      onAccept: () {},
      onDecline: () {},
      cardKey: const ValueKey('card'),
    );

RideRequest _ride(Map<String, dynamic> extra) => RideRequest({
  'id': 'r1',
  'status': 'accepted',
  'partner_id': 'd1',
  'partner_name': 'Muhammad Hafiz bin Abdullah',
  'partner_vehicle': 'White Perodua Myvi',
  'partner_plate': 'WXY 1234',
  'partner_rating': 4.9,
  ...extra,
});

void main() {
  group('the label', () {
    test('counts with the locale\'s separator, and calls a driver with none new', () {
      expect(driverTripsLabel(null), isNull);
      expect(driverTripsLabel(0), 'New driver');
      expect(driverTripsLabel(1), '1 trip');
      expect(driverTripsLabel(312), '312 trips');
      expect(driverTripsLabel(2553, locale: 'en_MY'), '2,553 trips');
      expect(driverTripsLabel(2553, locale: 'de'), '2.553 trips');
      expect(driverTripsLabel(2553, locale: 'xx_NOPE'), '2,553 trips');
    });

    test('a ride without the column knows no count; an empty stamp is a new driver', () {
      expect(_ride({}).partnerTrips, isNull);
      expect(_ride({'partner_trips': null}).partnerTrips, 0);
      expect(_ride({'partner_trips': 312}).partnerTrips, 312);
    });

    test('the standing offer carries the count', () {
      final r = RideRequest({
        'id': 'r1',
        'status': 'open',
        'partner_id': 'd1',
        'offered_fare': 25,
        'partner_rating': 4.9,
        'partner_trips': 312,
      });
      expect(standingOffer(r)!.trips, 312);
      expect(standingOffer(RideRequest({...r.raw}..remove('partner_trips')))!.trips, isNull);
    });
  });

  for (final b in Brightness.values) {
    for (final phone in _phones) {
      testWidgets('offer card, ${b.name}, $phone', (tester) async {
        await _pump(tester, phone, b, SearchOfferCard(offer: _offer(trips: 2553)));
        expect(tester.takeException(), isNull);
        expect(find.textContaining('4.9', findRichText: true), findsOneWidget);
        expect(find.textContaining('2,553 trips', findRichText: true), findsOneWidget);
        // The Accept and Decline keys stay on the card.
        expect(find.text('Accept'), findsOneWidget);
        expect(find.text('Decline'), findsOneWidget);
        // The muted count reads on the card in either theme.
        final rich = tester.widget<RichText>(find.textContaining('2,553', findRichText: true));
        TextSpan? span;
        rich.text.visitChildren((s) {
          if (s is TextSpan && (s.text ?? '').contains('trips')) span = s;
          return span == null;
        });
        expect(span, isNotNull);
        expect(span!.style?.color, Theme.of(tester.element(find.byKey(const ValueKey('card')))).colorScheme.onSurfaceVariant);
      });

      testWidgets('accepted driver card, ${b.name}, $phone', (tester) async {
        await _pump(tester, phone, b, Card(child: DriverCardHeader(ride: _ride({'partner_trips': 312}))));
        expect(tester.takeException(), isNull);
        expect(find.text('4.9'), findsOneWidget);
        expect(find.text('312 trips'), findsOneWidget);
        // Beside the rating (or under it when the row is full), inside the card.
        final rating = tester.getRect(find.byKey(const ValueKey('driver-rating')));
        final trips = tester.getRect(find.byKey(const ValueKey('driver-trips')));
        final card = tester.getRect(find.byType(Card));
        expect(trips.left >= rating.right - 0.01 || trips.top >= rating.bottom - 0.01, isTrue);
        expect(trips.right, lessThanOrEqualTo(card.right));
        expect(trips.bottom, lessThanOrEqualTo(card.bottom));
      });
    }
  }

  testWidgets('a new driver says so; an old server shows the rating alone', (tester) async {
    await _pump(tester, _phones.first, Brightness.light, Column(children: [
      SearchOfferCard(offer: _offer(trips: 0)),
      Card(child: DriverCardHeader(ride: _ride({'partner_trips': null}))),
    ]));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('New driver', findRichText: true), findsNWidgets(2));

    await _pump(tester, _phones.first, Brightness.dark, Column(children: [
      SearchOfferCard(offer: _offer()),
      Card(child: DriverCardHeader(ride: _ride({}))),
    ]));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('trip', findRichText: true), findsNothing);
    expect(find.textContaining('New', findRichText: true), findsNothing);
    expect(find.text('4.9'), findsOneWidget);
    expect(find.byKey(const ValueKey('driver-trips')), findsNothing);
  });

  testWidgets('no rating yet: the count alone', (tester) async {
    await _pump(tester, _phones[1], Brightness.dark,
        Card(child: DriverCardHeader(ride: _ride({'partner_rating': null, 'partner_trips': 0}))));
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.star), findsNothing);
    expect(find.text('New driver'), findsOneWidget);
  });
}
