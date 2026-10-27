// Post-trip star ratings (migration 0159): lib/src/core/ride_rating.dart,
// lib/src/data/ride_rating_repository.dart and the card in
// lib/src/widgets/ride_rating_card.dart.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ride_rating.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_rating_repository.dart';
import 'package:get_ride/src/widgets/ride_rating_card.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Repo implements RideRatingRepository {
  _Repo({this.existing, this.unavailable = false, this.refuse});
  final RideRating? existing;
  final bool unavailable;
  final Object? refuse;
  final saved = <(String, int, String?)>[];
  final tagsSent = <List<String>?>[];

  @override
  Future<RateRideResult> rate(String requestId, int stars, {String? comment, List<String>? tags}) async {
    if (refuse != null) throw refuse!;
    if (unavailable) return const RatingUnavailable();
    final clean = cleanRatingComment(comment);
    saved.add((requestId, stars, clean));
    tagsSent.add(tags);
    return RatingSaved(RideRating(stars: stars, comment: clean, tags: tags ?? const []), partnerRating: 4.5);
  }

  @override
  Future<RideRating?> mine(String requestId, String riderId) async => existing;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

final _now = DateTime.utc(2026, 10, 12, 12);

RideRequest _ride({String status = 'completed', DateTime? completedAt, String rider = 'u1'}) => RideRequest({
  'id': 'r1',
  'rider_id': rider,
  'partner_id': 'd1',
  'partner_name': 'Dan',
  'status': status,
  'completed_at': (completedAt ?? _now.subtract(const Duration(hours: 1))).toIso8601String(),
});

