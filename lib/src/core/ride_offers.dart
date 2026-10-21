// Many offers at once (migration 0269): the drivers' offers on a rider's
// open request, each its own `ride_offers` row, the admin's settings, and
// how the rider's searching screen orders and queues them. Pure.
//
// The single bid on the request row (core/ride_bidding.dart) is still filled
// by the server with the latest open offer, for older apps.
import 'ride_bidding.dart' show OfferOutcome;

/// How the rider orders the offers (the chips: Cheapest, Nearest, Top rated).
enum OfferSort {
  cheapest('Cheapest'),
  nearest('Nearest'),
  rating('Top rated');

  const OfferSort(this.label);
  final String label;

  static OfferSort parse(Object? v) => switch (v) {
    'nearest' => OfferSort.nearest,
    'rating' => OfferSort.rating,
    _ => OfferSort.cheapest,
  };
}

/// Admin > App Settings > Ride offers (app_settings 'city_ride_offers').
class OfferSettings {
  const OfferSettings({
    this.shown = defaultShown,
    this.lifetime = const Duration(seconds: defaultLifetimeSeconds),
    this.sort = OfferSort.cheapest,
    this.reofferAfterDecline = true,
  });

  static const defaultShown = 5, defaultLifetimeSeconds = 15;
  static const minShown = 1, maxShown = 10, minLifetime = 5, maxLifetime = 120;
  static const standard = OfferSettings();

  /// Offers on screen at once; the rest wait in line.
  final int shown;

  /// How long an offer stands.
  final Duration lifetime;

  /// The order the rider first sees.
  final OfferSort sort;

  /// A driver may offer again, once, after the rider declined them.
  final bool reofferAfterDecline;

