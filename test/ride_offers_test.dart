import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_bidding.dart' show OfferOutcome;
import 'package:get_ride/src/core/ride_offers.dart';
import 'package:get_ride/src/features/ride/searching_parts.dart';

typedef _O = ({String k, double? p, int? eta, double? r});

List<String> _keys(List<_O> xs) => [for (final x in xs) x.k];

List<_O> _sort(List<_O> xs, OfferSort s) =>
    sortOfferList(xs, s, amount: (o) => o.p, eta: (o) => o.eta, rating: (o) => o.r);

RideOfferRow _row({String status = 'open', String? reason, double amount = 20, DateTime? created, DateTime? expires}) {
  final c = created ?? DateTime.utc(2026, 10, 21, 10);
  return RideOfferRow.tryParse({
    'id': 'o1',
    'request_id': 'r1',
    'partner_id': 'p1',
    'amount': amount,
    'created_at': c.toIso8601String(),
    'expires_at': (expires ?? c.add(const Duration(seconds: 15))).toIso8601String(),
    'status': status,
    'closed_reason': reason,
  })!;
}

void main() {
  const offers = <_O>[
    (k: 'hafiz', p: 18, eta: 3, r: 4.9),
    (k: 'mei', p: 20, eta: 2, r: 4.8),
    (k: 'kumar', p: 17, eta: 6, r: 4.6),
    (k: 'azlan', p: 19, eta: 4, r: 5.0),
    (k: 'siti', p: 18, eta: 5, r: 4.7),
    (k: 'jason', p: 22, eta: 1, r: 4.9),
  ];

  group('sorting', () {
    test('cheapest, then nearer; ties keep their order', () {
      expect(_keys(_sort(offers, OfferSort.cheapest)), ['kumar', 'hafiz', 'siti', 'azlan', 'mei', 'jason']);
    });
    test('nearest, then cheaper', () {
      expect(_keys(_sort(offers, OfferSort.nearest)), ['jason', 'mei', 'hafiz', 'azlan', 'siti', 'kumar']);
    });
    test('top rated, then cheaper', () {
      expect(_keys(_sort(offers, OfferSort.rating)), ['azlan', 'hafiz', 'jason', 'mei', 'siti', 'kumar']);
    });
    test('unknowns go last', () {
      const xs = <_O>[(k: 'a', p: null, eta: null, r: null), (k: 'b', p: 30, eta: 9, r: 3)];
      for (final s in OfferSort.values) {
        expect(_keys(_sort(xs, s)), ['b', 'a'], reason: s.name);
      }
    });
    test('the setting reads back', () {
      expect(OfferSort.parse('nearest'), OfferSort.nearest);
      expect(OfferSort.parse('rating'), OfferSort.rating);
      expect(OfferSort.parse('nonsense'), OfferSort.cheapest);
      expect([for (final s in OfferSort.values) s.label], ['Cheapest', 'Nearest', 'Top rated']);
    });
  });

  group('the queue', () {
    String key(_O o) => o.k;
    test('the first five show, the rest wait', () {
      final q = offerQueue(_sort(offers, OfferSort.cheapest), shown: 5, key: key);
      expect(_keys(q.shown), ['kumar', 'hafiz', 'siti', 'azlan', 'mei']);
      expect(q.waiting, 1);
      expect(offersWaitingLabel(q.waiting), '+1 more waiting');
      expect(offersWaitingLabel(0), isNull);
    });
    test('a card on screen keeps its place when a cheaper one arrives', () {
      final first = offerQueue(_sort(offers.sublist(0, 2), OfferSort.cheapest), shown: 2, key: key);
      expect(_keys(first.shown), ['hafiz', 'mei']);
      final next = offerQueue(_sort(offers, OfferSort.cheapest), shown: 2, key: key, onScreen: {'hafiz', 'mei'});
      expect(_keys(next.shown), ['hafiz', 'mei'], reason: 'kumar (cheaper) waits in line');
      expect(next.waiting, 4);
    });
    test('a card that leaves frees its place for the best waiting', () {
      final rest = offers.where((o) => o.k != 'mei').toList();
      final q = offerQueue(_sort(rest, OfferSort.cheapest), shown: 2, key: key, onScreen: {'hafiz', 'mei'});
      expect(_keys(q.shown), ['kumar', 'hafiz']);
    });
    test('at least one shows', () {
      expect(offerQueue(offers, shown: 0, key: key).shown, hasLength(1));
    });
  });

  group('Lowest', () {
    String key(_O o) => o.k;
    double? amount(_O o) => o.p;
    test('on the cheapest of two or more, the first when they tie', () {
      expect(lowestOfferKey(offers, amount: amount, key: key), 'kumar');
      expect(lowestOfferKey(offers.sublist(0, 2), amount: amount, key: key), 'hafiz');
      const tie = <_O>[(k: 'x', p: 18, eta: 1, r: 4), (k: 'y', p: 18, eta: 1, r: 4)];
      expect(lowestOfferKey(tie, amount: amount, key: key), 'x');
    });
    test('none for a single offer', () {
      expect(lowestOfferKey(offers.sublist(0, 1), amount: amount, key: key), isNull);
    });
  });

  group('settings', () {
    test('defaults and limits', () {
      expect(OfferSettings.fromJson(null), OfferSettings.standard);
      expect(OfferSettings.standard.shown, 5);
      expect(OfferSettings.standard.lifetime, const Duration(seconds: 15));
      expect(OfferSettings.standard.sort, OfferSort.cheapest);
      expect(OfferSettings.standard.reofferAfterDecline, isTrue);
      final s = OfferSettings.fromJson({'shown': 50, 'lifetimeSeconds': 1, 'sort': 'rating', 'reofferAfterDecline': false});
      expect((s.shown, s.lifetime.inSeconds, s.sort, s.reofferAfterDecline), (10, 5, OfferSort.rating, false));
      expect(OfferSettings.fromJson(s.toJson()), s);
    });
  });

  group('an offer row', () {
    test('lives until it expires, its window draining', () {
      final o = _row();
      final c = o.createdAt;
      expect(o.isLive(c.add(const Duration(seconds: 5))), isTrue);
      expect(o.progress(c.add(const Duration(milliseconds: 7500))), closeTo(0.5, 1e-9));
      expect(o.isLive(c.add(const Duration(seconds: 15))), isFalse);
      expect(o.progress(c.add(const Duration(seconds: 20))), 0);
    });
    test('a bad row is skipped', () {
      expect(RideOfferRow.tryParse({'id': 'x'}), isNull);
      expect(RideOfferRow.tryParse('nope'), isNull);
    });
    test('the driver reads how it ended', () {
      expect(rowOfferOutcome(_row()), isNull);
      expect(rowOfferOutcome(_row(status: 'accepted'))?.outcome, OfferOutcome.won);
      expect(rowOfferOutcome(_row(status: 'withdrawn', reason: 'taken'))?.outcome, OfferOutcome.outbid);
      expect(_row(status: 'withdrawn', reason: 'taken').takenByOther, isTrue);
      expect(rowOfferOutcome(_row(status: 'withdrawn', reason: 'raised'))?.outcome, OfferOutcome.raised);
      expect(rowOfferOutcome(_row(status: 'withdrawn', reason: 'cancelled'))?.outcome, OfferOutcome.closed);
      expect(rowOfferOutcome(_row(status: 'withdrawn', reason: 'replaced')), isNull);
      expect(rowOfferOutcome(_row(status: 'declined'))?.outcome, OfferOutcome.declined);
      expect(rowOfferOutcome(_row(status: 'expired')), (outcome: OfferOutcome.declined, expired: true));
    });
    test('the server\'s refusals in words', () {
      expect(rideOfferError('OFFERS_PAUSED: You can send offers again at 14:30.'),
          'You cancelled too many rides this week. You can send offers again at 14:30.');
      expect(rideOfferError('OFFER_DECLINED'), 'The rider declined your offer.');
      expect(rideOfferError('boom'), contains('connection'));
    });
  });

  group('the card', () {
    SearchOfferView view(String k, double p, {bool lowest = false}) => SearchOfferView(
      key: k,
      price: 'RM$p',
      amount: p,
      yourFare: false,
      progress: 1,
      onAccept: () {},
      onDecline: () {},
      name: 'Aisyah Farid',
      lowest: lowest,
    );

    for (final dark in [false, true]) {
      testWidgets('Lowest, initials and the sort chips (${dark ? 'dark' : 'light'})', (tester) async {
        OfferSort? picked;
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
          home: Scaffold(
            body: Column(children: [
              OfferSortChips(sort: OfferSort.cheapest, onChanged: (s) => picked = s),
              SearchOfferCard(offer: view('a', 17).withLowest()),
              SearchOfferCard(offer: view('b', 18)),
            ]),
          ),
        ));
        expect(find.byKey(const ValueKey('offer-lowest-a')), findsOneWidget);
        expect(find.byKey(const ValueKey('offer-lowest-b')), findsNothing);
        expect(find.text('AF'), findsNWidgets(2));
        await tester.tap(find.byKey(const ValueKey('offer-sort-nearest')));
        expect(picked, OfferSort.nearest);
        expect(tester.takeException(), isNull);
      });
    }

    test('initials', () {
      expect(offerInitials('Aisyah Farid Binti Ali'), 'AF');
      expect(offerInitials('kumar'), 'K');
      expect(offerInitials('  '), '?');
      expect(offerInitials(null), '?');
    });
  });
}
