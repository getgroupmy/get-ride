// City to City per-seat trips (migration 0310; the approved boards 15, 16
// and 17): a driver posts a trip they are making anyway and riders book
// seats on it. Pure; the server's twins are c2c_seat_terms_for,
// c2c_seat_limits_of, c2c_door_extra and c2c_repeat_dates, tested on the
// same cases (test/city_to_city_seats_test.dart,
// supabase/tests/city_to_city_seats_0310.sql).
//
// The rules: a Default and a rule per region (country, state, city,
// suburb). The trip's start picks: the most specific active region rule
// wins, and a region rule overrides only the parts it sets; every other part
// comes from the rule above it, at last the Default.
import 'dart:math' as math;

import 'package:intl/intl.dart' show DateFormat;

import 'city_to_city.dart';
import 'commission.dart' show Geo;

/// The admin page key for the per-seat rules (0310), grantable on its own.
const c2cSeatsPage = 'admin-settings-city-to-city-seats';

String? _nz(Object? v) {
  final t = '${v ?? ''}'.trim();
  return t.isEmpty ? null : t;
}

double? _numOrNull(Object? v) {
  if (v == null) return null;
  final d = v is num ? v.toDouble() : double.tryParse('$v');
  return d == null || !d.isFinite ? null : d;
}

double _num(Object? v, [double fallback = 0]) => _numOrNull(v) ?? fallback;


bool? _boolOrNull(Object? v) => v is bool ? v : (v == 'true' ? true : (v == 'false' ? false : null));

DateTime? _at(Object? v) => DateTime.tryParse('${v ?? ''}')?.toLocal();

// ---- The rules ------------------------------------------------------------------------------------------

/// How riders join a trip.
enum C2cJoinMode {
  instant('instant', 'Instant'),
  approve('approve', 'Driver approves'),
  driverPicks('driver_picks', 'Driver picks per trip');

  const C2cJoinMode(this.key, this.label);
  final String key;
  final String label;
  static C2cJoinMode of(Object? v) => values.firstWhere((m) => m.key == v, orElse: () => driverPicks);

  /// What the admin page says under the choice.
  String note({int hours = 2, int beforeMin = 60}) => switch (this) {
    instant => 'A seat is booked at once, like a bus ticket.',
    approve => 'Each seat request waits for the driver; it lapses after $hours ${hours == 1 ? 'hour' : 'hours'} '
        'or ${c2cMinutesText(beforeMin)} before leaving.',
    driverPicks => 'When posting, the driver chooses Instant or Approve for that trip.',
  };
}

/// How a seat is priced.
enum C2cSeatPriceMode {
  range('range', 'Range from the route rule'),
  fixed('fixed', 'Fixed by admin'),
  free('free', 'Driver free');

  const C2cSeatPriceMode(this.key, this.label);
  final String key;
  final String label;
  static C2cSeatPriceMode of(Object? v) => values.firstWhere((m) => m.key == v, orElse: () => range);

  String get note => switch (this) {
    range => 'Drivers pick a price inside the range.',
    fixed => 'Drivers can\'t change it: the route\'s own seat price, else the middle of the range.',
    free => 'Drivers set any price; riders see it before booking.',
  };
}

/// How the region's seat range is given.
enum C2cSeatRangeMode {
  percent('percent', '% of the whole-car fare'),
  amount('amount', 'RM min and max');

  const C2cSeatRangeMode(this.key, this.label);
  final String key;
  final String label;
  static C2cSeatRangeMode of(Object? v) => v == 'amount' ? amount : percent;
}

/// The biggest parcel a trip takes.
enum C2cParcelSize {
  small('small', 'Small', 'Fits on a lap: an envelope or a shoebox'),
  medium('medium', 'Medium', 'A cabin bag'),
  large('large', 'Large', 'A suitcase');

  const C2cParcelSize(this.key, this.label, this.hint);
  final String key;
  final String label;
  final String hint;
  static C2cParcelSize of(Object? v) => values.firstWhere((m) => m.key == v, orElse: () => small);
}

/// The parts of a seat rule, each set whole on a region rule or left to the
/// rule above it, and the columns of each (the first one says whether it is
/// set).
enum C2cSeatPart {
  on('Per-seat trips', ['seats_on']),
  join('How riders join', ['join_mode', 'approve_hours', 'approve_before_min']),
  price('Seat price', ['price_mode', 'range_mode', 'pct_low', 'pct_high', 'amount_low', 'amount_high']),
  limits('Limits', ['max_seats', 'max_per_booking', 'cutoff_min', 'post_ahead_days']),
  door('Door pickup', ['door_on', 'door_max_km', 'door_per_km']),
  women('Women-only trips', ['women_on']),
  repeat('Repeat trips', ['repeat_on', 'repeat_max_weeks']),
  coriders('Co-riders', ['coriders_on']),
  parcels('Parcels', ['parcels_on', 'parcel_max_slots', 'parcel_max_size', 'parcel_min_price', 'parcel_max_price']);

  const C2cSeatPart(this.label, this.columns);
  final String label;
  final List<String> columns;
}

/// Every column of a seat rule's parts.
final c2cSeatColumns = [for (final p in C2cSeatPart.values) ...p.columns];

