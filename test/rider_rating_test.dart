import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/rider_rating.dart';
import 'package:get_ride/src/data/city_ride_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/widgets/rider_badge.dart';

RideRequest _ride({double? rating, int? ratings, int? trips}) => RideRequest({
  'id': 'r1',
  'status': 'open',
  'rider_rating': ?rating,
  'rider_ratings_count': ?ratings,
  'rider_trips': ?trips,
});

void main() {
  group('the badge', () {
    test('"New rider" under 5 ratings, "Low" below 4.0, else none', () {
      expect(riderBadge(rating: 5, ratings: 0), RiderBadge.newRider);
      expect(riderBadge(rating: 2, ratings: 4), RiderBadge.newRider, reason: 'too few to call low');
      expect(riderBadge(rating: 3.99, ratings: 5), RiderBadge.low);
      expect(riderBadge(rating: 4.0, ratings: 5), RiderBadge.none);
      expect(riderBadge(rating: 4.8, ratings: 126), RiderBadge.none);
      expect(riderBadge(rating: 4.8, ratings: null), RiderBadge.none, reason: 'a ride from before the server stamped it');
    });
    test('follows the admin\'s numbers', () {
      const s = RiderRatingSettings(newBelow: 0, lowBelow: 4.5);
      expect(riderBadge(rating: 4.4, ratings: 1, s: s), RiderBadge.low);
      expect(riderBadge(rating: 4.6, ratings: 0, s: s), RiderBadge.none);
    });
    test('the lines', () {
      expect(riderRatingLine(rating: 4.8, ratings: 126, trips: 126), '4.8 · 126 trips');
      expect(riderRatingLine(rating: 5, ratings: 0, trips: 1), '1 trip');
      expect(ownRiderRatingText(rating: null), 'No ratings yet');
      expect(ownRiderRatingText(rating: 4.75, ratings: 12), '4.75 from 12 ratings');
    });
  });

  group('tags', () {
    test('low for 3 stars or less, high above; a change of stars drops the others', () {
      expect(riderTagsFor(0), isEmpty);
      expect(riderTagsFor(3), riderLowTags);
      expect(riderTagsFor(4), riderHighTags);
      expect(riderLowTags, ['Late to pickup', 'Rude', 'Wrong pickup point', 'Left a mess', 'Unsafe request']);
      expect(riderHighTags, ['Polite', 'On time', 'Clear directions']);
      expect(keepRiderTags({'Rude', 'Polite'}, 2), {'Rude'});
      expect(keepRiderTags({'Rude', 'Polite'}, 5), {'Polite'});
    });
    test('rating stays open for 24 hours', () {
      final done = DateTime.utc(2026, 10, 21, 8);
      expect(canRateRider(completed: true, completedAt: done, now: done.add(const Duration(hours: 23))), isTrue);
      expect(canRateRider(completed: true, completedAt: done, now: done.add(const Duration(hours: 24))), isFalse);
      expect(canRateRider(completed: false, completedAt: done, now: done), isFalse);
    });
    test('settings', () {
      expect(RiderRatingSettings.fromJson(null), RiderRatingSettings.standard);
      expect(RiderRatingSettings.fromJson({'window': 1, 'newBelow': 99, 'lowBelow': 9}),
          const RiderRatingSettings(window: 5, newBelow: 50, lowBelow: 5));
      const s = RiderRatingSettings(window: 50, newBelow: 3, lowBelow: 3.5);
      expect(RiderRatingSettings.fromJson(s.toJson()), s);
    });
  });

  for (final dark in [false, true]) {
    testWidgets('the chip on a request (${dark ? 'dark' : 'light'})', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [cityRideConfigProvider.overrideWith((ref) async => CityRideConfig.standard)],
        child: MaterialApp(
          theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
          home: Scaffold(
            body: Column(children: [
              RiderBadgeChip(ride: _ride(rating: 5, ratings: 1)),
              RiderBadgeChip(ride: _ride(rating: 3.6, ratings: 40)),
              RiderBadgeChip(ride: _ride(rating: 4.8, ratings: 126)),
            ]),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('New rider'), findsOneWidget);
      expect(find.text('Low'), findsOneWidget);
      expect(find.byType(RiderBadgeChip), findsNWidgets(3));
      expect(showRiderStars(_ride(rating: 5, ratings: 1), RiderRatingSettings.standard), isFalse);
      expect(showRiderStars(_ride(rating: 4.8, ratings: 126), RiderRatingSettings.standard), isTrue);
    });
  }
}
