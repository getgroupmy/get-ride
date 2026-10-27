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
  const RideRating({required this.stars, this.comment, this.updatedAt, this.tags = const []});

  final int stars;
  final String? comment;
  final DateTime? updatedAt;

  /// The tags picked with the stars (0297).
  final List<String> tags;

  factory RideRating.fromRow(Map<String, dynamic> m) => RideRating(
    stars: (m['stars'] as num?)?.toInt() ?? 0,
    comment: cleanRatingComment(m['comment'] as String?),
    updatedAt: DateTime.tryParse('${m['updated_at'] ?? ''}'),
    tags: [for (final t in (m['tags'] as List?) ?? const []) if (t is String && t.trim().isNotEmpty) t],
  );

  @override
  bool operator ==(Object other) =>
      other is RideRating && other.stars == stars && other.comment == comment && _sameList(other.tags, tags);

  @override
  int get hashCode => Object.hash(stars, comment, Object.hashAll(tags));
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---- Tags on the rating (0297) ---------------------------------------------

/// The tags a rider picks after rating a driver, as the admin keeps them:
/// [high] for 4-5 stars ("What went well?"), [low] for 1-3 ("What went
/// wrong?").
class DriverRatingTags {
  const DriverRatingTags({this.high = const [], this.low = const []});

  final List<String> high, low;

  /// Before the admin's list is read (or on a database before 0297).
  static const fallback = DriverRatingTags(
    high: ['Safe driving', 'Clean car', 'Friendly', 'Knew the way', 'On time'],
    low: ['Late to pickup', 'Unsafe driving', 'Dirty car', 'Wrong route', 'Rude'],
  );

  /// Active rows of driver_rating_tags, in the admin's order.
  factory DriverRatingTags.fromRows(List<Map<String, dynamic>> rows) {
    final sorted = [...rows]..sort((a, b) => ((a['position'] as num?) ?? 0).compareTo((b['position'] as num?) ?? 0));
    List<String> of(bool low) => [
      for (final r in sorted)
        if (r['active'] != false && (r['low'] == true) == low && '${r['tag'] ?? ''}'.trim().isNotEmpty) '${r['tag']}'.trim(),
    ];
    return DriverRatingTags(high: of(false), low: of(true));
  }

  /// The list for [stars]; none before a star is picked.
  List<String> forStars(int? stars) => stars == null || stars < 1 ? const [] : (stars <= 3 ? low : high);
}

/// "What went wrong?" for 1-3 stars, "What went well?" for 4-5.
String driverTagQuestion(int stars) => stars <= 3 ? 'What went wrong?' : 'What went well?';

/// [picked] kept to the list for [stars], in that list's order.
List<String> keepDriverTags(Set<String> picked, int? stars, DriverRatingTags tags) =>
    [for (final t in tags.forStars(stars)) if (picked.contains(t)) t];

/// The driver's totals per tag (my_driver_rating_tags): counts only.
class DriverTagTotals {
  const DriverTagTotals({this.days = 30, this.rating, this.rated = 0, this.tags = const []});

  final int days;
  final double? rating;
  final int rated;
  final List<({String tag, bool low, int n})> tags;

  List<({String tag, bool low, int n})> get liked => [for (final t in tags) if (!t.low) t];
  List<({String tag, bool low, int n})> get toWorkOn => [for (final t in tags) if (t.low) t];

  factory DriverTagTotals.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    final list = m['tags'];
    return DriverTagTotals(
      days: (m['days'] as num?)?.toInt() ?? 30,
      rating: (m['rating'] as num?)?.toDouble(),
      rated: (m['rated'] as num?)?.toInt() ?? 0,
      tags: [
        if (list is List)
          for (final t in list)
            if (t is Map && '${t['tag'] ?? ''}'.trim().isNotEmpty)
              (tag: '${t['tag']}', low: t['low'] == true, n: (t['n'] as num?)?.toInt() ?? 0),
      ],
    );
  }
}

/// Seconds the trip summary shows after a rating (or Skip) before it closes.
const tripSummaryCloseAfter = Duration(seconds: 3);

/// The line on the trip summary: what the rider gave, if anything.
String tripSummaryRatedLine(int? stars) =>
    stars == null || stars < 1 ? 'Not rated.' : 'You rated $stars star${stars == 1 ? '' : 's'}.';

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
