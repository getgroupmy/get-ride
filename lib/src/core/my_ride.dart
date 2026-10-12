// My Ride — favourite drivers (migration 0160). A rider adds a driver by the
// driver's My Ride code (or its QR, `getride://myride/<CODE>`), and may book
// with My Ride on: the request goes to the picked favourites first, for the
// vehicle service's window, then opens to every nearby driver on its own.
// A driver may hide a rider who added them; the rider then just sees the
// driver as unavailable.
//
// Pure: the repository is lib/src/data/my_ride_repository.dart.

/// The QR payload prefix: a driver's QR encodes `getride://myride/<CODE>`.
const myRideQrPrefix = 'getride://myride/';

/// The characters a code is made of (no 0/O, 1/I), as the server makes them.
const myRideCodeAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

/// How long a code is.
const myRideCodeLength = 8;

/// How many favourites a rider may keep (the server's limit).
const myRideMaxFavourites = 50;

/// How many favourites one request may be offered to first.
const myRideMaxTargets = 20;

final _codePattern = RegExp('^[$myRideCodeAlphabet]{$myRideCodeLength}\$');

/// The QR payload for [code].
String myRideQrPayload(String code) => '$myRideQrPrefix${code.trim().toUpperCase()}';

/// The code in a scanned QR or a typed entry, normalised (upper case, no
/// spaces or dashes); null when it can't be a code. Accepts the QR payload
/// (any case, with or without a trailing slash) and a bare code.
String? parseMyRideCode(String? input) {
  var s = (input ?? '').trim();
  if (s.isEmpty) return null;
  if (s.toLowerCase().startsWith(myRideQrPrefix)) {
    s = s.substring(myRideQrPrefix.length);
  } else if (s.contains('://')) {
    // Some other link: not a My Ride QR.
    return null;
  }
  s = s.replaceAll(RegExp(r'[\s/-]'), '').toUpperCase();
  return _codePattern.hasMatch(s) ? s : null;
}

/// The code as shown to the driver: two groups of four (`ABCD EFGH`).
String formatMyRideCode(String code) {
  final c = code.trim().toUpperCase();
  return c.length == myRideCodeLength ? '${c.substring(0, 4)} ${c.substring(4)}' : c;
}

/// The farthest a favourite may be from the pickup to be offered the ride:
/// the smaller of the rider's own setting and the service's, where each
/// counts only when positive (0 / null = no limit). Null is no limit.
double? effectiveMyRideMaxKm(double? riderKm, double? serviceKm) {
  final limits = [riderKm, serviceKm].whereType<double>().where((v) => v > 0 && v.isFinite).toList();
  if (limits.isEmpty) return null;
  return limits.reduce((a, b) => a < b ? a : b);
}

/// Whether a request is still inside its favourites window at [now].
bool myRideWindowOpen({required List<String> targets, DateTime? targetedUntil, required DateTime now}) =>
    targets.isNotEmpty && targetedUntil != null && targetedUntil.isAfter(now);

/// What is left of the favourites window at [now]; null when there is no
/// window running.
Duration? myRideWindowRemaining({required List<String> targets, DateTime? targetedUntil, required DateTime now}) {
  if (!myRideWindowOpen(targets: targets, targetedUntil: targetedUntil, now: now)) return null;
  return targetedUntil!.difference(now);
}

/// Whether a request gets the driver's gold star: it is offered to [me] as a
/// favourite, or its rider has [me] as a favourite (and isn't hidden —
/// [favouriteRiderIds] comes from `my_favourite_rider_ids()`, which leaves
/// hidden riders out).
bool isStarredFor({
  required String? riderId,
  required List<String> targetDriverIds,
  required String? me,
  required Set<String> favouriteRiderIds,
}) {
  if (me == null) return false;
  if (targetDriverIds.contains(me)) return true;
  return riderId != null && favouriteRiderIds.contains(riderId);
}

/// Starred requests first, keeping the order within each group.
List<T> pinStarredFirst<T>(List<T> requests, bool Function(T) starred) => [
  ...requests.where(starred),
  ...requests.where((r) => !starred(r)),
];

// ---- Vehicle service settings ------------------------------------------------

/// The `vehicle-services` settings keys the dispatch reads (0160).
const searchRadiusMinKmKey = 'searchRadiusMinKm';
const searchRadiusMaxKmKey = 'searchRadiusMaxKm';
const searchWidenAfterSecKey = 'searchWidenAfterSec';
const myRideMaxKmKey = 'myRideMaxKm';
const myRideWindowSecKey = 'myRideWindowSec';

