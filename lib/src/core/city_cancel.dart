// City ride cancel and no-show rules by place (migration 0269): what a
// rider's cancel costs and when, when the driver's "Rider didn't come"
// unlocks, and a driver's own cancel rate. Pure. The server works the fee
// out the same way (ride_cancel_fee) and is the one that charges it.
import '../data/models.dart';

/// The rules at a place: Default, or a country / state / city / suburb's own
/// (Admin > App Settings > Cancel and no-show). Null fields inherit.
class CancelRules {
  const CancelRules({
    this.freeMinutes = 2,
    this.lateFee = 3,
    this.arrivedFee = 5,
    this.noShowMinutes = 5,
    this.noShowFee = 5,
  });

  static const standard = CancelRules();

  /// Free to cancel for this long after a driver accepts.
  final double freeMinutes;

  /// After that, before the driver arrives.
  final double lateFee;

  /// After the driver arrived.
  final double arrivedFee;

  /// How long the driver waits at the pickup before "Rider didn't come".
  final double noShowMinutes;
  final double noShowFee;

  static const keys = ['freeMinutes', 'lateFee', 'arrivedFee', 'noShowMinutes', 'noShowFee'];

  factory CancelRules.fromJson(Object? json, {CancelRules base = standard}) {
    if (json is! Map) return base;
    double v(String k, double fallback) {
      final x = json[k];
      return x is num && x >= 0 ? x.toDouble() : fallback;
    }

    return CancelRules(
      freeMinutes: v('freeMinutes', base.freeMinutes),
      lateFee: v('lateFee', base.lateFee),
      arrivedFee: v('arrivedFee', base.arrivedFee),
      noShowMinutes: v('noShowMinutes', base.noShowMinutes),
      noShowFee: v('noShowFee', base.noShowFee),
    );
  }

  Map<String, dynamic> toJson() => {
    'freeMinutes': freeMinutes,
    'lateFee': lateFee,
    'arrivedFee': arrivedFee,
    'noShowMinutes': noShowMinutes,
    'noShowFee': noShowFee,
  };

  Duration get freeTime => Duration(milliseconds: (freeMinutes * 60000).round());
  Duration get noShowWait => Duration(milliseconds: (noShowMinutes * 60000).round());

  @override
  bool operator ==(Object other) =>
      other is CancelRules &&
      other.freeMinutes == freeMinutes &&
      other.lateFee == lateFee &&
      other.arrivedFee == arrivedFee &&
      other.noShowMinutes == noShowMinutes &&
      other.noShowFee == noShowFee;

  @override
  int get hashCode => Object.hash(freeMinutes, lateFee, arrivedFee, noShowMinutes, noShowFee);
}

/// Cancel reasons that are always free: the car isn't coming, or isn't the
/// one booked.
const safetyCancelReasons = {'driver_not_moving', 'wrong_car'};

bool isSafetyCancelReason(String? reason) => safetyCancelReasons.contains(reason?.trim());

/// What a rider's cancel asked at [at] costs: nothing for a safety reason
/// or inside the free time; the arrived fee once the driver arrived; the
/// late fee in between. Kept in step with `ride_cancel_fee` (0269).
double cityCancelFee(
  CancelRules rules, {
  required DateTime? acceptedAt,
  DateTime? arrivedAt,
  required DateTime at,
  String? reason,
}) {
  if (isSafetyCancelReason(reason) || acceptedAt == null) return 0;
  if (arrivedAt != null && !at.isBefore(arrivedAt)) return rules.arrivedFee;
  if (at.isBefore(acceptedAt.add(rules.freeTime))) return 0;
  return rules.lateFee;
}

/// How long the rider can still cancel for free; null once the free time
/// is over (or the driver arrived, or nobody accepted yet).
Duration? freeCancelLeft(CancelRules rules, {required DateTime? acceptedAt, DateTime? arrivedAt, required DateTime now}) {
  if (acceptedAt == null || arrivedAt != null) return null;
  final left = acceptedAt.add(rules.freeTime).difference(now);
  return left > Duration.zero ? left : null;
}

/// How long the driver still waits before "Rider didn't come" unlocks;
/// zero once it has.
Duration noShowLeft(CancelRules rules, {required DateTime arrivedAt, required DateTime now}) {
  final left = arrivedAt.add(rules.noShowWait).difference(now);
  return left.isNegative ? Duration.zero : left;
}