/// The Default as 0310 seeds it (Per-seat trips off).
const c2cSeatDefaults = <String, Object?>{
  'seats_on': false,
  'join_mode': 'driver_picks',
  'approve_hours': 2,
  'approve_before_min': 60,
  'price_mode': 'range',
  'range_mode': 'percent',
  'pct_low': 25,
  'pct_high': 40,
  'amount_low': 30,
  'amount_high': 60,
  'max_seats': 4,
  'max_per_booking': 4,
  'cutoff_min': 60,
  'post_ahead_days': 30,
  'door_on': true,
  'door_max_km': 5,
  'door_per_km': 1,
  'women_on': true,
  'repeat_on': true,
  'repeat_max_weeks': 8,
  'coriders_on': true,
  'parcels_on': false,
  'parcel_max_slots': 2,
  'parcel_max_size': 'medium',
  'parcel_min_price': 5,
  'parcel_max_price': 30,
};

/// A per-seat rule (c2c_seat_rules): the Default (no place) or a region's,
/// its parts as stored (a region rule's unset parts null).
class C2cSeatRule extends C2cRegionRule {
  C2cSeatRule({this.id, this.place, this.active = true, this.createdAt, Map<String, Object?>? values})
    : values = Map.unmodifiable({for (final c in c2cSeatColumns) c: values?[c]});

  factory C2cSeatRule.fromRow(Map<String, dynamic> r) => C2cSeatRule(
    id: _nz(r['id']),
    place: r['place'] is Map ? C2cPlace.fromJson(Map<String, dynamic>.from(r['place'] as Map)) : null,
    active: r['active'] != false,
    createdAt: DateTime.tryParse('${r['created_at'] ?? ''}'),
    values: {for (final c in c2cSeatColumns) c: _clean(c, r[c])},
  );

  @override
  final String? id;
  @override
  final C2cPlace? place;
  @override
  final bool active;
  @override
  final DateTime? createdAt;

  /// Each column's value; null: not set here.
  final Map<String, Object?> values;

  /// Whether [part] is set on this rule (always on the Default).
  bool sets(C2cSeatPart part) => values[part.columns.first] != null;

  /// This rule with [changes] (columns to values).
  C2cSeatRule withValues(Map<String, Object?> changes) =>
      C2cSeatRule(id: id, place: place, active: active, createdAt: createdAt, values: {...values, ...changes});

  /// This rule with [part] set to [from]'s values (the rule above's), or
  /// left to the rule above (null [from]).
  C2cSeatRule withPart(C2cSeatPart part, C2cSeatTerms? from) => withValues({
    for (final c in part.columns) c: from?.values[c],
  });

  C2cSeatRule copyWith({C2cPlace? place, bool? active}) => C2cSeatRule(
    id: id,
    place: place ?? this.place,
    active: active ?? this.active,
    createdAt: createdAt,
    values: values,
  );

  /// The row as stored (without the server's stamps).
  Map<String, dynamic> toRow() => {
    if (id != null) 'id': id,
    'place': place?.toJson(),
    'active': active,
    for (final c in c2cSeatColumns) c: values[c],
  };

  /// Why it can't be saved, or null.
  String? get problem {
    final why = place?.problem;
    if (why != null) return why;
    if (isDefault && C2cSeatPart.values.any((p) => !sets(p))) return 'The default sets every part.';
    final t = C2cSeatTerms(values);
    if (sets(C2cSeatPart.price)) {
      if (t.pctLow > t.pctHigh) return 'The lowest % must not be above the highest.';
      if (t.amountLow > t.amountHigh) return 'The lowest price must not be above the highest.';
    }
    if (sets(C2cSeatPart.parcels) && t.parcelMinPrice > t.parcelMaxPrice) {
      return 'The lowest parcel price must not be above the highest.';
    }
    return null;
  }
}

Object? _clean(String column, Object? v) {
  if (v == null) return null;
  if (column.endsWith('_on')) return _boolOrNull(v);
  if (const {'join_mode', 'price_mode', 'range_mode', 'parcel_max_size'}.contains(column)) return _nz(v);
  final d = _numOrNull(v);
  if (d == null) return null;
  return const {'pct_low', 'pct_high', 'amount_low', 'amount_high', 'door_max_km', 'door_per_km', 'parcel_min_price',
          'parcel_max_price'}.contains(column)
      ? d
      : d.round();
}

/// The rule in force for a trip: every part, merged (c2c_seat_terms_for's
/// result), with the app's defaults for anything missing.
class C2cSeatTerms {
  C2cSeatTerms(Map<String, Object?> values, {this.ruleIds = const []})
    : values = Map.unmodifiable({for (final c in c2cSeatColumns) c: _clean(c, values[c]) ?? c2cSeatDefaults[c]});

  factory C2cSeatTerms.fromJson(Object? v) {
    final m = v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
    return C2cSeatTerms(m, ruleIds: [for (final e in m['ruleIds'] is List ? m['ruleIds'] as List : const []) '$e']);
  }

  final Map<String, Object?> values;

  /// The rules that apply, most specific first.
  final List<String> ruleIds;

  bool _b(String c) => values[c] == true;
  int _i(String c) => (values[c] as num? ?? 0).round();
  double _d(String c) => (values[c] as num? ?? 0).toDouble();

