// Post-trip star ratings (migration 0159): the passenger rates the driver
// 1–5 stars with an optional short comment, once per ride, and may change it
// until [rideRatingWindow] after drop-off. Pure: the repository is
// lib/src/data/ride_rating_repository.dart, the card
// lib/src/widgets/ride_rating_card.dart.

/// How long after drop-off a rating can be given or changed (the server
/// allows 7 days).
const rideRatingWindow = Duration(days: 7);

/// The longest comment the server keeps.
const rideRatingCommentMax = 500;

/// Whether the passenger may still rate (or re-rate) a trip that completed
/// at [completedAt].
bool canRateRide({required bool completed, DateTime? completedAt, required DateTime now}) =>
    completed && completedAt != null && now.difference(completedAt) < rideRatingWindow;

/// Whether [stars] is a rating the server accepts.
bool validStars(int? stars) => stars != null && stars >= 1 && stars <= 5;

/// The comment as it is sent: trimmed, at most [rideRatingCommentMax]
/// characters; null when there is none.
String? cleanRatingComment(String? input) {
  final s = (input ?? '').trim();
  if (s.isEmpty) return null;
  return s.length > rideRatingCommentMax ? s.substring(0, rideRatingCommentMax) : s;
}

/// A short word for a star count, under the stars.
String starsLabel(int stars) => switch (stars) {
  1 => 'Poor',
  2 => 'Fair',
  3 => 'Good',
  4 => 'Very good',
  5 => 'Excellent',
  _ => 'Tap a star to rate',
};

class RideRating {
  const RideRating({required this.stars, this.comment, this.updatedAt});

  final int stars;
  final String? comment;
  final DateTime? updatedAt;

  factory RideRating.fromRow(Map<String, dynamic> m) => RideRating(
    stars: (m['stars'] as num?)?.toInt() ?? 0,
    comment: cleanRatingComment(m['comment'] as String?),
    updatedAt: DateTime.tryParse('${m['updated_at'] ?? ''}'),
  );

  @override
  bool operator ==(Object other) => other is RideRating && other.stars == stars && other.comment == comment;

  @override
  int get hashCode => Object.hash(stars, comment);
}

/// What saving a rating came to.
sealed class RateRideResult {
  const RateRideResult();
}

/// Saved; [partnerRating] is the driver's new average when the server said.
class RatingSaved extends RateRideResult {
  const RatingSaved(this.rating, {this.partnerRating});
  final RideRating rating;
  final double? partnerRating;
}

/// The database doesn't have ratings yet (before migration 0159).
class RatingUnavailable extends RateRideResult {
  const RatingUnavailable();
}

/// The server's refusal, in words.
String rideRatingError(Object e) {
  final s = '$e';
  if (s.contains('too_late')) return 'It\'s too late to rate this trip.';
  if (s.contains('not_completed')) return 'You can rate the trip once it has finished.';
  if (s.contains('bad_stars')) return 'Choose 1 to 5 stars.';
  if (s.contains('not_authorized')) return 'Only the passenger can rate this trip.';
  return 'Couldn\'t save your rating. Check your connection and try again.';
}