/// "1:05".
String minSec(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The rider's line over Cancel: "Free to cancel for 1:42", or what it costs.
String cancelTermsLine(CancelRules rules, RideRequest r, DateTime now, {String Function(double)? money}) {
  final left = freeCancelLeft(rules, acceptedAt: r.acceptedAt, arrivedAt: r.arrivedAt, now: now);
  if (left != null) return 'Free to cancel for ${minSec(left)}';
  final fee = cityCancelFee(rules, acceptedAt: r.acceptedAt, arrivedAt: r.arrivedAt, at: now);
  if (fee <= 0) return 'Free to cancel';
  final m = money?.call(fee) ?? 'RM ${fee.toStringAsFixed(2)}';
  return r.arrivedAt != null
      ? 'Your driver is here: cancelling now costs $m'
      : 'Cancelling now costs $m. Safety reasons are always free.';
}

/// The Cancel button: "Cancel ride" or "Cancel ride (RM 3.00)".
String cancelButtonLabel(double fee, {String Function(double)? money}) =>
    fee <= 0 ? 'Cancel ride' : 'Cancel ride (${money?.call(fee) ?? 'RM ${fee.toStringAsFixed(2)}'})';

/// Whether a ride is a city ride the rules apply to: taken by a driver,
/// before pickup, not a scheduled booking.
bool cityCancelApplies(RideRequest r) =>
    (r.status == RideStatus.accepted || r.status == RideStatus.arrived) && r.scheduledRideId == null;

/// A driver's own cancels (driver_cancel_stats, 0269).
class DriverCancelStats {
  const DriverCancelStats({
    this.cancels = 0,
    this.rides = 0,
    this.percent = 0,
    this.limitPercent = 20,
    this.days = 7,
    this.pauseMinutes = 30,
    this.minRides = 5,
    this.pausedUntil,
  });

  final int cancels, rides, limitPercent, days, pauseMinutes, minRides;
  final double percent;
  final DateTime? pausedUntil;

  factory DriverCancelStats.fromJson(Object? json) {
    if (json is! Map) return const DriverCancelStats();
    int n(String k, int f) => (json[k] as num?)?.round() ?? f;
    return DriverCancelStats(
      cancels: n('cancels', 0),
      rides: n('rides', 0),
      percent: (json['percent'] as num?)?.toDouble() ?? 0,
      limitPercent: n('limitPercent', 20),
      days: n('days', 7),
      pauseMinutes: n('pauseMinutes', 30),
      minRides: n('minRides', 5),
      pausedUntil: DateTime.tryParse('${json['pausedUntil'] ?? ''}'),
    );
  }

  bool pausedAt(DateTime now) => pausedUntil != null && now.isBefore(pausedUntil!);

  /// Above the limit (with enough rides to count).
  bool get overLimit => rides >= minRides && percent > limitPercent;

  /// "Your cancel rate this week: 12% (3 of 25). Above 20% you can't send
  /// offers for 30 min."
  String describe() {
    final period = days == 7 ? 'this week' : 'in the last $days days';
    final pct = percent == percent.roundToDouble() ? percent.toStringAsFixed(0) : percent.toStringAsFixed(1);
    return 'Your cancel rate $period: $pct% ($cancels of $rides). '
        'Above $limitPercent% you can\'t send offers for $pauseMinutes min.';
  }
}

/// Admin > Driver cancel limit (app_settings 'driver_cancel_limit').
class DriverCancelLimit {
  const DriverCancelLimit({this.limitPercent = 20, this.days = 7, this.pauseMinutes = 30, this.minRides = 5});
  final int limitPercent, days, pauseMinutes, minRides;

  static const standard = DriverCancelLimit();

  factory DriverCancelLimit.fromJson(Object? json) {
    if (json is! Map) return standard;
    int n(String k, int f, int lo, int hi) => json[k] is num ? (json[k] as num).round().clamp(lo, hi) : f;
    return DriverCancelLimit(
      limitPercent: n('limitPercent', 20, 1, 100),
      days: n('days', 7, 1, 30),
      pauseMinutes: n('pauseMinutes', 30, 1, 1440),
      minRides: n('minRides', 5, 1, 100),
    );
  }

  Map<String, dynamic> toJson() => {
    'limitPercent': limitPercent,
    'days': days,
    'pauseMinutes': pauseMinutes,
    'minRides': minRides,
  };

  @override
  bool operator ==(Object other) =>
      other is DriverCancelLimit &&
      other.limitPercent == limitPercent &&
      other.days == days &&
      other.pauseMinutes == pauseMinutes &&
      other.minRides == minRides;

  @override
  int get hashCode => Object.hash(limitPercent, days, pauseMinutes, minRides);
}

/// One `ride_cancel_places` row as the admin edits it.
class CancelPlace {
  const CancelPlace({this.id, required this.level, this.country, this.state, this.city, this.suburb, this.rules = const {}});

  final String? id;
  final String level;
  final String? country, state, city, suburb;

  /// Only the keys this place sets.
  final Map<String, double> rules;

  bool get isDefault => level == 'default';

  String get label => isDefault
      ? 'Default (everywhere)'
      : [country, state, city, suburb].whereType<String>().where((s) => s.trim().isNotEmpty).join(', ');

  factory CancelPlace.fromRow(Map<String, dynamic> m) {
    final raw = m['rules'];
    return CancelPlace(
      id: m['id'] as String?,
      level: '${m['level'] ?? 'default'}',
      country: m['country'] as String?,
      state: m['state'] as String?,
      city: m['city'] as String?,
      suburb: m['suburb'] as String?,
      rules: {
        if (raw is Map)
          for (final e in raw.entries)
            if (e.value is num && CancelRules.keys.contains(e.key)) '${e.key}': (e.value as num).toDouble(),
      },
    );
  }

  Map<String, dynamic> toRow() => {
    'level': level,
    'country': level == 'default' ? null : country?.trim(),
    'state': const ['state', 'city', 'suburb'].contains(level) ? state?.trim() : null,
    'city': const ['city', 'suburb'].contains(level) ? city?.trim() : null,
    'suburb': level == 'suburb' ? suburb?.trim() : null,
    'rules': rules,
  };
}

/// What the app reads for one ride (ride_cancel_terms, 0269).
class CancelTerms {
  const CancelTerms({this.rules = CancelRules.standard, this.currency, this.scheduled = false});
  final CancelRules rules;
  final String? currency;
  final bool scheduled;

  factory CancelTerms.fromJson(Object? json) => json is Map
      ? CancelTerms(
          rules: CancelRules.fromJson(json),
          currency: json['currency'] as String?,
          scheduled: json['scheduled'] == true,
        )
      : const CancelTerms();
}