  bool get seatsOn => _b('seats_on');
  C2cJoinMode get joinMode => C2cJoinMode.of(values['join_mode']);
  int get approveHours => _i('approve_hours');
  int get approveBeforeMin => _i('approve_before_min');
  C2cSeatPriceMode get priceMode => C2cSeatPriceMode.of(values['price_mode']);
  C2cSeatRangeMode get rangeMode => C2cSeatRangeMode.of(values['range_mode']);
  double get pctLow => _d('pct_low');
  double get pctHigh => _d('pct_high');
  double get amountLow => _d('amount_low');
  double get amountHigh => _d('amount_high');
  int get maxSeats => _i('max_seats');
  int get maxPerBooking => _i('max_per_booking');
  int get cutoffMin => _i('cutoff_min');
  int get postAheadDays => _i('post_ahead_days');
  bool get doorOn => _b('door_on');
  double get doorMaxKm => _d('door_max_km');
  double get doorPerKm => _d('door_per_km');
  bool get womenOn => _b('women_on');
  bool get repeatOn => _b('repeat_on');
  int get repeatMaxWeeks => _i('repeat_max_weeks');
  bool get coridersOn => _b('coriders_on');
  bool get parcelsOn => _b('parcels_on');
  int get parcelMaxSlots => _i('parcel_max_slots');
  C2cParcelSize get parcelMaxSize => C2cParcelSize.of(values['parcel_max_size']);
  double get parcelMinPrice => _d('parcel_min_price');
  double get parcelMaxPrice => _d('parcel_max_price');

  /// Seats one booking may take: several with co-riders on, else 1.
  int get seatsPerBooking => coridersOn ? math.max(maxPerBooking, 1) : 1;
}

/// The terms for a trip starting at [start] among [rules]: each part from
/// the most specific active rule that sets it, the Default last
/// (c2c_seat_terms_for's twin; ties to the older rule, then the lower id).
C2cSeatTerms c2cSeatTermsFor(List<C2cSeatRule> rules, Geo start) {
  final ranked = <(int, C2cSeatRule)>[
    for (final r in rules)
      if (r.place == null)
        (0, r)
      else if (r.active && r.place!.holds(start) > 0)
        (r.place!.holds(start), r),
  ]..sort((a, b) {
      final c = b.$1.compareTo(a.$1);
      if (c != 0) return c;
      final d = (a.$2.createdAt ?? DateTime(0)).compareTo(b.$2.createdAt ?? DateTime(0));
      return d != 0 ? d : (a.$2.id ?? '').compareTo(b.$2.id ?? '');
    });
  final out = <String, Object?>{};
  for (final part in C2cSeatPart.values) {
    final from = ranked.where((e) => e.$2.sets(part)).firstOrNull?.$2;
    for (final c in part.columns) {
      out[c] = from?.values[c];
    }
  }
  return C2cSeatTerms(out, ruleIds: [for (final e in ranked) ?e.$2.id]);
}

/// The terms the rule above [rule] gives it: [rules] without [rule], for
/// [rule]'s own place (the Default for the Default itself).
C2cSeatTerms c2cSeatTermsAbove(List<C2cSeatRule> rules, C2cSeatRule rule) {
  final p = rule.place;
  if (p == null) return C2cSeatTerms(rule.values);
  final g = Geo(
    country: p.country,
    state: p.rank >= 2 ? p.state : null,
    city: p.rank >= 3 ? p.city : null,
    suburb: p.rank >= 4 ? p.suburb : null,
  );
  return c2cSeatTermsFor([
    for (final r in rules)
      if (!identical(r, rule) && (rule.id == null || r.id != rule.id)) r,
  ], g);
}

/// "driver picks, range, door pickup", or "Off": a rule's line in the list.
String c2cSeatRuleSummary(C2cSeatTerms t) {
  if (!t.seatsOn) return 'Off';
  final join = switch (t.joinMode) {
    C2cJoinMode.instant => 'instant',
    C2cJoinMode.approve => 'driver approves',
    C2cJoinMode.driverPicks => 'driver picks',
  };
  final price = switch (t.priceMode) {
    C2cSeatPriceMode.range => 'range',
    C2cSeatPriceMode.fixed => 'fixed',
    C2cSeatPriceMode.free => 'driver free',
  };
  return [join, price, if (t.doorOn) 'door pickup'].join(', ');
}