/// A vehicle service's dispatch settings, as the server reads them: a
/// missing or non-positive value takes the default.
class ServiceDispatchConfig {
  const ServiceDispatchConfig({
    this.searchRadiusMinKm = defaultMinKm,
    this.searchRadiusMaxKm = defaultMaxKm,
    this.widenAfter = const Duration(seconds: defaultWidenSec),
    this.myRideMaxKm,
    this.myRideWindow = const Duration(seconds: defaultWindowSec),
  });

  static const defaultMinKm = 3.0;
  static const defaultMaxKm = 15.0;
  static const defaultWidenSec = 30;
  static const defaultWindowSec = 60;

  final double searchRadiusMinKm;
  final double searchRadiusMaxKm;
  final Duration widenAfter;

  /// Null is no limit.
  final double? myRideMaxKm;
  final Duration myRideWindow;

  /// From a `vehicle-services` entry's values (the same clamps as the server).
  factory ServiceDispatchConfig.fromValues(Map<String, dynamic>? values) {
    double? pos(String key) {
      final v = values?[key];
      final n = v is num ? v.toDouble() : double.tryParse('${v ?? ''}'.trim());
      return n != null && n.isFinite && n > 0 ? n : null;
    }

    final min = (pos(searchRadiusMinKmKey) ?? defaultMinKm).clamp(0, 200).toDouble();
    final max = (pos(searchRadiusMaxKmKey) ?? defaultMaxKm).clamp(min, 200).toDouble();
    final widen = (pos(searchWidenAfterSecKey) ?? defaultWidenSec).round().clamp(5, 3600);
    final window = (pos(myRideWindowSecKey) ?? defaultWindowSec).round().clamp(5, 600);
    return ServiceDispatchConfig(
      searchRadiusMinKm: min,
      searchRadiusMaxKm: max,
      widenAfter: Duration(seconds: widen),
      myRideMaxKm: pos(myRideMaxKmKey),
      myRideWindow: Duration(seconds: window),
    );
  }
}

// ---- Rows ------------------------------------------------------------------------

/// When a favourite driver was last seen taking rides.
enum LastSeen {
  online,
  recent,
  today,
  away;

  static LastSeen? parse(Object? v) => switch (v) {
    'online' => LastSeen.online,
    'recent' => LastSeen.recent,
    'today' => LastSeen.today,
    'away' => LastSeen.away,
    _ => null,
  };

  String get label => switch (this) {
    LastSeen.online => 'Online',
    LastSeen.recent => 'Seen in the last hour',
    LastSeen.today => 'Seen today',
    LastSeen.away => 'Away',
  };
}

