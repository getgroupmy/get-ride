import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/city_cancel.dart';
import 'package:get_ride/src/data/city_ride_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/city_cancel_parts.dart';

final _accepted = DateTime.utc(2026, 10, 21, 10);

RideRequest _ride({String status = 'accepted', DateTime? arrived, String? scheduled}) => RideRequest({
  'id': 'r1',
  'status': status,
  'currency': 'MYR',
  'accepted_at': _accepted.toIso8601String(),
  if (arrived != null) 'arrived_at': arrived.toIso8601String(),
  'scheduled_ride_id': ?scheduled,
});

void main() {
  const rules = CancelRules.standard;

  group('the fee by time', () {
    double fee(Duration after, {Duration? arrivedAfter, String? reason}) => cityCancelFee(
      rules,
      acceptedAt: _accepted,
      arrivedAt: arrivedAfter == null ? null : _accepted.add(arrivedAfter),
      at: _accepted.add(after),
      reason: reason,
    );

    test('free for 2 minutes after accept', () {
      expect(fee(Duration.zero), 0);
      expect(fee(const Duration(minutes: 1, seconds: 59)), 0);
    });
    test('RM 3 after that, before arrival', () {
      expect(fee(const Duration(minutes: 2)), 3);
      expect(fee(const Duration(minutes: 9)), 3);
    });
    test('RM 5 once the driver arrived, even inside the free time', () {
      expect(fee(const Duration(minutes: 6), arrivedAfter: const Duration(minutes: 5)), 5);
      expect(fee(const Duration(minutes: 1, seconds: 30), arrivedAfter: const Duration(minutes: 1)), 5);
      expect(fee(const Duration(minutes: 4), arrivedAfter: const Duration(minutes: 5)), 3, reason: 'asked before arrival');
    });
    test('a safety reason is always free', () {
      expect(fee(const Duration(minutes: 9), reason: 'driver_not_moving'), 0);
      expect(fee(const Duration(minutes: 9), arrivedAfter: const Duration(minutes: 5), reason: 'wrong_car'), 0);
      expect(isSafetyCancelReason('changed_plans'), isFalse);
    });
    test('nobody accepted yet: free', () {
      expect(cityCancelFee(rules, acceptedAt: null, at: _accepted), 0);
    });
    test('a place\'s own rules', () {
      final city = CancelRules.fromJson({'freeMinutes': 5, 'lateFee': 4}, base: rules);
      expect(cityCancelFee(city, acceptedAt: _accepted, at: _accepted.add(const Duration(minutes: 4))), 0);
      expect(cityCancelFee(city, acceptedAt: _accepted, at: _accepted.add(const Duration(minutes: 5))), 4);
      expect(city.arrivedFee, 5, reason: 'the rest inherits');
    });
  });

  group('what the screens say', () {
    test('"Free to cancel for m:ss" counts down, then the fee', () {
      final r = _ride();
      expect(freeCancelLeft(rules, acceptedAt: _accepted, now: _accepted.add(const Duration(seconds: 18))),
          const Duration(minutes: 1, seconds: 42));
      expect(cancelTermsLine(rules, r, _accepted.add(const Duration(seconds: 18))), 'Free to cancel for 1:42');
      expect(cancelTermsLine(rules, r, _accepted.add(const Duration(minutes: 3))),
          'Cancelling now costs RM3.00. Safety reasons are always free.');
      final here = _ride(status: 'arrived', arrived: _accepted.add(const Duration(minutes: 4)));
      expect(cancelTermsLine(rules, here, _accepted.add(const Duration(minutes: 5))),
          'Your driver is here: cancelling now costs RM5.00');
      expect(cancelButtonLabel(0), 'Cancel ride');
      expect(cancelButtonLabel(3), 'Cancel ride (RM3.00)');
    });
    test('the no-show unlocks after 5 minutes', () {
      final at = _accepted;
      expect(noShowLeft(rules, arrivedAt: at, now: at.add(const Duration(minutes: 1))), const Duration(minutes: 4));
      expect(noShowLeft(rules, arrivedAt: at, now: at.add(const Duration(minutes: 6))), Duration.zero);
      expect(minSec(const Duration(minutes: 4, seconds: 5)), '4:05');
    });
    test('scheduled rides keep their own rules', () {
      expect(cityCancelApplies(_ride()), isTrue);
      expect(cityCancelApplies(_ride(scheduled: 's1')), isFalse);
      expect(cityCancelApplies(_ride(status: 'on_trip')), isFalse);
    });
    test('no strings with arrows', () {
      final all = [
        cancelTermsLine(rules, _ride(), _accepted),
        cancelTermsLine(rules, _ride(), _accepted.add(const Duration(hours: 1))),
        const DriverCancelStats(cancels: 3, rides: 25, percent: 12).describe(),
      ];
      for (final s in all) {
        expect(s.contains('→'), isFalse, reason: s);
      }
    });
  });

  group('the driver\'s rate', () {
    test('reads and says it', () {
      final s = DriverCancelStats.fromJson({
        'cancels': 3, 'rides': 25, 'percent': 12, 'limitPercent': 20, 'days': 7, 'pauseMinutes': 30, 'minRides': 5,
      });
      expect(s.describe(),
          "Your cancel rate this week: 12% (3 of 25). Above 20% you can't send offers for 30 min.");
      expect(s.overLimit, isFalse);
      expect(const DriverCancelStats(cancels: 2, rides: 5, percent: 40).overLimit, isTrue);
      expect(const DriverCancelStats(cancels: 2, rides: 3, percent: 66.7).overLimit, isFalse, reason: 'too few rides');
      final paused = DriverCancelStats.fromJson({'pausedUntil': '2026-10-21T10:30:00Z'});
      expect(paused.pausedAt(DateTime.utc(2026, 10, 21, 10, 10)), isTrue);
      expect(paused.pausedAt(DateTime.utc(2026, 10, 21, 10, 31)), isFalse);
    });
    test('the admin\'s limit', () {
      expect(DriverCancelLimit.fromJson(null), DriverCancelLimit.standard);
      expect(DriverCancelLimit.fromJson({'limitPercent': 500, 'days': 0}).limitPercent, 100);
      const l = DriverCancelLimit(limitPercent: 25, days: 14, pauseMinutes: 60, minRides: 8);
      expect(DriverCancelLimit.fromJson(l.toJson()), l);
    });
    test('a place row', () {
      final p = CancelPlace.fromRow({
        'id': 'x', 'level': 'city', 'country': 'Malaysia', 'state': 'Selangor', 'city': 'Shah Alam',
        'rules': {'lateFee': 4, 'bogus': 1},
      });
      expect(p.label, 'Malaysia, Selangor, Shah Alam');
      expect(p.rules, {'lateFee': 4.0});
      expect(p.toRow()['suburb'], isNull);
      expect(const CancelPlace(level: 'default').label, 'Default (everywhere)');
    });
  });

  for (final dark in [false, true]) {
    testWidgets('the rider\'s Cancel ride counts down, then shows the fee (${dark ? 'dark' : 'light'})', (tester) async {
      var now = _accepted.add(const Duration(seconds: 30));
      Widget app() => ProviderScope(
        overrides: [
          cancelTermsProvider('r1').overrideWith((ref) async => const CancelTerms(currency: 'MYR')),
          cityCancelClockProvider.overrideWithValue(() => now),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
          home: Scaffold(body: CityCancelButton(ride: _ride(), onPressed: () {})),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pump();
      expect(find.text('Free to cancel for 1:30'), findsOneWidget);
      expect(find.text('Cancel ride'), findsOneWidget);
      now = _accepted.add(const Duration(minutes: 3));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Cancel ride (RM3.00)'), findsOneWidget);
      expect(find.byKey(const ValueKey('ride-cancel-terms')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('without the rules (an older server) just the button', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [cancelTermsProvider('r1').overrideWith((ref) async => null)],
      child: MaterialApp(home: Scaffold(body: CityCancelButton(ride: _ride(), onPressed: () {}))),
    ));
    await tester.pump();
    expect(find.text('Cancel ride'), findsOneWidget);
    expect(find.byKey(const ValueKey('ride-cancel-terms')), findsNothing);
  });

  testWidgets('the driver waits, then "Rider didn\'t come" unlocks', (tester) async {
    final arrived = _accepted.add(const Duration(minutes: 2));
    var now = arrived.add(const Duration(minutes: 1));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        cancelTermsProvider('r1').overrideWith((ref) async => const CancelTerms(currency: 'MYR')),
        cityCancelClockProvider.overrideWithValue(() => now),
      ],
      child: MaterialApp(home: Scaffold(body: NoShowPanel(ride: _ride(status: 'arrived', arrived: arrived)))),
    ));
    await tester.pump();
    expect(find.text('1:00'), findsOneWidget);
    expect(find.text('"Rider didn\'t come" unlocks in 4:00'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.descendant(of: find.byKey(const ValueKey('no-show')),
        matching: find.byType(OutlinedButton))).onPressed, isNull);
    now = arrived.add(const Duration(minutes: 5));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('You can end it as a no-show'), findsOneWidget);
  });

  group('a freight trip (0271): only the freight fee', () {
    // As ride_cancel_terms gives it: the city fees 0, the freight one 15.
    final terms = CancelTerms.fromJson({
      'freeMinutes': 0, 'lateFee': 0, 'arrivedFee': 0, 'noShowMinutes': 5, 'noShowFee': 0,
      'currency': 'MYR', 'scheduled': false, 'freight': true, 'freightArrivedFee': 15,
    });
    final arrived = _accepted.add(const Duration(minutes: 4));
    final here = _ride(status: 'arrived', arrived: arrived);

    test('reads the terms', () {
      expect(terms.freight, isTrue);
      expect(terms.freightArrivedFee, 15);
      expect(terms.rules.arrivedFee, 0);
      expect(CancelTerms.fromJson({'arrivedFee': 5}).freight, isFalse);
      expect(CancelTerms.fromJson({'freight': true, 'freightArrivedFee': -1}).freightArrivedFee, 0);
    });
    test('free until the driver arrives, then the freight fee and never the city one', () {
      expect(cancelFeeFor(terms, _ride(), _accepted.add(const Duration(minutes: 3))), 0);
      expect(cancelFeeFor(terms, here, arrived.add(const Duration(minutes: 1))), 15);
      expect(cancelTermsLineFor(terms, _ride(), _accepted.add(const Duration(seconds: 18))), 'Free to cancel');
      expect(cancelTermsLineFor(terms, here, arrived.add(const Duration(minutes: 1))),
          'Your driver is here: cancelling now costs RM15.00');
      expect(cancelFeeNote(terms, here, arrived.add(const Duration(minutes: 1))),
          'Your driver is at the pickup: cancelling now costs RM15.00, added to your next request.');
      expect(cancelFeeNote(terms, _ride(), _accepted.add(const Duration(minutes: 3))), isNull);
    });
    test('without a freight fee at the pickup it is free', () {
      final none = CancelTerms.fromJson({'arrivedFee': 0, 'lateFee': 0, 'freight': true});
      expect(cancelFeeFor(none, here, arrived.add(const Duration(minutes: 1))), 0);
      expect(cancelTermsLineFor(none, here, arrived.add(const Duration(minutes: 1))), 'Free to cancel');
    });
    test('a city ride is unchanged', () {
      const city = CancelTerms(currency: 'MYR');
      expect(cancelFeeFor(city, here, arrived.add(const Duration(minutes: 1))), 5);
      expect(cancelTermsLineFor(city, _ride(), _accepted.add(const Duration(seconds: 18))), 'Free to cancel for 1:42');
    });

    testWidgets('the rider\'s Cancel ride shows the freight fee', (tester) async {
      var now = _accepted.add(const Duration(minutes: 3));
      var ride = _ride();
      Widget app() => ProviderScope(
        overrides: [
          cancelTermsProvider('r1').overrideWith((ref) async => terms),
          cityCancelClockProvider.overrideWithValue(() => now),
        ],
        child: MaterialApp(home: Scaffold(body: CityCancelButton(ride: ride, onPressed: () {}))),
      );
      await tester.pumpWidget(app());
      await tester.pump();
      expect(find.text('Free to cancel'), findsOneWidget);
      expect(find.text('Cancel ride'), findsOneWidget);
      now = arrived.add(const Duration(minutes: 1));
      ride = here;
      await tester.pumpWidget(app());
      await tester.pump();
      expect(find.text('Your driver is here: cancelling now costs RM15.00'), findsOneWidget);
      expect(find.text('Cancel ride (RM15.00)'), findsOneWidget);
      expect(find.textContaining('RM5.00'), findsNothing);
    });
  });

  test('the owed line counts every fee from earlier rides', () {
    expect(owedFeesNote(20, 'MYR'), '+ RM20.00 owed from an earlier ride');
    expect(owedFeesNote(0, 'MYR'), isNull);
  });
}