/// "60 min", "2 h", "1 h 30 min".
String c2cMinutesText(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

// ---- The price ----------------------------------------------------------------------------------------

/// The seat price limits: a range, a fixed price, or any price from 1
/// (c2c_seat_limits_of's result).
class C2cSeatLimits {
  const C2cSeatLimits({
    this.mode = C2cSeatPriceMode.range,
    this.low = 1,
    this.high,
    this.price,
    this.wholeCar,
    this.currency = 'MYR',
  });

  factory C2cSeatLimits.fromJson(Object? v) {
    final m = v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
    return C2cSeatLimits(
      mode: C2cSeatPriceMode.of(m['mode']),
      low: _num(m['low'], 1),
      high: _numOrNull(m['high']),
      price: _numOrNull(m['price']),
      wholeCar: _numOrNull(m['wholeCar']),
      currency: (_nz(m['currency']) ?? 'MYR').toUpperCase(),
    );
  }

  final C2cSeatPriceMode mode;
  final double low;

  /// Null: no top (driver free).
  final double? high;

  /// The fixed price.
  final double? price;
  final double? wholeCar;
  final String currency;

  /// [p] within the limits.
  double clamp(double p) {
    if (mode == C2cSeatPriceMode.fixed) return price ?? low;
    final top = high;
    return c2cRound2(top == null ? math.max(p, low) : p.clamp(low, top).toDouble());
  }

  /// Why [p] isn't allowed, or null.
  String? problem(double p) {
    if (mode == C2cSeatPriceMode.fixed) return p == price ? null : 'This route has a fixed seat price.';
    if (p < low) return 'A seat is at least ${c2cMoney(low, currency)}.';
    final top = high;
    if (top != null && p > top) return 'A seat is at most ${c2cMoney(top, currency)}.';
    return null;
  }

  /// What the post screen says under the price: "Allowed RM 35 to 56 a
  /// seat (admin's range)".
  String get hint => switch (mode) {
    C2cSeatPriceMode.fixed => 'Fixed by GET.ride for this route',
    C2cSeatPriceMode.free => 'Any price; riders see it before booking',
    C2cSeatPriceMode.range =>
      'Allowed ${c2cMoney(low, currency)} to ${c2cMoney(high ?? low, currency).replaceFirst(RegExp(r'^[A-Z]+ '), '')} a seat (admin\'s range)',
  };
}

/// The limits under [t], a route's per-seat rule [route] (null: none) and
/// the whole-car fare [whole] (c2c_seat_limits_of's twin): Driver free
/// first; then a route's fixed price or RM range; else the region's range
/// (% of the whole car, at least 1, or RM), its fixed price the middle.
C2cSeatLimits c2cSeatLimitsOf(C2cSeatTerms t, C2cRule? route, double? whole, {String currency = 'MYR'}) {
  if (t.priceMode == C2cSeatPriceMode.free) {
    return C2cSeatLimits(mode: C2cSeatPriceMode.free, low: 1, wholeCar: whole, currency: currency);
  }
  if (route != null && route.fareMode == C2cFareMode.fixed && route.fixedFare != null) {
    final p = route.fixedFare!;
    return C2cSeatLimits(mode: C2cSeatPriceMode.fixed, low: p, high: p, price: p, wholeCar: whole, currency: currency);
  }
  double low, high;
  if (route != null && route.rangeMode == C2cRangeMode.set && route.rangeLow != null) {
    low = route.rangeLow!;
    high = route.rangeHigh ?? low;
  } else if (t.rangeMode == C2cSeatRangeMode.amount) {
    low = t.amountLow;
    high = t.amountHigh;
  } else {
    low = math.max(c2cRound0((whole ?? 0) * t.pctLow / 100), 1);
    high = math.max(c2cRound0((whole ?? 0) * t.pctHigh / 100), low);
  }
  if (t.priceMode == C2cSeatPriceMode.fixed) {
    final mid = c2cRound0((low + high) / 2);
    return C2cSeatLimits(mode: C2cSeatPriceMode.fixed, low: mid, high: mid, price: mid, wholeCar: whole, currency: currency);
  }
  return C2cSeatLimits(low: low, high: high, wholeCar: whole, currency: currency);
}

/// The per-seat route rule for a trip from [from] to [to] (0306's order,
/// rules of kind 'per_seat'); null for none.
C2cRule? c2cSeatRouteRuleFor(List<C2cRule> rules, Geo from, Geo to) =>
    c2cRuleFor(rules, from, to, tripKind: 'per_seat')?.rule;

/// The board's example line for [t]: "KL to Ipoh, whole car RM 140: seat
/// 25% to 40% = RM 35 to RM 56."
String c2cSeatRangeExample(C2cSeatTerms t, {double whole = 140, String currency = 'MYR'}) {
  final l = c2cSeatLimitsOf(t, null, whole, currency: currency);
  String m(double v) => c2cMoney(v, currency);
  return switch (t.priceMode) {
    C2cSeatPriceMode.free => 'Any price from ${m(1)}.',
    C2cSeatPriceMode.fixed => 'Kuala Lumpur to Ipoh, whole car ${m(whole)}: a seat ${m(l.price ?? l.low)}, unless the '
        'route has its own seat price.',
    C2cSeatPriceMode.range => t.rangeMode == C2cSeatRangeMode.percent
        ? 'Kuala Lumpur to Ipoh, whole car ${m(whole)}: seat ${t.pctLow.round()}% to ${t.pctHigh.round()}% = '
              '${m(l.low)} to ${m(l.high ?? l.low)}.'
        : 'A seat ${m(l.low)} to ${m(l.high ?? l.low)}, unless the route has its own range.',
  };
}

// ---- Door pickup and repeats ------------------------------------------------------------------------------

/// Door pickup's extra: [km] off the route to 0.1 km, at [perKm] a km, in
/// cents (c2c_door_extra's twin).
double c2cDoorExtra(double km, double perKm) =>
    c2cRound2((math.max(km, 0) * 10 + 1e-9).roundToDouble() / 10 * math.max(perKm, 0));

/// "Door pickup within 5 km (+ RM 1 a km)".
String c2cDoorLine(double maxKm, double perKm, [String currency = 'MYR']) =>
    'Door pickup within ${_km(maxKm)} km (+ ${c2cMoney(perKm, currency)} a km)';

String _km(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// How a trip repeats.
enum C2cRepeat {
  none('none', 'Once'),
  daily('daily', 'Every day'),
  weekdays('weekdays', 'Weekdays'),
  weekly('weekly', 'Every week');

  const C2cRepeat(this.key, this.label);
  final String key;
  final String label;
  static C2cRepeat of(Object? v) => values.firstWhere((m) => m.key == v, orElse: () => none);
}

/// The repeats after [start] (local) up to the end of [until], at most
/// [max] (c2c_repeat_dates' twin).
List<DateTime> c2cRepeatDates(DateTime start, C2cRepeat mode, DateTime until, {int max = 60}) {
  final out = <DateTime>[];
  if (mode == C2cRepeat.none) return out;
  final last = DateTime(until.year, until.month, until.day);
  for (var n = 1; n <= 400 && out.length < max; n++) {
    final d = DateTime(start.year, start.month, start.day + n, start.hour, start.minute);
    if (DateTime(d.year, d.month, d.day).isAfter(last)) break;
    final ok = switch (mode) {
      C2cRepeat.daily => true,
      C2cRepeat.weekdays => d.weekday <= DateTime.friday,
      C2cRepeat.weekly => d.weekday == start.weekday,
      C2cRepeat.none => false,
    };
    if (ok) out.add(d);
  }
  return out;
}

/// "Repeat every Saturday", "Repeat on weekdays", "Repeat every day".
String c2cRepeatLine(C2cRepeat mode, DateTime start) => switch (mode) {
  C2cRepeat.none => 'Once',
  C2cRepeat.daily => 'Repeat every day',
  C2cRepeat.weekdays => 'Repeat on weekdays',
  C2cRepeat.weekly => 'Repeat every ${DateFormat('EEEE').format(start)}',
};

// ---- Posting ------------------------------------------------------------------------------------------

/// What the post screen is told for a route (c2c_post_terms).
class C2cPostTerms {
  const C2cPostTerms({
    required this.terms,
    this.limits = const C2cSeatLimits(),
    this.commissionRate,
    this.eligibility = const C2cEligibility(),
    this.approved = false,
    this.verifiedWoman = false,
    this.available = true,
  });

  factory C2cPostTerms.fromJson(Object? v) {
    final m = v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
    return C2cPostTerms(
      terms: C2cSeatTerms.fromJson(m['terms']),
      limits: C2cSeatLimits.fromJson(m['limits']),
      commissionRate: _numOrNull(m['commissionRate']),
      eligibility: m['eligibility'] is Map
          ? C2cEligibility.fromJson(Map<String, dynamic>.from(m['eligibility'] as Map))
          : const C2cEligibility(),
      approved: m['approved'] == true,
      verifiedWoman: m['verifiedWoman'] == true,
      available: m['available'] != false,
    );
  }

  final C2cSeatTerms terms;
  final C2cSeatLimits limits;
  final double? commissionRate;
  final C2cEligibility eligibility;
  final bool approved, verifiedWoman, available;

  /// Why the driver can't post this route at all, or null.
  String? get block {
    if (!approved) return 'Only approved drivers can post a trip.';
    if (!terms.seatsOn || !available) return "Per-seat trips aren't offered from here yet.";
    if (!eligibility.ok) return c2cLockLine(eligibility) ?? "You can't take this route yet.";
    return null;
  }
}

/// "3 x RM 45 = RM 135": the post screen's "If every seat is booked".
String c2cEarnLine(int seats, double price, [String currency = 'MYR']) =>
    '$seats x ${c2cMoney(price, currency)} = ${c2cMoney(c2cRound2(seats * price), currency)}';

/// "You keep RM 118.80 after the 12% City to City commission."
String c2cSeatKeepLine(double total, double? rate, [String currency = 'MYR']) {
  if (rate == null) return 'City to City commission comes off what riders pay.';
  final pct = (rate * 100).toStringAsFixed(rate * 100 == (rate * 100).roundToDouble() ? 0 : 1);
  return 'You keep ${c2cMoney(c2cRound2(total * (1 - rate)), currency)} after the $pct% City to City commission.';
}

/// "Post trip with 3 seats".
String c2cPostButton(int seats, {int trips = 1}) =>
    'Post trip with $seats ${seats == 1 ? 'seat' : 'seats'}${trips > 1 ? ' ($trips trips)' : ''}';

// ---- Trips and seat bookings ---------------------------------------------------------------------------

/// A meeting point of a trip: [minutes] after it leaves.
class C2cMeetingPoint {
  const C2cMeetingPoint({required this.name, this.address, required this.lat, required this.lng, this.minutes = 0});

  factory C2cMeetingPoint.fromJson(Map<String, dynamic> j) => C2cMeetingPoint(
    name: _nz(j['name']) ?? 'Meeting point',
    address: _nz(j['address']),
    lat: _num(j['lat']),
    lng: _num(j['lng']),
    minutes: _num(j['minutes']).round(),
  );

  final String name;
  final String? address;
  final double lat, lng;
  final int minutes;

  Map<String, dynamic> toJson() => {'name': name, 'address': ?address, 'lat': lat, 'lng': lng, 'minutes': minutes};

  /// When the car is there for a trip leaving at [leave].
  DateTime at(DateTime leave) => leave.add(Duration(minutes: minutes));
}

/// Where a trip is.
enum C2cTripStatus {
  scheduled('scheduled', 'Posted'),
  onTrip('on_trip', 'On the trip'),
  completed('completed', 'Done'),
  cancelled('cancelled', 'Cancelled');

  const C2cTripStatus(this.key, this.label);
  final String key;
  final String label;
  static C2cTripStatus of(Object? v) => values.firstWhere((s) => s.key == v, orElse: () => scheduled);
  bool get ended => this == completed || this == cancelled;
}

/// A trip a driver posted, as riders and its driver see it (c2c_trips with
/// c2c_trip_view's additions).
class C2cTrip {
  const C2cTrip({
    required this.id,
    this.ref = '',
    this.driverId,
    required this.fromName,
    this.fromPlace = const Geo(),
    required this.toName,
    this.toPlace = const Geo(),
    this.distanceKm = 0,
    this.durationMin = 0,
    required this.leaveAt,
    this.meetingPoints = const [],
    this.seatsTotal = 1,
    this.seatsLeft = 0,
    this.seatPrice = 0,
    this.currency = 'MYR',
    this.instant = true,
    this.womenOnly = false,
    this.doorPickup = false,
    this.doorMaxKm,
    this.doorPerKm,
    this.parcelSlots = 0,
    this.parcelsLeft = 0,
    this.parcelMaxSize,
    this.parcelPrice,
    this.suitcase = false,
    this.note,
    this.repeat = C2cRepeat.none,
    this.seriesId,
    this.driverName = 'Driver',
    this.driverRating,
    this.car,
    this.plate,
    this.status = C2cTripStatus.scheduled,
    this.closesAt,
    this.maxPerBooking = 1,
    this.coridersOn = false,
    this.mayBook = true,
    this.bookings = const [],
  });

  factory C2cTrip.fromJson(Map<String, dynamic> r) {
    Geo geo(Object? v) {
      final m = v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
      return Geo(country: _nz(m['country']), state: _nz(m['state']), city: _nz(m['city']), suburb: _nz(m['suburb']));
    }

    final total = _num(r['seats_total'], 1).round();
    return C2cTrip(
      id: '${r['id']}',
      ref: _nz(r['ref']) ?? '',
      driverId: _nz(r['driver_id']),
      fromName: _nz(r['from_name']) ?? 'Start',
      fromPlace: geo(r['from_place']),
      toName: _nz(r['to_name']) ?? 'End',
      toPlace: geo(r['to_place']),
      distanceKm: _num(r['distance_km']),
      durationMin: _num(r['duration_min']),
      leaveAt: _at(r['leave_at']) ?? DateTime.now(),
      meetingPoints: [
        for (final e in r['meeting_points'] is List ? r['meeting_points'] as List : const [])
          if (e is Map) C2cMeetingPoint.fromJson(Map<String, dynamic>.from(e)),
      ],
      seatsTotal: total,
      seatsLeft: _num(r['seats_left'], total.toDouble()).round(),
      seatPrice: _num(r['seat_price']),
      currency: (_nz(r['currency']) ?? 'MYR').toUpperCase(),
      instant: r['join_mode'] != 'approve',
      womenOnly: r['women_only'] == true,
      doorPickup: r['door_on'] is bool ? r['door_on'] == true : r['door_pickup'] == true,
      doorMaxKm: _numOrNull(r['door_max_km']),
      doorPerKm: _numOrNull(r['door_per_km']),
      parcelSlots: _num(r['parcel_slots']).round(),
      parcelsLeft: _num(r['parcels_left'], _num(r['parcel_slots'])).round(),
      parcelMaxSize: r['parcel_max_size'] == null ? null : C2cParcelSize.of(r['parcel_max_size']),
      parcelPrice: _numOrNull(r['parcel_price']),
      suitcase: r['luggage'] == 'suitcase',
      note: _nz(r['note']),
      repeat: C2cRepeat.of(r['repeat_mode']),
      seriesId: _nz(r['series_id']),
      driverName: _nz(r['driver_name']) ?? 'Driver',
      driverRating: _numOrNull(r['driver_rating']),
      car: _nz(r['car']),
      plate: _nz(r['plate']),
      status: C2cTripStatus.of(r['status']),
      closesAt: _at(r['closes_at']),
      maxPerBooking: _num(r['max_per_booking'], 1).round(),
      coridersOn: r['coriders_on'] == true,
      mayBook: r['may_book'] != false,
      bookings: [
        for (final e in r['bookings'] is List ? r['bookings'] as List : const [])
          if (e is Map) C2cSeatBooking.fromJson(Map<String, dynamic>.from(e)),
      ],
    );
  }

  final String id, ref;
  final String? driverId;
  final String fromName, toName;
  final Geo fromPlace, toPlace;
  final double distanceKm, durationMin;
  final DateTime leaveAt;
  final List<C2cMeetingPoint> meetingPoints;
  final int seatsTotal, seatsLeft;
  final double seatPrice;
  final String currency;

  /// Instant booking; false: the driver approves each request.
  final bool instant;
  final bool womenOnly;

  /// Door pickup offered (and allowed now), within [doorMaxKm] at [doorPerKm].
  final bool doorPickup;
  final double? doorMaxKm, doorPerKm;
  final int parcelSlots, parcelsLeft;
  final C2cParcelSize? parcelMaxSize;
  final double? parcelPrice;

  /// Room for 1 suitcase each; else small bags only.
  final bool suitcase;
  final String? note;
  final C2cRepeat repeat;
  final String? seriesId;
  final String driverName;
  final double? driverRating;
  final String? car, plate;
  final C2cTripStatus status;

  /// When booking closes (the cut-off before leaving).
  final DateTime? closesAt;
  final int maxPerBooking;
  final bool coridersOn;

  /// The caller may book it (not their own; women only for a verified woman).
  final bool mayBook;

  /// The driver's view: its bookings.
  final List<C2cSeatBooking> bookings;

  /// "Kuala Lumpur to Ipoh".
  String get route => '${fromPlace.city ?? fromPlace.state ?? fromName} to ${toPlace.city ?? toPlace.state ?? toName}';

  /// "Hafiz R. 4.9".
  String get driverLine => [driverName, if (driverRating != null) driverRating!.toStringAsFixed(1)].join(' ');

  /// "Honda City VKB 5512".
  String get carLine => [?car, ?plate].join(' ');

  /// The requests waiting for the driver, and the seats booked.
  List<C2cSeatBooking> get requests => [for (final b in bookings) if (b.status == C2cStatus.requested) b];
  List<C2cSeatBooking> get riding => [
    for (final b in bookings)
      if (b.status.withDriver || b.status == C2cStatus.completed) b,
  ];

  int get seatsBooked => riding.where((b) => !b.parcel).fold(0, (s, b) => s + b.seats);
}

/// One booking on a trip, as its driver sees it (c2c_driver_seat_trips).
class C2cSeatBooking {
  const C2cSeatBooking({
    required this.id,
    this.ref = '',
    this.status = C2cStatus.requested,
    this.parcel = false,
    this.seats = 1,
    this.riderName = 'Rider',
    this.riderRating,
    this.names = const [],
    this.door = false,
    this.pickupName = '',
    this.pickupAddress,
    this.leaveAt,
    this.doorKm,
    this.doorExtra,
    this.fare = 0,
    this.currency = 'MYR',
    this.cash = true,
    this.payStatus,
    this.expiresAt,
    this.parcelSize,
    this.recipient,
    this.note,
    this.commissionRate,
  });

  factory C2cSeatBooking.fromJson(Map<String, dynamic> j) {
    final p = j['parcel'] is Map ? Map<String, dynamic>.from(j['parcel'] as Map) : null;
    return C2cSeatBooking(
      id: '${j['id']}',
      ref: _nz(j['ref']) ?? '',
      status: C2cStatus.of(j['status']),
      parcel: j['item'] == 'parcel',
      seats: _num(j['seats'], 1).round(),
      riderName: _nz(j['rider_name']) ?? 'Rider',
      riderRating: _numOrNull(j['rider_rating']),
      names: c2cPassengerNames(j['passenger_names']),
      door: j['pickup_kind'] == 'door',
      pickupName: _nz(j['pickup_name']) ?? '',
      pickupAddress: _nz(j['pickup_address']),
      leaveAt: _at(j['leave_at']),
      doorKm: _numOrNull(j['door_km']),
      doorExtra: _numOrNull(j['door_extra']),
      fare: _num(j['fare']),
      currency: (_nz(j['currency']) ?? 'MYR').toUpperCase(),
      cash: j['payment'] != 'in_app',
      payStatus: _nz(j['pay_status']),
      expiresAt: _at(j['expires_at']),
      parcelSize: p == null ? null : C2cParcelSize.of(p['size']),
      recipient: p == null ? null : [?_nz(p['recipientName']), ?_nz(p['recipientPhone'])].join(', '),
      note: _nz(j['note']),
      commissionRate: _numOrNull(j['commission_rate']),
    );
  }

  final String id, ref;
  final C2cStatus status;
  final bool parcel;
  final int seats;
  final String riderName;
  final double? riderRating;
  final List<String> names;
  final bool door;
  final String pickupName;
  final String? pickupAddress;
  final DateTime? leaveAt;
  final double? doorKm, doorExtra;
  final double fare;
  final String currency;
  final bool cash;
  final String? payStatus;
  final DateTime? expiresAt;
  final C2cParcelSize? parcelSize;
  final String? recipient, note;
  final double? commissionRate;

  /// "Farah T. 4.8 · 2 seats" / "Farah T. · small parcel".
  String get who => [
    [riderName, if (riderRating != null) riderRating!.toStringAsFixed(1)].join(' '),
    parcel ? '${parcelSize?.label.toLowerCase() ?? 'small'} parcel' : '$seats ${seats == 1 ? 'seat' : 'seats'}',
  ].join(' · ');

  /// "8:15 Bus stop, Jalan Pahang" / "Door: 12 Jalan Ampang, 2.4 km off".
  String get pickupLine {
    final clock = leaveAt == null ? '' : '${c2cClock(leaveAt!)} ';
    return door
        ? '${clock}Door: $pickupName${doorKm == null ? '' : ', ${_km(doorKm!)} km off'}'
        : '$clock$pickupName';
  }

  /// "RM 90, cash" / "RM 47.40, paid in app" / "RM 45, in app after the trip".
  String get payLine => '${c2cMoney(fare, currency)}, ${cash ? 'cash' : payStatus == 'held' || payStatus == 'paid'
      ? 'paid in app'
      : payStatus == 'refunded'
      ? 'refunded'
      : 'in app after the trip'}';
}

/// The names of a seat booking's passengers ([{name, familyMemberId?}]).
List<String> c2cPassengerNames(Object? raw) => [
  if (raw is List)
    for (final e in raw)
      if (e is Map && _nz(e['name']) != null) _nz(e['name'])!,
];

/// A passenger as the rider names them; [familyMemberId] is for the Family
/// module to fill from the rider's family members.
typedef C2cPassenger = ({String name, String? familyMemberId});

/// The passengers as c2c_book_seat takes them, the booker first; empty
/// names left out.
List<Map<String, dynamic>> c2cPassengersJson(List<C2cPassenger> list) => [
  for (final p in list)
    if (p.name.trim().isNotEmpty) {'name': p.name.trim(), 'familyMemberId': ?p.familyMemberId},
];

/// Why the passengers can't be sent for [seats] seats, or null: one name a
/// seat when more than 1.
String? c2cNamesProblem(int seats, List<C2cPassenger> list) {
  if (seats <= 1) return null;
  final named = list.take(seats).where((p) => p.name.trim().isNotEmpty).length;
  return named == seats && list.length >= seats ? null : 'Name each passenger, one a seat.';
}

/// A trip's tags in the search list: (label, tone) with tone 'good',
/// 'pink' or ''.
List<(String, String)> c2cTripTags(C2cTrip t) => [
  if (t.womenOnly) ('Women only', 'pink'),
  t.instant ? ('Instant', 'good') : ('Driver approves', ''),
  if (t.doorPickup) ('Door pickup', ''),
  if (t.repeat != C2cRepeat.none) (c2cRepeatLine(t.repeat, t.leaveAt).replaceFirst('Repeat e', 'E').replaceFirst('Repeat on w', 'W'), ''),
  if (t.parcelsLeft > 0) ('Takes parcels', ''),
];

/// "Hafiz R. 4.9 · Honda City · 2 seats left".
String c2cTripDriverLine(C2cTrip t) => [
  t.driverLine,
  if (t.car != null) t.car!,
  t.seatsLeft == 0 ? 'full' : '${t.seatsLeft} ${t.seatsLeft == 1 ? 'seat' : 'seats'} left',
].join(' · ');

/// "2 h 30 min".
String c2cDurationText(double min) => c2cMinutesText(min.round());

/// "Instant: booked when you tap" / "The driver approves: they answer
/// within 2 hours".
String c2cJoinLine(C2cTrip t, {int approveHours = 2}) => t.instant
    ? 'Instant: booked when you tap'
    : 'The driver approves: you hear back within $approveHours ${approveHours == 1 ? 'hour' : 'hours'}';

/// The total for [seats] seats at [price] with door pickup's [doorExtra].
double c2cSeatTotal(double price, int seats, {double doorExtra = 0}) => c2cRound2(price * seats + doorExtra);

/// "Book 2 seats · RM 92.40" / "Request 1 seat · RM 45" / "Send parcel · RM 15".
String c2cBookButton(int seats, double total, {bool instant = true, bool parcel = false, String currency = 'MYR'}) =>
    parcel
        ? '${instant ? 'Send parcel' : 'Request parcel space'} · ${c2cMoney(total, currency)}'
        : '${instant ? 'Book' : 'Request'} $seats ${seats == 1 ? 'seat' : 'seats'} · ${c2cMoney(total, currency)}';

/// What the rider's My trips row says a booking is: "whole car", "2 seats",
/// "parcel".
String c2cBookingKind(C2cBooking b) => !b.perSeat
    ? 'whole car'
    : b.item == 'parcel'
    ? 'parcel'
    : '${b.passengers} ${b.passengers == 1 ? 'seat' : 'seats'}';

/// The words for a seat booking's end: declined, lapsed, cancelled with the
/// trip.
String c2cSeatEndLine(C2cBooking b) {
  final back = b.payStatus == 'refunded' ? ' The fare held came back to you.' : '';
  return switch (b.status) {
    C2cStatus.declined => 'The driver declined this request.$back',
    C2cStatus.expired => "The driver didn't answer in time.$back",
    _ when b.cancelledBy == 'driver' => 'The driver cancelled this trip.$back',
    _ => '',
  };
}

/// Great-circle km between two points (0160's km_between twin).
double c2cKmBetween(double lat1, double lng1, double lat2, double lng2) {
  double rad(double d) => d * math.pi / 180;
  final a = math.pow(math.sin(rad(lat2 - lat1) / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(rad(lng2 - lng1) / 2), 2);
  return 2 * 6371 * math.asin(math.sqrt(a));
}

/// Door pickup at ([lat], [lng]) on [t]: the km off the route (the straight
/// line to the nearest meeting point, to 0.1 km), the extra, the nearest
/// point, and whether it is within the trip's limit (c2c_book_seat's twin).
({double km, double extra, C2cMeetingPoint? nearest, bool ok}) c2cDoorQuote(C2cTrip t, double lat, double lng) {
  C2cMeetingPoint? best;
  var bestKm = double.infinity;
  for (final p in t.meetingPoints) {
    final d = c2cKmBetween(lat, lng, p.lat, p.lng);
    if (d < bestKm) {
      bestKm = d;
      best = p;
    }
  }
  if (best == null) return (km: 0, extra: 0, nearest: null, ok: false);
  final km = (bestKm * 10 + 1e-9).roundToDouble() / 10;
  return (
    km: km,
    extra: c2cDoorExtra(km, t.doorPerKm ?? 0),
    nearest: best,
    ok: t.doorPickup && km <= (t.doorMaxKm ?? 0),
  );
}

/// "My address: 12 Jalan Ampang" and "Door pickup · 2.4 km off route · + RM 2.40".
String c2cDoorNote(double km, double extra, [String currency = 'MYR']) =>
    'Door pickup · ${_km(km)} km off route · + ${c2cMoney(extra, currency)}';