  factory OfferSettings.fromJson(Object? json) {
    if (json is! Map) return standard;
    int n(Object? v, int fallback, int lo, int hi) => v is num ? v.round().clamp(lo, hi) : fallback;
    return OfferSettings(
      shown: n(json['shown'], defaultShown, minShown, maxShown),
      lifetime: Duration(seconds: n(json['lifetimeSeconds'], defaultLifetimeSeconds, minLifetime, maxLifetime)),
      sort: OfferSort.parse(json['sort']),
      reofferAfterDecline: json['reofferAfterDecline'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
    'shown': shown,
    'lifetimeSeconds': lifetime.inSeconds,
    'sort': sort.name,
    'reofferAfterDecline': reofferAfterDecline,
  };

  @override
  bool operator ==(Object other) =>
      other is OfferSettings &&
      other.shown == shown &&
      other.lifetime == lifetime &&
      other.sort == sort &&
      other.reofferAfterDecline == reofferAfterDecline;

  @override
  int get hashCode => Object.hash(shown, lifetime, sort, reofferAfterDecline);
}

/// Where an offer stands (`ride_offers.status`).
enum OfferStatus { open, declined, expired, accepted, withdrawn }

OfferStatus parseOfferStatus(Object? v) => switch (v) {
  'declined' => OfferStatus.declined,
  'expired' => OfferStatus.expired,
  'accepted' => OfferStatus.accepted,
  'withdrawn' => OfferStatus.withdrawn,
  _ => OfferStatus.open,
};

/// One `ride_offers` row.
class RideOfferRow {
  const RideOfferRow({
    required this.id,
    required this.requestId,
    required this.partnerId,
    required this.amount,
    required this.createdAt,
    required this.expiresAt,
    this.status = OfferStatus.open,
    this.closedReason,
    this.etaMin,
    this.fromLat,
    this.fromLng,
    this.name,
    this.photo,
    this.rating,
    this.trips,
    this.vehicle,
    this.plate,
    this.plateColours,
  });

  final String id, requestId, partnerId;
  final double amount;
  final DateTime createdAt, expiresAt;
  final OfferStatus status;

  /// Why it closed: declined, expired, taken, raised, replaced, cancelled, withdrawn.
  final String? closedReason;
  final int? etaMin;
  final double? fromLat, fromLng;
  final String? name, photo, vehicle, plate;
  final double? rating;
  final int? trips;
  final Map<String, dynamic>? plateColours;

  /// Still standing at [now].
  bool isLive(DateTime now) => status == OfferStatus.open && now.isBefore(expiresAt);

  /// Another driver got the ride.
  bool get takenByOther => status == OfferStatus.withdrawn && closedReason == 'taken';

  /// What is left of its window at [now], 1 → 0.
  double progress(DateTime now) {
    final total = expiresAt.difference(createdAt).inMilliseconds;
    if (total <= 0) return 0;
    return (expiresAt.difference(now).inMilliseconds / total).clamp(0.0, 1.0);
  }

  static RideOfferRow? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    double? d(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    final amount = d(m['amount']);
    final created = DateTime.tryParse('${m['created_at'] ?? ''}');
    final expires = DateTime.tryParse('${m['expires_at'] ?? ''}');
    if (m['id'] == null || m['partner_id'] == null || amount == null || created == null || expires == null) {
      return null;
    }
    final colours = m['partner_plate_colours'];
    return RideOfferRow(
      id: '${m['id']}',
      requestId: '${m['request_id']}',
      partnerId: '${m['partner_id']}',
      amount: amount,
      createdAt: created,
      expiresAt: expires,
      status: parseOfferStatus(m['status']),
      closedReason: m['closed_reason'] as String?,
      etaMin: (m['eta_min'] as num?)?.toInt(),
      fromLat: d(m['from_lat']),
      fromLng: d(m['from_lng']),
      name: m['partner_name'] as String?,
      photo: m['partner_photo'] as String?,
      rating: d(m['partner_rating']),
      trips: (m['partner_trips'] as num?)?.toInt(),
      vehicle: m['partner_vehicle'] as String?,
      plate: m['partner_plate'] as String?,
      plateColours: colours is Map ? Map<String, dynamic>.from(colours) : null,
    );
  }
}

/// [offers] in [sort]'s order: cheapest (then nearer), nearest (then
/// cheaper) or top rated (then cheaper). Unknowns go last; ties keep the
/// order they came in.
List<T> sortOfferList<T>(
  List<T> offers,
  OfferSort sort, {
  required double? Function(T) amount,
  required int? Function(T) eta,
  required double? Function(T) rating,
}) {
  int byAmount(T a, T b) => (amount(a) ?? double.infinity).compareTo(amount(b) ?? double.infinity);
  int byEta(T a, T b) => (eta(a) ?? 1 << 20).compareTo(eta(b) ?? 1 << 20);
  int byRating(T a, T b) => (rating(b) ?? -1).compareTo(rating(a) ?? -1);
  final order = switch (sort) {
    OfferSort.cheapest => [byAmount, byEta],
    OfferSort.nearest => [byEta, byAmount],
    OfferSort.rating => [byRating, byAmount, byEta],
  };
  final indexed = offers.indexed.toList();
  indexed.sort((a, b) {
    for (final c in order) {
      final r = c(a.$2, b.$2);
      if (r != 0) return r;
    }
    return a.$1.compareTo(b.$1);
  });
  return [for (final (_, o) in indexed) o];
}

/// The offers on screen and how many wait in line: the first [shown] of
/// [ordered]. A card already on screen ([onScreen], by key) keeps its place
/// while it stands, so a cheaper one arriving queues instead of pushing it
/// off; the free places go to the best of the rest.
({List<T> shown, int waiting}) offerQueue<T>(
  List<T> ordered, {
  required int shown,
  required String Function(T) key,
  Set<String> onScreen = const {},
}) {
  final limit = shown < 1 ? 1 : shown;
  final kept = [for (final o in ordered) if (onScreen.contains(key(o))) o].take(limit).toList();
  final keptKeys = {for (final o in kept) key(o)};
  final room = limit - kept.length;
  final added = [for (final o in ordered) if (!keptKeys.contains(key(o))) o].take(room).toSet();
  final out = [for (final o in ordered) if (keptKeys.contains(key(o)) || added.contains(o)) o];
  return (shown: out, waiting: ordered.length - out.length);
}

/// The key of the offer the "Lowest" badge goes on: the cheapest of two or
/// more (the first to come in when they tie); null with fewer than two or
/// when none has an amount.
String? lowestOfferKey<T>(List<T> offers, {required double? Function(T) amount, required String Function(T) key}) {
  if (offers.length < 2) return null;
  T? best;
  for (final o in offers) {
    final a = amount(o);
    if (a == null) continue;
    final b = best == null ? null : amount(best as T);
    if (b == null || a < b - 0.004) best = o;
  }
  return best == null ? null : key(best as T);
}

/// "+3 more waiting" under the cards; null with none.
String? offersWaitingLabel(int waiting) => waiting <= 0 ? null : '+$waiting more waiting';

/// The server's refusal of an offer or an accept, in words.
String rideOfferError(Object e) {
  final s = '$e';
  if (s.contains('OFFERS_PAUSED')) {
    final at = RegExp(r'again at (\d{1,2}:\d{2})').firstMatch(s)?.group(1);
    return at == null
        ? 'You cancelled too many rides this week, so offers are paused for a while.'
        : 'You cancelled too many rides this week. You can send offers again at $at.';
  }
  if (s.contains('OFFER_DECLINED')) return 'The rider declined your offer.';
  if (s.contains('OFFER_AMOUNT')) return 'Offer the rider\'s fare or more, up to 4 times it.';
  if (s.contains('OFFER_REQUEST_CLOSED')) return 'This request is no longer open.';
  if (s.contains('OFFER_GONE')) return 'That offer is no longer available.';
  if (s.contains('too_many')) return 'Too many offers on this request.';
  return 'Couldn\'t send that. Check your connection and try again.';
}

/// What the driver's own offer row says of it (0269), the way [offerOutcome]
/// reads the request row; null while it stands. An expired offer reads as
/// declined with [expired] true.
({OfferOutcome outcome, bool expired})? rowOfferOutcome(RideOfferRow o) => switch (o.status) {
  OfferStatus.open => null,
  OfferStatus.accepted => (outcome: OfferOutcome.won, expired: false),
  OfferStatus.declined => (outcome: OfferOutcome.declined, expired: false),
  OfferStatus.expired => (outcome: OfferOutcome.declined, expired: true),
  OfferStatus.withdrawn => switch (o.closedReason) {
    'taken' => (outcome: OfferOutcome.outbid, expired: false),
    'raised' => (outcome: OfferOutcome.raised, expired: false),
    'cancelled' => (outcome: OfferOutcome.closed, expired: false),
    'replaced' => null,
    _ => (outcome: OfferOutcome.declined, expired: false),
  },
};