void main() {
  group('rules', () {
    test('rateable for 7 days after a completed trip', () {
      final done = _now.subtract(const Duration(days: 6));
      expect(canRateRide(completed: true, completedAt: done, now: _now), isTrue);
      expect(canRateRide(completed: false, completedAt: done, now: _now), isFalse);
      expect(canRateRide(completed: true, completedAt: null, now: _now), isFalse);
      expect(canRateRide(completed: true, completedAt: _now.subtract(const Duration(days: 7)), now: _now), isFalse);
    });

    test('stars 1–5, comments trimmed and capped', () {
      expect([0, 1, 5, 6, null].map(validStars), [false, true, true, false, false]);
      expect(cleanRatingComment('  '), isNull);
      expect(cleanRatingComment(null), isNull);
      expect(cleanRatingComment('  nice  '), 'nice');
      expect(cleanRatingComment('x' * 600)!.length, rideRatingCommentMax);
      expect(starsLabel(5), 'Excellent');
      expect(starsLabel(0), 'Tap a star to rate');
    });

    test('a stored row, and the server\'s refusals in words', () {
      final r = RideRating.fromRow({'stars': 4, 'comment': ' ok ', 'updated_at': '2026-10-12T10:00:00Z'});
      expect(r, const RideRating(stars: 4, comment: 'ok'));
      expect(r.updatedAt, DateTime.utc(2026, 10, 12, 10));
      expect(rideRatingError('PostgrestException(message: too_late)'), contains('too late'));
      expect(rideRatingError('not_completed'), contains('once it has finished'));
      expect(rideRatingError('bad_stars'), contains('1 to 5'));
      expect(rideRatingError('not_authorized'), contains('Only the passenger'));
      expect(rideRatingError('socket'), contains('connection'));
    });

    test('tags: the list follows the stars, picks keep to it', () {
      const tags = DriverRatingTags.fallback;
      expect(tags.forStars(5), contains('Clean car'));
      expect(tags.forStars(2), contains('Rude'));
      expect(driverTagQuestion(4), 'What went well?');
      expect(driverTagQuestion(3), 'What went wrong?');
      expect(keepDriverTags({'Rude', 'Clean car', 'Friendly'}, 5, tags), ['Clean car', 'Friendly']);
      expect(keepDriverTags({'Rude', 'Clean car'}, 1, tags), ['Rude']);
      final rows = DriverRatingTags.fromRows([
        {'tag': 'B', 'low': false, 'position': 2, 'active': true},
        {'tag': 'A', 'low': false, 'position': 1, 'active': true},
        {'tag': 'Gone', 'low': true, 'position': 1, 'active': false},
        {'tag': 'Late', 'low': true, 'position': 3, 'active': true},
      ]);
      expect(rows.high, ['A', 'B']);
      expect(rows.low, ['Late']);
      expect(RideRating.fromRow({'stars': 5, 'tags': ['Friendly']}).tags, ['Friendly']);
      expect(RideRating.fromRow({'stars': 5}).tags, isEmpty, reason: 'a row from before 0297');
    });

    test('driver totals and the trip summary line', () {
      final d = DriverTagTotals.fromJson({
        'days': 30,
        'rating': 4.8,
        'rated': 12,
        'tags': [
          {'tag': 'Friendly', 'low': false, 'n': 7},
          {'tag': 'Rude', 'low': true, 'n': 1},
          {'tag': '', 'low': true, 'n': 9},
        ],
      });
      expect(d.rated, 12);
      expect(d.liked.single.tag, 'Friendly');
      expect(d.toWorkOn.single.n, 1);
      expect(DriverTagTotals.fromJson(null).rated, 0);
      expect(tripSummaryRatedLine(null), 'Not rated.');
      expect(tripSummaryRatedLine(1), 'You rated 1 star.');
      expect(tripSummaryRatedLine(5), 'You rated 5 stars.');
      expect(tripSummaryCloseAfter, const Duration(seconds: 3));
    });

    test('an older database without rate_ride is told apart from a refusal', () {
      expect(isMissingRatingFunction(const PostgrestException(message: 'x', code: 'PGRST202')), isTrue);
      expect(isMissingRatingFunction(const PostgrestException(message: 'x', code: '42883')), isTrue);
      expect(
        isMissingRatingFunction(const PostgrestException(message: 'Could not find the function public.rate_ride')),
        isTrue,
      );
      expect(isMissingRatingFunction(const PostgrestException(message: 'too_late', code: 'P0001')), isFalse);
    });
  });

  for (final b in Brightness.values) {
    group('the card (${b.name})', () {
      Future<_Repo> pump(WidgetTester tester, RideRequest ride, {_Repo? repo, VoidCallback? onSkip}) async {
        final r = repo ?? _Repo();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              rideRatingRepositoryProvider.overrideWithValue(r),
              driverRatingTagsProvider.overrideWith((ref) async => DriverRatingTags.fallback),
            ],
            child: MaterialApp(
              theme: appTheme(b),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: RideRatingCard(ride: ride, now: () => _now, onSkip: onSkip),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return r;
      }

      testWidgets('a star saves at once; the comment saves as it is written', (tester) async {
        final repo = await pump(tester, _ride());
        expect(find.text('Rate Dan'), findsOneWidget);
        expect(find.byKey(const ValueKey('ride-rating-submit')), findsNothing, reason: 'nothing to forget to press');
        expect(find.text('Tap a star. It saves straight away.'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('rate-star-4')));
        await tester.pumpAndSettle();
        expect(repo.saved.single, ('r1', 4, null), reason: 'saved on the tap');
        expect(find.text('Very good'), findsOneWidget);
        expect(find.byKey(const ValueKey('ride-rating-saved-chip')), findsOneWidget);
        expect(find.text('Rating saved'), findsOneWidget);
        // It stays open for a comment rather than folding away.
        expect(find.byKey(const ValueKey('ride-rating-card')), findsOneWidget);

        await tester.enterText(find.byKey(const ValueKey('ride-rating-comment')), '  Smooth drive ');
        await tester.pump(const Duration(milliseconds: 500));
        expect(repo.saved, hasLength(1), reason: 'not on every keystroke');
        await tester.pump(rideRatingCommentSaveAfter);
        await tester.pumpAndSettle();
        expect(repo.saved.last, ('r1', 4, 'Smooth drive'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('a comment still being typed as the screen goes is sent all the same', (tester) async {
        final repo = await pump(tester, _ride());
        await tester.tap(find.byKey(const ValueKey('rate-star-5')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('ride-rating-comment')), 'Thanks!');
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(repo.saved.last, ('r1', 5, 'Thanks!'));
      });

      testWidgets('a saved rating shows, and Edit changes it within the window', (tester) async {
        final repo = await pump(
          tester,
          _ride(),
          repo: _Repo(existing: const RideRating(stars: 2, comment: 'Late')),
        );
        expect(find.byKey(const ValueKey('ride-rating-saved')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('ride-rating-edit')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ride-rating-card')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('rate-star-5')));
        await tester.pumpAndSettle();
        expect(repo.saved.single, ('r1', 5, 'Late'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('after the window: the saved rating without Edit, or nothing', (tester) async {
        final old = _ride(completedAt: _now.subtract(const Duration(days: 8)));
        await pump(tester, old, repo: _Repo(existing: const RideRating(stars: 3)));
        expect(find.byKey(const ValueKey('ride-rating-saved')), findsOneWidget);
        expect(find.byKey(const ValueKey('ride-rating-edit')), findsNothing);

        await pump(tester, old);
        expect(find.byKey(const ValueKey('ride-rating-card')), findsNothing);
        expect(find.byKey(const ValueKey('ride-rating-saved')), findsNothing);
      });

      testWidgets('after a star the tags show; a tap saves them a moment later', (tester) async {
        final repo = await pump(tester, _ride());
        expect(find.byKey(const ValueKey('ride-rating-tag-Friendly')), findsNothing, reason: 'no tags before a star');
        await tester.tap(find.byKey(const ValueKey('rate-star-5')));
        await tester.pumpAndSettle();
        expect(find.text('What went well?'), findsOneWidget);
        expect(find.byKey(const ValueKey('ride-rating-tag-Rude')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('ride-rating-tag-Friendly')));
        await tester.tap(find.byKey(const ValueKey('ride-rating-tag-Clean car')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(repo.saved, hasLength(1), reason: 'taps are gathered');
        await tester.pump(rideRatingTagsSaveAfter);
        await tester.pumpAndSettle();
        expect(repo.tagsSent.last, ['Clean car', 'Friendly'], reason: 'in the list\'s order');

        // Down to 2 stars: the 4-5 star tags go, the low list shows.
        await tester.tap(find.byKey(const ValueKey('rate-star-2')));
        await tester.pumpAndSettle();
        expect(find.text('What went wrong?'), findsOneWidget);
        expect(repo.tagsSent.last, isEmpty);
        expect(find.byKey(const ValueKey('ride-rating-tag-Rude')), findsOneWidget);
        expect(find.textContaining('Your driver sees totals only'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('Skip shows until a star is given, and calls back', (tester) async {
        var skipped = 0;
        await pump(tester, _ride(), onSkip: () => skipped++);
        final skip = find.byKey(const ValueKey('ride-rating-skip'));
        expect(skip, findsOneWidget);
        final size = tester.getSize(skip);
        expect(size.width >= 120 && size.height >= 48, isTrue, reason: 'an easy target');
        await tester.tap(skip);
        expect(skipped, 1);
        await tester.tap(find.byKey(const ValueKey('rate-star-4')));
        await tester.pumpAndSettle();
        expect(skip, findsNothing);
      });

      testWidgets('no Skip without somewhere to go, or once rated', (tester) async {
        await pump(tester, _ride());
        expect(find.byKey(const ValueKey('ride-rating-skip')), findsNothing);
        await pump(tester, _ride(), repo: _Repo(existing: const RideRating(stars: 4)), onSkip: () {});
        expect(find.byKey(const ValueKey('ride-rating-skip')), findsNothing);
      });

      testWidgets('only a completed trip is rated', (tester) async {
        await pump(tester, _ride(status: 'on_trip'));
        expect(find.byKey(const ValueKey('ride-rating-card')), findsNothing);
      });

      testWidgets('an older database says ratings are not available yet', (tester) async {
        await pump(tester, _ride(), repo: _Repo(unavailable: true));
        await tester.tap(find.byKey(const ValueKey('rate-star-3')));
        await tester.pumpAndSettle();
        expect(find.text('Ratings aren\'t available yet.'), findsOneWidget);
        expect(find.byKey(const ValueKey('ride-rating-card')), findsOneWidget);
      });

      testWidgets('a refusal is put in words', (tester) async {
        await pump(
          tester,
          _ride(),
          repo: _Repo(refuse: const PostgrestException(message: 'too_late')),
        );
        await tester.tap(find.byKey(const ValueKey('rate-star-3')));
        await tester.pumpAndSettle();
        expect(find.text('It\'s too late to rate this trip.'), findsOneWidget);
      });
    });
  }
}