String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
double? _n(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// One of the rider's favourite drivers (`my_favourite_drivers()`). Only what
/// a rider sees of a driver on a ride, never a phone number.
class FavouriteDriver {
  const FavouriteDriver({
    required this.driverId,
    required this.name,
    this.addedAt,
    this.available = false,
    this.online = false,
    this.lastSeen,
    this.distanceKm,
    this.avatarUrl,
    this.vehicle,
    this.make,
    this.model,
    this.colour,
    this.plate,
    this.rating,
  });

  final String driverId;
  final String name;
  final DateTime? addedAt;

  /// False when the driver can't be offered rides (they hid this rider, or
  /// can't take rides); the two read alike on purpose.
  final bool available;
  final bool online;
  final LastSeen? lastSeen;

  /// Km to the point asked about, to the nearest 0.5, while online.
  final double? distanceKm;
  final String? avatarUrl;
  final String? vehicle;
  final String? make;
  final String? model;
  final String? colour;
  final String? plate;
  final double? rating;

  factory FavouriteDriver.fromRow(Map<String, dynamic> row) => FavouriteDriver(
    driverId: '${row['driver_id']}',
    name: _s(row['name']) ?? 'Driver',
    addedAt: _date(row['added_at']),
    available: row['available'] == true,
    online: row['online'] == true,
    lastSeen: LastSeen.parse(row['last_seen']),
    distanceKm: _n(row['distance_km']),
    avatarUrl: _s(row['avatar_url']),
    vehicle: _s(row['vehicle']),
    make: _s(row['make']),
    model: _s(row['model']),
    colour: _s(row['colour']),
    plate: _s(row['plate']),
    rating: _n(row['rating']),
  );

  /// "White Perodua Bezza", or whichever parts are known; the free-text
  /// vehicle where there are none.
  String? get vehicleLabel {
    final parts = [colour, make, model].whereType<String>().toList();
    return parts.isNotEmpty ? parts.join(' ') : vehicle;
  }
}

/// A rider who has the driver as a favourite (`my_favourite_riders()`); the
/// name is masked ("Aminah A.").
class FavouriteRider {
  const FavouriteRider({
    required this.riderId,
    required this.name,
    this.addedAt,
    this.hidden = false,
    this.hiddenAt,
    this.ridesTogether = 0,
  });

  final String riderId;
  final String name;
  final DateTime? addedAt;
  final bool hidden;
  final DateTime? hiddenAt;
  final int ridesTogether;

  factory FavouriteRider.fromRow(Map<String, dynamic> row) => FavouriteRider(
    riderId: '${row['rider_id']}',
    name: _s(row['name']) ?? 'Rider',
    addedAt: _date(row['added_at']),
    hidden: row['hidden'] == true,
    hiddenAt: _date(row['hidden_at']),
    ridesTogether: _n(row['rides_together'])?.toInt() ?? 0,
  );
}

// ---- Adding by code -------------------------------------------------------------

/// Why a code was not added.
enum AddFavouriteError {
  invalidCode,
  notFound,
  ownCode,
  unavailable,
  limitReached,
  rateLimited,
  noProfile,
  unknown;

  static AddFavouriteError parse(Object? v) => switch (v) {
    'invalid_code' => AddFavouriteError.invalidCode,
    'not_found' => AddFavouriteError.notFound,
    'own_code' => AddFavouriteError.ownCode,
    'unavailable' => AddFavouriteError.unavailable,
    'limit_reached' => AddFavouriteError.limitReached,
    'rate_limited' => AddFavouriteError.rateLimited,
    'no_profile' => AddFavouriteError.noProfile,
    _ => AddFavouriteError.unknown,
  };

  String get message => switch (this) {
    AddFavouriteError.invalidCode => "That doesn't look like a My Ride code. Codes are 8 letters and numbers.",
    AddFavouriteError.notFound => 'No driver has that code. Check it with your driver.',
    AddFavouriteError.ownCode => "That's your own code.",
    AddFavouriteError.unavailable => "This driver can't be added right now.",
    AddFavouriteError.limitReached =>
      'You have $myRideMaxFavourites favourite drivers already. Remove one to add another.',
    AddFavouriteError.rateLimited => 'Too many codes tried. Please wait a while and try again.',
    AddFavouriteError.noProfile => 'Finish setting up your account first.',
    AddFavouriteError.unknown => "Couldn't add the driver. Please try again.",
  };
}

/// What adding a driver by code came to.
sealed class AddFavouriteResult {
  const AddFavouriteResult();

  /// From `add_favourite_driver`'s reply.
  factory AddFavouriteResult.fromJson(Object? json) {
    final m = json is Map ? Map<String, dynamic>.from(json) : const <String, dynamic>{};
    if (m['ok'] == true) {
      final d = m['driver'];
      return FavouriteAdded(
        d is Map ? FavouriteDriver.fromRow({...Map<String, dynamic>.from(d), 'available': true}) : null,
      );
    }
    final wait = _n(m['retry_after'])?.toInt();
    return FavouriteNotAdded(
      AddFavouriteError.parse(m['error']),
      retryAfter: wait != null && wait > 0 ? Duration(seconds: wait) : null,
    );
  }
}

class FavouriteAdded extends AddFavouriteResult {
  const FavouriteAdded(this.driver);

  /// The driver's card; null if the server sent none.
  final FavouriteDriver? driver;
}

class FavouriteNotAdded extends AddFavouriteResult {
  const FavouriteNotAdded(this.error, {this.retryAfter});
  final AddFavouriteError error;
  final Duration? retryAfter;
}

/// The database doesn't have My Ride yet (migration 0160 not applied).
class MyRideNotAvailable extends AddFavouriteResult {
  const MyRideNotAvailable();
}

/// What "Offer to all nearby" came to.
enum OfferToAllOutcome {
  /// The window was ended and nearby drivers told.
  opened,

  /// It was already open to everybody.
  alreadyOpen,

  /// The request is no longer open (taken, cancelled, expired).
  notOpen,

  /// The database doesn't have My Ride yet.
  unavailable;

  static OfferToAllOutcome fromJson(Object? json) {
    final m = json is Map ? json : const {};
    if (m['ok'] != true) return OfferToAllOutcome.notOpen;
    return m['opened'] == true ? OfferToAllOutcome.opened : OfferToAllOutcome.alreadyOpen;
  }
}
