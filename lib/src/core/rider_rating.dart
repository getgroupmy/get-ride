// Drivers rate riders (migration 0269): the stars and tags a driver gives
// after a trip, the admin's settings, and the badge a driver sees on a
// request ("New rider", "Low"). Pure.

/// Tags for 3 stars or less.
const riderLowTags = ['Late to pickup', 'Rude', 'Wrong pickup point', 'Left a mess', 'Unsafe request'];

/// Tags for 4 or 5 stars.
const riderHighTags = ['Polite', 'On time', 'Clear directions'];

/// The tags offered for [stars] (none before a star is picked).
List<String> riderTagsFor(int stars) => stars <= 0 ? const [] : (stars <= 3 ? riderLowTags : riderHighTags);

/// [picked] kept to the tags [stars] offers (a change of stars drops the others).
Set<String> keepRiderTags(Set<String> picked, int stars) => picked.intersection(riderTagsFor(stars).toSet());

/// How long after the drop-off a driver can still rate (from trip history
/// after a Skip); the server allows the same.
const rateRiderWindow = Duration(hours: 24);

bool canRateRider({required bool completed, DateTime? completedAt, required DateTime now, bool alreadyRated = false}) =>
    completed && !alreadyRated && completedAt != null && now.difference(completedAt) < rateRiderWindow;

/// Admin > App Settings > Rider ratings (app_settings 'rider_rating').
class RiderRatingSettings {
  const RiderRatingSettings({this.window = 100, this.newBelow = 5, this.lowBelow = 4.0});

  static const standard = RiderRatingSettings();

  /// The average is over the rider's last this many ratings.
  final int window;

  /// "New rider" until they have this many ratings.
  final int newBelow;

  /// "Low" below this average.
  final double lowBelow;

  factory RiderRatingSettings.fromJson(Object? json) {
    if (json is! Map) return standard;
    return RiderRatingSettings(
      window: json['window'] is num ? (json['window'] as num).round().clamp(5, 1000) : 100,
      newBelow: json['newBelow'] is num ? (json['newBelow'] as num).round().clamp(0, 50) : 5,
      lowBelow: json['lowBelow'] is num ? (json['lowBelow'] as num).toDouble().clamp(1.0, 5.0) : 4.0,
    );
  }

  Map<String, dynamic> toJson() => {'window': window, 'newBelow': newBelow, 'lowBelow': lowBelow};

  @override
  bool operator ==(Object other) =>
      other is RiderRatingSettings && other.window == window && other.newBelow == newBelow && other.lowBelow == lowBelow;

  @override
  int get hashCode => Object.hash(window, newBelow, lowBelow);
}

enum RiderBadge { none, newRider, low }

/// The badge on a request: "New rider" with fewer ratings than the
/// setting's, else "Low" below its average. [ratings] null (an older
/// server) shows no badge.
RiderBadge riderBadge({double? rating, int? ratings, RiderRatingSettings s = RiderRatingSettings.standard}) {
  if (ratings == null) return RiderBadge.none;
  if (ratings < s.newBelow) return RiderBadge.newRider;
  if (rating != null && rating < s.lowBelow - 1e-9) return RiderBadge.low;
  return RiderBadge.none;
}

/// "4.8 · 126 trips" next to a rider's name; just the trips for a new rider.
String riderRatingLine({double? rating, int? ratings, int? trips, RiderRatingSettings s = RiderRatingSettings.standard}) {
  final parts = <String>[
    if (rating != null && riderBadge(rating: rating, ratings: ratings, s: s) != RiderBadge.newRider)
      rating.toStringAsFixed(1),
    if (trips != null) '$trips ${trips == 1 ? 'trip' : 'trips'}',
  ];
  return parts.join(' · ');
}

/// What the rider sees of their own rating on Profile.
String ownRiderRatingText({double? rating, int ratings = 0, RiderRatingSettings s = RiderRatingSettings.standard}) {
  if (rating == null || ratings == 0) return 'No ratings yet';
  final n = ratings == 1 ? '1 rating' : '$ratings ratings';
  return '${rating.toStringAsFixed(2)} from $n';
}

/// The server's refusal, in words.
String rateRiderError(Object e) {
  final s = '$e';
  if (s.contains('too_late')) return 'It\'s too late to rate this trip.';
  if (s.contains('not_completed')) return 'You can rate a rider once the trip is finished.';
  return 'Couldn\'t send the rating. Check your connection and try again.';
}
