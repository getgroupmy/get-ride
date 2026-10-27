// City to City (intercity rides, e.g. Kuala Lumpur to Ipoh): the settings,
// the route rules and the quote. Pure; the server's twin is migration 0306
// (c2c_rule_for, c2c_fare_card, c2c_quote, c2c_driver_check), and both are
// tested on the same cases (test/city_to_city_test.dart,
// supabase/tests/city_to_city_0306.sql).
//
// Which rule: each end of the trip takes the most specific place of the rule
// that holds it (suburb 4, city 3, state 2, country 1; none: the rule does
// not apply). The winner has the highest sum of both ends, then the more
// specific pickup end, then the lower position (list order), then the older
// rule, then the lower id. No rule: the default (the fare card plus the
// settings' add-on and range).
//
// A place matches as commission rates do: its own name (or as whole words
// in the geocoder's), and each parent that both name. A place keeps the
// parents of the region it was picked from, so Kuala Lumpur (a federal
// territory, its own state) is never taken to be in Selangor.
//
// Bookings (migration 0307): the rider's request, drivers' offers, the
// booking and the cancel fee; [C2cBooking], [C2cOffer], [c2cCancelFee],
// [c2cFareProblem] and the words the rider app shows. The server checks
// the same on insert and cancel (supabase/tests/city_to_city_bookings_0307.sql).
import 'dart:math' as math;

import 'package:intl/intl.dart' show DateFormat;

import 'commission.dart' show Geo;
import 'fare.dart' show ServiceRates, calculateFare;
import 'fare_tariff.dart';
import 'ride_bidding.dart' show placeNameMatches;

/// The Vehicle Service City to City trips are booked as (0306).
const c2cServiceName = 'City to City';

/// The admin page key for the settings, permits and rules (0306).
const c2cPage = 'admin-settings-city-to-city';

/// Place levels, broadest first; a place's rank is its index + 1.
const c2cLevels = ['country', 'state', 'city', 'suburb'];

String? _nz(Object? v) {
  final t = '${v ?? ''}'.trim();
  return t.isEmpty ? null : t;
}

double _num(Object? v, [double fallback = 0]) {
  final d = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
  return d == null || !d.isFinite ? fallback : d;
}

double? _numOrNull(Object? v) {
  if (v == null) return null;
  final d = v is num ? v.toDouble() : double.tryParse('$v');
  return d == null || !d.isFinite ? null : d;
}

bool _same(String? rule, String? trip) {
  final r = _nz(rule), p = _nz(trip);
  return r != null && p != null && (r.toLowerCase() == p.toLowerCase() || placeNameMatches(r, p));
}

bool _parentOk(String? rule, String? trip) => _nz(rule) == null || _nz(trip) == null || _same(rule, trip);

/// Cents, as numeric(…, 2) rounds (half away from zero), steady against
/// binary fractions (118.25 × 1.15 is 135.99, not 135.98).
double c2cRound2(double v) => (v * 100 + (v >= 0 ? 1e-6 : -1e-6)).round() / 100;

/// Whole units, as round(numeric) does.
double c2cRound0(double v) => (v + (v >= 0 ? 1e-6 : -1e-6)).roundToDouble();

/// One place of a rule: a country, state, city or suburb with its parents.
class C2cPlace {
  const C2cPlace({required this.level, required this.country, this.state, this.city, this.suburb});

  factory C2cPlace.fromJson(Map<String, dynamic> j) => C2cPlace(
    level: c2cLevels.contains(j['level']) ? j['level'] as String : 'country',
    country: _nz(j['country']) ?? '',
    state: _nz(j['state']),
    city: _nz(j['city']),
    suburb: _nz(j['suburb']),
  );

  /// country | state | city | suburb.
  final String level;
  final String country;
  final String? state, city, suburb;

  /// Its own name.
  String get name => switch (level) {
    'suburb' => suburb ?? '',
    'city' => city ?? '',
    'state' => state ?? '',
    _ => country,
  };

  /// suburb 4, city 3, state 2, country 1.
  int get rank => c2cLevels.indexOf(level) + 1;

  /// "Kuala Lumpur · city".
  String get label => '$name · $level';

  /// The places it sits in, nearest first ("Selangor, Malaysia").
  String get within => [
    if (rank > 3) city,
    if (rank > 2) state,
    if (rank > 1) country,
  ].whereType<String>().join(', ');

  /// Same place.
  String get key => [level, country, state, city, suburb].map((s) => (s ?? '').toLowerCase()).join('|');

  /// How specifically it holds the trip end [g]: [rank], or 0.
  int holds(Geo g) => switch (level) {
    'suburb' =>
      _same(suburb, g.suburb) && _parentOk(city, g.city) && _parentOk(state, g.state) && _parentOk(country, g.country)
          ? 4
          : 0,
    'city' => _same(city, g.city) && _parentOk(state, g.state) && _parentOk(country, g.country) ? 3 : 0,
    'state' => _same(state, g.state) && _parentOk(country, g.country) ? 2 : 0,
    _ => _same(country, g.country) ? 1 : 0,
  };

  /// As stored: the level, the country and the names down to the level.
  Map<String, dynamic> toJson() => {
    'level': level,
    'country': country,
    if (rank >= 2 && state != null) 'state': state,
    if (rank >= 3 && city != null) 'city': city,
    if (rank >= 4 && suburb != null) 'suburb': suburb,
  };

  /// Why it can't be saved, or null.
  String? get problem {
    if (country.trim().isEmpty) return 'A place needs its country.';
    if (name.trim().isEmpty) return 'A $level needs its name.';
    return null;
  }

  @override
  bool operator ==(Object other) => other is C2cPlace && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

List<C2cPlace> c2cPlacesFrom(Object? raw) => [
  if (raw is List)
    for (final e in raw)
      if (e is Map) C2cPlace.fromJson(Map<String, dynamic>.from(e)),
];

/// The most specific of [places] that holds [g]; 0 for none.
int c2cSideRank(List<C2cPlace> places, Geo g) => places.fold(0, (m, p) => math.max(m, p.holds(g)));

/// How the fare is worked out.
enum C2cFareMode {
  card('card', 'Fare card + add-on'),
  fixed('fixed', 'Fixed fare');

  const C2cFareMode(this.key, this.label);
  final String key;
  final String label;
  static C2cFareMode of(Object? v) => v == 'fixed' ? fixed : card;
}

/// How the suggested range is set.
enum C2cRangeMode {
  auto('auto', 'Auto ±%'),
  set('set', 'Set range');

  const C2cRangeMode(this.key, this.label);
  final String key;
  final String label;
  static C2cRangeMode of(Object? v) => v == 'set' ? set : auto;
}

/// Minimum years of driving for a rule.
enum C2cYearsMode {
  byDefault('default', 'Use default'),
  set('set', 'Set years'),
  off('off', 'No restriction');

  const C2cYearsMode(this.key, this.label);
  final String key;
  final String label;
  static C2cYearsMode of(Object? v) => switch (v) {
    'set' => set,
    'off' => off,
    _ => byDefault,
  };
}

/// One route rule (c2c_route_rules).
class C2cRule {
  const C2cRule({
    this.id,
    this.from = const [],
    this.to = const [],
    this.fareMode = C2cFareMode.card,
    this.addOnAmount = 0,
    this.addOnPercent = 0,
    this.fixedFare,
    this.rangeMode = C2cRangeMode.auto,
    this.rangePercent = 8,
    this.rangeLow,
    this.rangeHigh,
    this.bookAheadDays = 14,
    this.yearsMode = C2cYearsMode.byDefault,
    this.minYears,
    this.tripKind = 'whole_car',
    this.active = true,
    this.position = 0,
    this.createdAt,
  });

  factory C2cRule.fromRow(Map<String, dynamic> r) => C2cRule(
    id: _nz(r['id']),
    from: c2cPlacesFrom(r['from_places']),
    to: c2cPlacesFrom(r['to_places']),
    fareMode: C2cFareMode.of(r['fare_mode']),
    addOnAmount: _num(r['add_on_amount']),
    addOnPercent: _num(r['add_on_percent']),
    fixedFare: _numOrNull(r['fixed_fare']),
    rangeMode: C2cRangeMode.of(r['range_mode']),
    rangePercent: _num(r['range_percent'], 8),
    rangeLow: _numOrNull(r['range_low']),
    rangeHigh: _numOrNull(r['range_high']),
    bookAheadDays: _num(r['book_ahead_days'], 14).round(),
    yearsMode: C2cYearsMode.of(r['min_years_mode']),
    minYears: _numOrNull(r['min_years'])?.round(),
    tripKind: _nz(r['trip_kind']) ?? 'whole_car',
    active: r['active'] != false,
    position: _num(r['position']).round(),
    createdAt: DateTime.tryParse('${r['created_at'] ?? ''}'),
  );

  final String? id;
  final List<C2cPlace> from, to;
  final C2cFareMode fareMode;
  final double addOnAmount, addOnPercent;
  final double? fixedFare;
  final C2cRangeMode rangeMode;
  final double rangePercent;
  final double? rangeLow, rangeHigh;
  final int bookAheadDays;
  final C2cYearsMode yearsMode;
  final int? minYears;

  /// 'whole_car' (launch); 'per_seat' is kept for later and never matched.
  final String tripKind;
  final bool active;
  final int position;
  final DateTime? createdAt;

  C2cRule copyWith({
    List<C2cPlace>? from,
    List<C2cPlace>? to,
    C2cFareMode? fareMode,
    double? addOnAmount,
    double? addOnPercent,
    double? fixedFare,
    C2cRangeMode? rangeMode,
    double? rangePercent,
    double? rangeLow,
    double? rangeHigh,
    int? bookAheadDays,
    C2cYearsMode? yearsMode,
    int? minYears,
    bool? active,
    int? position,
  }) => C2cRule(
    id: id,
    from: from ?? this.from,
    to: to ?? this.to,
    fareMode: fareMode ?? this.fareMode,
    addOnAmount: addOnAmount ?? this.addOnAmount,
    addOnPercent: addOnPercent ?? this.addOnPercent,
    fixedFare: fixedFare ?? this.fixedFare,
    rangeMode: rangeMode ?? this.rangeMode,
    rangePercent: rangePercent ?? this.rangePercent,
    rangeLow: rangeLow ?? this.rangeLow,
    rangeHigh: rangeHigh ?? this.rangeHigh,
    bookAheadDays: bookAheadDays ?? this.bookAheadDays,
    yearsMode: yearsMode ?? this.yearsMode,
    minYears: minYears ?? this.minYears,
    tripKind: tripKind,
    active: active ?? this.active,
    position: position ?? this.position,
    createdAt: createdAt,
  );

  /// The row as stored (without the server's stamps).
  Map<String, dynamic> toRow() => {
    if (id != null) 'id': id,
    'from_places': [for (final p in from) p.toJson()],
    'to_places': [for (final p in to) p.toJson()],
    'fare_mode': fareMode.key,
    'add_on_amount': addOnAmount,
    'add_on_percent': addOnPercent,
    'fixed_fare': fareMode == C2cFareMode.fixed ? fixedFare : null,
    'range_mode': rangeMode.key,
    'range_percent': rangePercent,
    'range_low': rangeMode == C2cRangeMode.set ? rangeLow : null,
    'range_high': rangeMode == C2cRangeMode.set ? rangeHigh : null,
    'book_ahead_days': bookAheadDays,
    'min_years_mode': yearsMode.key,
    'min_years': yearsMode == C2cYearsMode.set ? minYears : null,
    'active': active,
    'position': position,
  };
}

/// City to City settings (city_to_city_settings, one row).
class C2cSettings {
  const C2cSettings({
    this.cancelFeeOn = true,
    this.cancelFeeAmount = 20,
    this.cancelFreeHours = 24,
    this.payInApp = true,
    this.payCash = true,
    this.minYearsOn = true,
    this.minYears = 3,
    this.defaultAddOnAmount = 0,
    this.defaultAddOnPercent = 0,
    this.defaultRangeMode = C2cRangeMode.auto,
    this.defaultRangePercent = 8,
    this.defaultRangeLow,
    this.defaultRangeHigh,
    this.defaultBookAheadDays = 14,
    this.currency = 'MYR',
  });

  factory C2cSettings.fromRow(Map<String, dynamic>? r) {
    if (r == null) return const C2cSettings();
    return C2cSettings(
      cancelFeeOn: r['cancel_fee_on'] != false,
      cancelFeeAmount: _num(r['cancel_fee_amount'], 20),
      cancelFreeHours: _num(r['cancel_free_hours'], 24).round(),
      payInApp: r['pay_in_app'] != false,
      payCash: r['pay_cash'] != false,
      minYearsOn: r['min_years_on'] != false,
      minYears: _num(r['min_years'], 3).round(),
      defaultAddOnAmount: _num(r['default_add_on_amount']),
      defaultAddOnPercent: _num(r['default_add_on_percent']),
      defaultRangeMode: C2cRangeMode.of(r['default_range_mode']),
      defaultRangePercent: _num(r['default_range_percent'], 8),
      defaultRangeLow: _numOrNull(r['default_range_low']),
      defaultRangeHigh: _numOrNull(r['default_range_high']),
      defaultBookAheadDays: _num(r['default_book_ahead_days'], 14).round(),
      currency: (_nz(r['currency']) ?? 'MYR').toUpperCase(),
    );
  }

  final bool cancelFeeOn;
  final double cancelFeeAmount;
  final int cancelFreeHours;
  final bool payInApp, payCash;
  final bool minYearsOn;
  final int minYears;
  final double defaultAddOnAmount, defaultAddOnPercent;
  final C2cRangeMode defaultRangeMode;
  final double defaultRangePercent;
  final double? defaultRangeLow, defaultRangeHigh;
  final int defaultBookAheadDays;
  final String currency;

  /// The default rule, for the quote and the editor: the fare card plus the
  /// default add-on, with its own range.
  C2cRule get defaultRule => C2cRule(
    addOnAmount: defaultAddOnAmount,
    addOnPercent: defaultAddOnPercent,
    rangeMode: defaultRangeMode,
    rangePercent: defaultRangePercent,
    rangeLow: defaultRangeLow,
    rangeHigh: defaultRangeHigh,
    bookAheadDays: defaultBookAheadDays,
  );

  C2cSettings copyWith({
    bool? cancelFeeOn,
    double? cancelFeeAmount,
    int? cancelFreeHours,
    bool? payInApp,
    bool? payCash,
    bool? minYearsOn,
    int? minYears,
    C2cRule? defaultRule,
  }) => C2cSettings(
    cancelFeeOn: cancelFeeOn ?? this.cancelFeeOn,
    cancelFeeAmount: cancelFeeAmount ?? this.cancelFeeAmount,
    cancelFreeHours: cancelFreeHours ?? this.cancelFreeHours,
    payInApp: payInApp ?? this.payInApp,
    payCash: payCash ?? this.payCash,
    minYearsOn: minYearsOn ?? this.minYearsOn,
    minYears: minYears ?? this.minYears,
    defaultAddOnAmount: defaultRule?.addOnAmount ?? defaultAddOnAmount,
    defaultAddOnPercent: defaultRule?.addOnPercent ?? defaultAddOnPercent,
    defaultRangeMode: defaultRule?.rangeMode ?? defaultRangeMode,
    defaultRangePercent: defaultRule?.rangePercent ?? defaultRangePercent,
    defaultRangeLow: defaultRule == null ? defaultRangeLow : defaultRule.rangeLow,
    defaultRangeHigh: defaultRule == null ? defaultRangeHigh : defaultRule.rangeHigh,
    defaultBookAheadDays: defaultRule?.bookAheadDays ?? defaultBookAheadDays,
    currency: currency,
  );

  Map<String, dynamic> toRow() => {
    'cancel_fee_on': cancelFeeOn,
    'cancel_fee_amount': cancelFeeAmount,
    'cancel_free_hours': cancelFreeHours,
    'pay_in_app': payInApp,
    'pay_cash': payCash,
    'min_years_on': minYearsOn,
    'min_years': minYears,
    'default_add_on_amount': defaultAddOnAmount,
    'default_add_on_percent': defaultAddOnPercent,
    'default_range_mode': defaultRangeMode.key,
    'default_range_percent': defaultRangePercent,
    'default_range_low': defaultRangeMode == C2cRangeMode.set ? defaultRangeLow : null,
    'default_range_high': defaultRangeMode == C2cRangeMode.set ? defaultRangeHigh : null,
    'default_book_ahead_days': defaultBookAheadDays,
  };

  /// What riders see about cancelling.
  String get cancelLine => cancelFeeOn
      ? 'Free to cancel until $cancelFreeHours ${cancelFreeHours == 1 ? 'hour' : 'hours'} before, '
            'then ${c2cMoney(cancelFeeAmount, currency)}.'
      : 'Free to cancel any time.';

  /// Why they can't be saved, or null.
  String? get problem {
    if (!payInApp && !payCash) return 'Keep at least one payment method on.';
    if (cancelFeeOn && cancelFeeAmount <= 0) return 'Set the cancel fee, or turn it off.';
    return c2cRuleProblem(defaultRule, isDefault: true);
  }
}

/// [v] in [currency]: "RM 20", "RM 135.99".
String c2cMoney(double v, [String currency = 'MYR']) {
  final symbol = currency.toUpperCase() == 'MYR' ? 'RM' : currency.toUpperCase();
  final whole = v == v.roundToDouble();
  return '$symbol ${whole ? v.toStringAsFixed(0) : v.toStringAsFixed(2)}';
}

/// The winning rule for a whole-car trip from [pickup] to [drop], with how
/// specifically each end matched; null for the default.
({C2cRule rule, int from, int to})? c2cRuleFor(List<C2cRule> rules, Geo pickup, Geo drop) {
  ({C2cRule rule, int from, int to})? best;
  int cmp(({C2cRule rule, int from, int to}) a, ({C2cRule rule, int from, int to}) b) {
    final c = [
      (b.from + b.to).compareTo(a.from + a.to),
      b.from.compareTo(a.from),
      a.rule.position.compareTo(b.rule.position),
      (a.rule.createdAt ?? DateTime(0)).compareTo(b.rule.createdAt ?? DateTime(0)),
      (a.rule.id ?? '').compareTo(b.rule.id ?? ''),
    ].firstWhere((v) => v != 0, orElse: () => 0);
    return c;
  }

  for (final r in rules) {
    if (!r.active || r.tripKind != 'whole_car') continue;
    final f = c2cSideRank(r.from, pickup), t = c2cSideRank(r.to, drop);
    if (f == 0 || t == 0) continue;
    final hit = (rule: r, from: f, to: t);
    if (best == null || cmp(hit, best) < 0) best = hit;
  }
  return best;
}

/// The fare card for a trip from [pickup]: the Fare tariffs card for the
/// place and the service (its own card, its type's, every service's),
/// else the service's own [rates], else the TEKSI tariff. No service
/// multiplier.
({double fare, String currency, FareTariff? card}) c2cFareCard(
  List<FareTariff> cards,
  Geo pickup,
  double distanceKm,
  double durationMin, {
  String? vehicleService,
  Set<String> serviceTypes = const {},
  ServiceRates? rates,
  String currency = 'MYR',
}) {
  final card = resolveFareTariff(cards, pickup, vehicleService: vehicleService, serviceTypes: serviceTypes);
  if (card != null) {
    return (fare: tariffFare(card, distanceKm, durationMin), currency: card.currency, card: card);
  }
  return (
    fare: rates?.fare(distanceKm, durationMin) ?? calculateFare(distanceKm, durationMin),
    currency: currency,
    card: null,
  );
}

/// What a rule asks of a driver: years of driving, or null for none.
int? c2cMinYears(C2cRule? rule, C2cSettings s) {
  if (!s.minYearsOn) return null;
  if (rule == null) return s.minYears;
  return switch (rule.yearsMode) {
    C2cYearsMode.byDefault => s.minYears,
    C2cYearsMode.set => rule.minYears,
    C2cYearsMode.off => null,
  };
}

/// A quote (as c2c_quote returns it).
class C2cQuote {
  const C2cQuote({
    required this.ruleId,
    required this.fareMode,
    required this.fareCard,
    required this.addOn,
    required this.suggested,
    required this.low,
    required this.high,
    required this.rangeMode,
    required this.rangePercent,
    required this.bookAheadDays,
    required this.minYears,
    required this.currency,
  });

  final String? ruleId;
  final C2cFareMode fareMode;

  /// The fare card; null for a fixed fare.
  final double? fareCard;
  final double addOn, suggested;
  final double? low, high;
  final C2cRangeMode rangeMode;
  final double rangePercent;
  final int bookAheadDays;
  final int? minYears;
  final String currency;

  /// Whether the suggestion sits inside its range.
  bool get inRange => low == null || high == null || (low! <= suggested && suggested <= high! && low! <= high!);
}

/// The quote under [rule] (null: the settings' default) with the trip's
/// [fareCard] (used only by the card mode).
C2cQuote c2cQuoteFor(C2cRule? rule, C2cSettings s, {required double fareCard, String? currency}) {
  final r = rule ?? s.defaultRule;
  final fixed = rule != null && r.fareMode == C2cFareMode.fixed;
  final suggested = fixed
      ? c2cRound2(r.fixedFare ?? 0)
      : c2cRound2(fareCard + r.addOnAmount + fareCard * r.addOnPercent / 100);
  final auto = r.rangeMode == C2cRangeMode.auto;
  return C2cQuote(
    ruleId: rule?.id,
    fareMode: fixed ? C2cFareMode.fixed : C2cFareMode.card,
    fareCard: fixed ? null : fareCard,
    addOn: fixed ? 0 : c2cRound2(suggested - fareCard),
    suggested: suggested,
    low: auto ? c2cRound0(suggested * (1 - r.rangePercent / 100)) : r.rangeLow,
    high: auto ? c2cRound0(suggested * (1 + r.rangePercent / 100)) : r.rangeHigh,
    rangeMode: r.rangeMode,
    rangePercent: r.rangePercent,
    bookAheadDays: r.bookAheadDays,
    minYears: c2cMinYears(rule, s),
    currency: currency ?? s.currency,
  );
}

/// The quote for a trip: the rule for [pickup] to [drop] among [rules],
/// and [fareCard] for the card mode.
C2cQuote c2cQuote(List<C2cRule> rules, C2cSettings s, Geo pickup, Geo drop, {required double fareCard, String? currency}) =>
    c2cQuoteFor(c2cRuleFor(rules, pickup, drop)?.rule, s, fareCard: fareCard, currency: currency);

/// Why [r] can't be saved, or null. The default rule has no places and is
/// always the fare card.
String? c2cRuleProblem(C2cRule r, {bool isDefault = false}) {
  if (!isDefault && (r.from.isEmpty || r.to.isEmpty)) return 'Add at least one place to From and To.';
  for (final p in [...r.from, ...r.to]) {
    final why = p.problem;
    if (why != null) return why;
  }
  if (r.addOnAmount < 0 || r.addOnPercent < 0) return 'An add-on can\'t be below 0.';
  if (!isDefault && r.fareMode == C2cFareMode.fixed && (r.fixedFare ?? 0) < 1) return 'Set the fare per car.';
  if (r.rangeMode == C2cRangeMode.auto && (r.rangePercent < 0 || r.rangePercent > 90)) {
    return 'Plus or minus is between 0 and 90%.';
  }
  if (r.rangeMode == C2cRangeMode.set) {
    final lo = r.rangeLow, hi = r.rangeHigh;
    if (lo == null || hi == null || lo <= 0) return 'Set the range low and high.';
    if (lo > hi) return 'The range low is at or below the high.';
    if (!isDefault && r.fareMode == C2cFareMode.fixed && (r.fixedFare! < lo || r.fixedFare! > hi)) {
      return 'The fixed fare should sit inside the range.';
    }
  }
  if (r.bookAheadDays < 1 || r.bookAheadDays > 365) return 'Book ahead is 1 to 365 days.';
  if (r.yearsMode == C2cYearsMode.set && (r.minYears == null || r.minYears! < 0)) return 'Set the years.';
  return null;
}

/// The fare as the rules list prints it: "Fare card + RM 20", "Fixed RM 190".
String c2cFareText(C2cRule r, {String currency = 'MYR', bool isDefault = false}) {
  if (!isDefault && r.fareMode == C2cFareMode.fixed) return 'Fixed ${c2cMoney(r.fixedFare ?? 0, currency)}';
  final parts = [
    if (r.addOnAmount > 0) c2cMoney(r.addOnAmount, currency),
    if (r.addOnPercent > 0) '${_pct(r.addOnPercent)}%',
  ];
  return 'Fare card + ${parts.isEmpty ? c2cMoney(0, currency) : parts.join(' + ')}';
}

/// "Auto ± 8%", "RM 130 to RM 150".
String c2cRangeText(C2cRule r, {String currency = 'MYR'}) => r.rangeMode == C2cRangeMode.auto
    ? 'Auto ± ${_pct(r.rangePercent)}%'
    : '${c2cMoney(r.rangeLow ?? 0, currency)} to ${c2cMoney(r.rangeHigh ?? 0, currency)}';

/// "Default (3)", "5 years", "Off".
String c2cYearsText(C2cRule r, C2cSettings s) => switch (r.yearsMode) {
  C2cYearsMode.byDefault => s.minYearsOn ? 'Default (${s.minYears})' : 'Default (off)',
  C2cYearsMode.set => '${r.minYears ?? 0} ${r.minYears == 1 ? 'year' : 'years'}',
  C2cYearsMode.off => 'Off',
};

String _pct(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

// ---- Drivers ----------------------------------------------------------------------------------------

/// A permit needed in a country (c2c_country_permits with its type).
class C2cCountryPermit {
  const C2cCountryPermit({
    this.id,
    required this.country,
    required this.permitTypeId,
    this.name = '',
    this.appliesTo = 'driver',
    this.position = 0,
  });

  factory C2cCountryPermit.fromRow(Map<String, dynamic> r) {
    final t = r['permit_types'] is Map ? Map<String, dynamic>.from(r['permit_types'] as Map) : const {};
    return C2cCountryPermit(
      id: _nz(r['id']),
      country: _nz(r['country']) ?? '',
      permitTypeId: _nz(r['permit_type_id']) ?? '',
      name: _nz(t['name']) ?? _nz(r['name']) ?? 'Permit',
      appliesTo: r['applies_to'] == 'vehicle' ? 'vehicle' : 'driver',
      position: _num(r['position']).round(),
    );
  }

  final String? id;
  final String country;
  final String permitTypeId;
  final String name;

  /// driver | vehicle.
  final String appliesTo;
  final int position;

  /// "PSV licence (driver)".
  String get label => '$name ($appliesTo)';
}

/// Whole years of driving from [since] to [today].
int drivingYears(DateTime since, DateTime today) {
  var y = today.year - since.year;
  if (today.month < since.month || (today.month == since.month && today.day < since.day)) y--;
  return math.max(0, y);
}

/// What a driver lacks for a trip touching [countries]: the permits of
/// [permits] for those countries not in [held] (permit type ids).
List<C2cCountryPermit> c2cPermitsNeeded(
  List<C2cCountryPermit> permits,
  Iterable<String> countries,
  Set<String> held,
) {
  final seen = <String>{};
  return [
    for (final p in permits)
      if (countries.any((c) => _same(p.country, c)) && !held.contains(p.permitTypeId) && seen.add(p.permitTypeId)) p,
  ];
}

/// Whether a driver may take a trip: enough years ([minYears] null: any)
/// and nothing in [needs]. Unknown experience ([years] null) is not enough.
bool c2cDriverOk({required int? minYears, required int? years, required List<C2cCountryPermit> needs}) =>
    (minYears == null || (years != null && years >= minYears)) && needs.isEmpty;

// ---- Commission per service ---------------------------------------------------------------------------

/// Where a trip's commission rate comes from.
enum CommissionSource { user, promotion, service, place }

/// The rate a trip pays: the driver's own [userRate] first; else the
/// service's [serviceRate] or the [placeRate], lowered by a running
/// [promotionRate] below it (as migrations 0224 and 0306 lock it; tiers
/// lower the service or place rate the same way before the promotion).
({double rate, CommissionSource source}) commissionForService({
  double? userRate,
  double? promotionRate,
  double? serviceRate,
  required double placeRate,
}) {
  if (userRate != null) return (rate: userRate, source: CommissionSource.user);
  final base = serviceRate ?? placeRate;
  if (promotionRate != null && promotionRate < base) return (rate: promotionRate, source: CommissionSource.promotion);
  return (rate: base, source: serviceRate != null ? CommissionSource.service : CommissionSource.place);
}

// ---- Bookings (0307) ------------------------------------------------------------------------------

/// The rider's City to City page.
const c2cPageRoute = '/city-to-city';

/// How long before leaving a trip can be booked at the latest (0307).
const c2cMinLead = Duration(hours: 1);

/// How far either side of the rider's time a flexible trip may leave.
const c2cFlexWindow = Duration(minutes: 30);

/// Trips a rider may have under way at once (0307, C2C_TOO_MANY).
const c2cMaxUnderWay = 3;

/// Passengers in a whole car: 1 to 6 (5 or 6: an MPV).
const c2cMaxPassengers = 6;

/// Where a request or booking is.
enum C2cStatus {
  open('open', 'Waiting for offers'),
  offered('offered', 'Offers in'),
  booked('booked', 'Booked'),
  driverArriving('driver_arriving', 'Driver on the way'),
  onTrip('on_trip', 'On the trip'),
  completed('completed', 'Completed'),
  cancelled('cancelled', 'Cancelled'),
  expired('expired', 'Expired');

  const C2cStatus(this.key, this.label);
  final String key;
  final String label;
  static C2cStatus of(Object? v) => values.firstWhere((s) => s.key == v, orElse: () => open);

  /// No driver yet: drivers offer, the rider picks.
  bool get waiting => this == open || this == offered;

  /// A driver is booked and the trip has not ended.
  bool get withDriver => this == booked || this == driverArriving || this == onTrip;

  /// Over: completed, cancelled or expired.
  bool get ended => this == completed || this == cancelled || this == expired;
}

/// What the rider brings.
enum C2cLuggage {
  none('none', 'No bags'),
  small('small', 'Small bags'),
  suitcases('suitcases', '1 to 2 suitcases'),
  many('many', '3+ suitcases');

  const C2cLuggage(this.key, this.label);
  final String key;
  final String label;
  static C2cLuggage of(Object? v) => values.firstWhere((s) => s.key == v, orElse: () => small);
}

/// How the rider pays.
enum C2cPayment {
  inApp('in_app', 'In app'),
  cash('cash', 'Cash');

  const C2cPayment(this.key, this.label);
  final String key;
  final String label;
  static C2cPayment of(Object? v) => v == 'in_app' ? inApp : cash;
}

/// The payment methods the settings allow, In app first.
List<C2cPayment> c2cPayments(C2cSettings s) => [if (s.payInApp) C2cPayment.inApp, if (s.payCash) C2cPayment.cash];

/// A quote as c2c_quote returns it (0306), or as a booking keeps it.
C2cQuote c2cQuoteFromJson(Map<String, dynamic> j, {String currency = 'MYR'}) => C2cQuote(
  ruleId: _nz(j['ruleId']),
  fareMode: C2cFareMode.of(j['fareMode']),
  fareCard: _numOrNull(j['fareCard']),
  addOn: _num(j['addOn']),
  suggested: _num(j['suggested']),
  low: _numOrNull(j['low']),
  high: _numOrNull(j['high']),
  rangeMode: C2cRangeMode.of(j['rangeMode']),
  rangePercent: _num(j['rangePercent'], 8),
  bookAheadDays: _num(j['bookAheadDays'], 14).round(),
  minYears: _numOrNull(j['minYears'])?.round(),
  currency: (_nz(j['currency']) ?? currency).toUpperCase(),
);

/// A trip request and, once a driver is picked, the booking (c2c_bookings).
class C2cBooking {
  const C2cBooking({
    required this.id,
    this.ref = '',
    required this.pickupName,
    this.pickupAddress,
    this.pickupPlace = const Geo(),
    required this.dropName,
    this.dropAddress,
    this.dropPlace = const Geo(),
    this.distanceKm = 0,
    this.durationMin = 0,
    required this.leaveAt,
    this.flexible = true,
    this.passengers = 1,
    this.luggage = C2cLuggage.small,
    required this.fare,
    this.currency = 'MYR',
    this.quote,
    this.payment = C2cPayment.cash,
    this.status = C2cStatus.open,
    this.expiresAt,
    this.driverId,
    this.agreedFare,
    this.driverLeaveAt,
    this.cancelledBy,
    this.cancelFee,
    this.cancelFeeStatus,
    this.riderStars,
    this.createdAt,
  });

  factory C2cBooking.fromRow(Map<String, dynamic> r) {
    Geo geo(Object? v) {
      final m = v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
      return Geo(country: _nz(m['country']), state: _nz(m['state']), city: _nz(m['city']), suburb: _nz(m['suburb']));
    }

    DateTime? at(Object? v) => DateTime.tryParse('${v ?? ''}')?.toLocal();
    final currency = (_nz(r['currency']) ?? 'MYR').toUpperCase();
    final q = r['quote'] is Map ? Map<String, dynamic>.from(r['quote'] as Map) : null;
    return C2cBooking(
      id: '${r['id']}',
      ref: _nz(r['ref']) ?? '',
      pickupName: _nz(r['pickup_name']) ?? 'Pickup',
      pickupAddress: _nz(r['pickup_address']),
      pickupPlace: geo(r['pickup_place']),
      dropName: _nz(r['drop_name']) ?? 'Drop-off',
      dropAddress: _nz(r['drop_address']),
      dropPlace: geo(r['drop_place']),
      distanceKm: _num(r['distance_km']),
      durationMin: _num(r['duration_min']),
      leaveAt: at(r['leave_at']) ?? DateTime.now(),
      flexible: r['flexible'] != false,
      passengers: _num(r['passengers'], 1).round(),
      luggage: C2cLuggage.of(r['luggage']),
      fare: _num(r['fare']),
      currency: currency,
      quote: q == null || q.isEmpty ? null : c2cQuoteFromJson(q, currency: currency),
      payment: C2cPayment.of(r['payment']),
      status: C2cStatus.of(r['status']),
      expiresAt: at(r['expires_at']),
      driverId: _nz(r['driver_id']),
      agreedFare: _numOrNull(r['agreed_fare']),
      driverLeaveAt: at(r['driver_leave_at']),
      cancelledBy: _nz(r['cancelled_by']),
      cancelFee: _numOrNull(r['cancel_fee']),
      cancelFeeStatus: _nz(r['cancel_fee_status']),
      riderStars: _numOrNull(r['rider_stars'])?.round(),
      createdAt: at(r['created_at']),
    );
  }

  final String id;

  /// "CC-20481".
  final String ref;
  final String pickupName, dropName;
  final String? pickupAddress, dropAddress;
  final Geo pickupPlace, dropPlace;
  final double distanceKm, durationMin;
  final DateTime leaveAt;

  /// ± 30 minutes is fine.
  final bool flexible;
  final int passengers;
  final C2cLuggage luggage;

  /// The rider's fare for the whole car.
  final double fare;
  final String currency;
  final C2cQuote? quote;
  final C2cPayment payment;
  final C2cStatus status;
  final DateTime? expiresAt;
  final String? driverId;
  final double? agreedFare;
  final DateTime? driverLeaveAt;

  /// rider | driver | admin.
  final String? cancelledBy;
  final double? cancelFee;

  /// charged | due | none.
  final String? cancelFeeStatus;
  final int? riderStars;
  final DateTime? createdAt;

  /// What the trip costs now: the agreed fare once booked, else the rider's.
  double get price => agreedFare ?? fare;

  /// When the car leaves: the driver's time once booked, else the rider's.
  DateTime get leaves => driverLeaveAt ?? leaveAt;

  /// "Kuala Lumpur to Ipoh": the cities (else the names).
  String get route => '${pickupPlace.city ?? pickupPlace.state ?? pickupName} to ${dropPlace.city ?? dropPlace.state ?? dropName}';

  /// The pickup line: "12 Jalan Ampang, Kuala Lumpur".
  String get pickupLine => c2cAddressLine(pickupName, pickupPlace);

  String get dropLine => c2cAddressLine(dropName, dropPlace);
}

/// "12 Jalan Ampang, Kuala Lumpur": the name, then the city when the name
/// doesn't already say it.
String c2cAddressLine(String name, Geo place) {
  final city = place.city ?? place.state;
  if (city == null || name.toLowerCase().contains(city.toLowerCase())) return name;
  return '$name, $city';
}

/// A driver's offer on a request (c2c_offers).
class C2cOffer {
  const C2cOffer({
    required this.id,
    required this.bookingId,
    required this.driverId,
    required this.price,
    required this.leaveAt,
    this.driverName = 'Driver',
    this.rating,
    this.trips,
    this.car,
    this.plate,
    this.status = 'open',
    this.createdAt,
  });

  factory C2cOffer.fromRow(Map<String, dynamic> r) => C2cOffer(
    id: '${r['id']}',
    bookingId: '${r['booking_id']}',
    driverId: '${r['driver_id']}',
    price: _num(r['price']),
    leaveAt: DateTime.tryParse('${r['leave_at'] ?? ''}')?.toLocal() ?? DateTime.now(),
    driverName: _nz(r['driver_name']) ?? 'Driver',
    rating: _numOrNull(r['driver_rating']),
    trips: _numOrNull(r['driver_trips'])?.round(),
    car: _nz(r['car']),
    plate: _nz(r['plate']),
    status: _nz(r['status']) ?? 'open',
    createdAt: DateTime.tryParse('${r['created_at'] ?? ''}')?.toLocal(),
  );

  final String id, bookingId, driverId;
  final double price;
  final DateTime leaveAt;
  final String driverName;
  final double? rating;
  final int? trips;
  final String? car, plate;

  /// open | accepted | declined | withdrawn | expired.
  final String status;
  final DateTime? createdAt;

  bool get open => status == 'open';

  /// "AC" for Aiman Contoh.
  String get initials => c2cInitials(driverName);

  /// "4.9 (312 trips)", "New driver".
  String get ratingLine {
    final r = rating, t = trips;
    if (r == null || r <= 0) return t == null || t == 0 ? 'New driver' : '$t ${t == 1 ? 'trip' : 'trips'}';
    return '${r.toStringAsFixed(1)}${t == null ? '' : ' ($t ${t == 1 ? 'trip' : 'trips'})'}';
  }

  /// "Proton X50, VKA 2231".
  String get carLine => [?car, ?plate].join(', ');
}

/// Up to two capitals of [name]: "AC" for "Aiman Contoh".
String c2cInitials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  return words.take(2).map((w) => w[0].toUpperCase()).join();
}

/// How an offer's price sits against the rider's [fare]: "Your fare",
/// "+ RM 5", "- RM 5".
String c2cOfferDiff(double price, double fare, [String currency = 'MYR']) {
  final d = c2cRound2(price - fare);
  if (d == 0) return 'Your fare';
  return '${d > 0 ? '+' : '-'} ${c2cMoney(d.abs(), currency)}';
}

/// What a cancel at [at] costs for a booked trip leaving at [leaveAt], as
/// the server's c2c_cancel_fee (0307): 0 while the fee is off or until the
/// free hours before, then the amount. A request with no driver yet is free.
double c2cCancelFee(C2cSettings s, DateTime leaveAt, DateTime at, {bool booked = true}) {
  if (!booked || !s.cancelFeeOn) return 0;
  if (at.isBefore(c2cFreeCancelUntil(s, leaveAt))) return 0;
  return c2cRound2(s.cancelFeeAmount);
}

/// Until when a booked trip leaving at [leaveAt] cancels free.
DateTime c2cFreeCancelUntil(C2cSettings s, DateTime leaveAt) => leaveAt.subtract(Duration(hours: s.cancelFreeHours));

/// What the booked trip says about cancelling: "Free to cancel until 24
/// hours before (Thu 29 Oct, 9:00), then RM 20. The fee goes to the
/// driver.", or "Free to cancel any time."
String c2cCancelText(C2cSettings s, DateTime leaveAt) {
  if (!s.cancelFeeOn) return 'Free to cancel any time.';
  final until = c2cFreeCancelUntil(s, leaveAt);
  final h = s.cancelFreeHours;
  return 'Free to cancel until $h ${h == 1 ? 'hour' : 'hours'} before (${c2cDayTime(until)}), '
      'then ${c2cMoney(s.cancelFeeAmount, s.currency)}. The fee goes to the driver.';
}

/// Why [fare] can't be sent under [q], as the server says it (0307,
/// C2C_FARE_OUT_OF_RANGE), or null.
String? c2cFareProblem(double fare, C2cQuote q) {
  if (q.fareMode == C2cFareMode.fixed) {
    return c2cRound2(fare) == c2cRound2(q.suggested)
        ? null
        : 'This route has a fixed fare of ${c2cMoney(q.suggested, q.currency)}.';
  }
  final lo = q.low, hi = q.high;
  if (lo != null && hi != null && (fare < lo || fare > hi)) {
    return 'Your fare must be between ${c2cMoney(lo, q.currency)} and ${c2cMoney(hi, q.currency)}.';
  }
  return null;
}

/// Why leaving at [leaveAt] can't be booked at [now] with [bookAheadDays]
/// (0307: C2C_TOO_SOON, C2C_TOO_FAR_AHEAD), or null.
String? c2cLeaveProblem(DateTime leaveAt, DateTime now, int bookAheadDays) {
  if (leaveAt.isBefore(now.add(c2cMinLead))) return 'Leave at least 1 hour from now.';
  if (leaveAt.isAfter(now.add(Duration(days: bookAheadDays)))) {
    return 'Book up to $bookAheadDays ${bookAheadDays == 1 ? 'day' : 'days'} ahead on this route.';
  }
  return null;
}

/// The fare the Price step starts at: the fixed fare, else the suggestion
/// rounded to the nearest RM [step], kept within the range.
double c2cStartFare(C2cQuote q, {double step = 5}) {
  if (q.fareMode == C2cFareMode.fixed) return c2cRound2(q.suggested);
  return c2cClampFare((q.suggested / step).round() * step, q);
}

/// [fare] kept within [q]'s range.
double c2cClampFare(double fare, C2cQuote q) {
  final lo = q.low, hi = q.high;
  var f = fare;
  if (lo != null && f < lo) f = lo;
  if (hi != null && f > hi) f = hi;
  return c2cRound2(f);
}

/// [fare] moved by [by] steps of RM [step] (to the next whole step first),
/// within the range; a fixed fare doesn't move.
double c2cStepFare(double fare, int by, C2cQuote q, {double step = 5}) {
  if (q.fareMode == C2cFareMode.fixed) return c2cRound2(q.suggested);
  final base = by > 0 ? (fare / step).floor() * step : (fare / step).ceil() * step;
  return c2cClampFare(base + by * step, q);
}

/// Where [fare] sits on the Price step's bar, 0 to 1: the bar runs from 20%
/// of the range's width below it to 20% above.
({double start, double end, double at}) c2cFareBar(double fare, C2cQuote q) {
  final lo = q.low ?? q.suggested, hi = q.high ?? q.suggested;
  final pad = math.max((hi - lo) * 0.5, math.max(hi * 0.1, 1));
  final min = lo - pad, max = hi + pad;
  double pos(double v) => ((v - min) / (max - min)).clamp(0.0, 1.0);
  return (start: pos(lo), end: pos(hi), at: pos(fare));
}

/// "Fare card RM 118 + City to City RM 20 = RM 138 suggested", or "Fixed
/// fare RM 190 on this route".
String c2cQuoteLine(C2cQuote q) {
  if (q.fareMode == C2cFareMode.fixed) return 'Fixed fare ${c2cMoney(q.suggested, q.currency)} on this route';
  final card = q.fareCard ?? q.suggested;
  if (q.addOn == 0) return 'Fare card ${c2cMoney(card, q.currency)} suggested';
  return 'Fare card ${c2cMoney(card, q.currency)} + City to City ${c2cMoney(q.addOn, q.currency)} = '
      '${c2cMoney(q.suggested, q.currency)} suggested';
}

/// "Most drivers accept RM 130 to RM 150 for Kuala Lumpur to Ipoh."
String c2cRangeLine(C2cQuote q, String route) {
  final lo = q.low, hi = q.high;
  if (q.fareMode == C2cFareMode.fixed || lo == null || hi == null) {
    return 'Drivers take ${c2cMoney(q.suggested, q.currency)} for $route.';
  }
  return 'Most drivers accept ${c2cMoney(lo, q.currency)} to ${c2cMoney(hi, q.currency)} for $route.';
}

/// "Fri 30 Oct, 9:00".
String c2cDayTime(DateTime t) => DateFormat('EEE d MMM, H:mm').format(t);

/// "9:00".
String c2cClock(DateTime t) => DateFormat('H:mm').format(t);

/// "Leave Fri 30 Oct at 9:00".
String c2cLeaveText(DateTime t) => 'Leave ${DateFormat('EEE d MMM').format(t)} at ${c2cClock(t)}';

/// "Flexible, 8:30 to 9:30", or "Exact time".
String c2cFlexText(DateTime t, bool flexible) => flexible
    ? 'Flexible, ${c2cClock(t.subtract(c2cFlexWindow))} to ${c2cClock(t.add(c2cFlexWindow))}'
    : 'Exact time';

/// "Whole car, 2 passengers".
String c2cCarLine(int passengers) => 'Whole car, $passengers ${passengers == 1 ? 'passenger' : 'passengers'}';

/// The passengers step's hint.
String c2cPassengerHint(int passengers) =>
    passengers > 4 ? 'Who is travelling. 5 or 6: an MPV is matched' : 'Who is travelling, you included';

/// "Whole car · 2 passengers · 1 to 2 suitcases".
String c2cTripLine(int passengers, C2cLuggage luggage) =>
    'Whole car · $passengers ${passengers == 1 ? 'passenger' : 'passengers'} · ${luggage.label}';

/// What is left of [d], roughly: "2 d 14 h", "3 h 20 min", "14 min".
String c2cTimeLeft(Duration d) {
  if (d.inMinutes < 1) return 'less than a minute';
  if (d.inHours < 1) return '${d.inMinutes} min';
  if (d.inDays < 1) return '${d.inHours} h ${d.inMinutes % 60} min';
  return '${d.inDays} d ${d.inHours % 24} h';
}

/// The status line over the offers: "2 offers. Request open for 2 d 14 h
/// more.", "No offers yet. Drivers who can take the trip are told."
String c2cOffersLine(int offers, DateTime? expiresAt, DateTime now) {
  final left = expiresAt?.difference(now);
  final open = left == null || left.isNegative ? '' : ' Request open for ${c2cTimeLeft(left)} more.';
  if (offers == 0) return 'No offers yet. Drivers who can take the trip see it now.$open';
  return '$offers ${offers == 1 ? 'offer' : 'offers'}.$open';
}

/// "Arrive about 11:30": leaving at [leaves], [durationMin] on the road.
String c2cArriveText(DateTime leaves, double durationMin) =>
    'Arrive about ${c2cClock(leaves.add(Duration(minutes: durationMin.round())))}';

/// "205 km, about 2 h 40 min."
String c2cTripSize(double km, double min) {
  final m = min.round();
  final time = m < 60 ? '$m min' : '${m ~/ 60} h${m % 60 == 0 ? '' : ' ${m % 60} min'}';
  return '${km.round()} km, about $time.';
}

/// The words for a server refusal by code (0307), for when it gives none.
const c2cErrorWords = <String, String>{
  'C2C_NOT_AVAILABLE': "City to City isn't available from this pickup yet.",
  'C2C_BAD_TRIP': "The distance doesn't match the addresses. Pick them again.",
  'C2C_TOO_SOON': 'Leave at least 1 hour from now.',
  'C2C_TOO_FAR_AHEAD': "That's too far ahead for this route.",
  'C2C_FARE_OUT_OF_RANGE': 'Your fare is outside the range for this route.',
  'C2C_PAYMENT_NOT_ALLOWED': "That payment method isn't offered for City to City.",
  'C2C_TOO_MANY': 'You have 3 City to City trips under way. Finish or cancel one first.',
  'C2C_OFFER_GONE': 'This offer is no longer available.',
  'C2C_NOT_OPEN': 'This trip already has a driver, or it was cancelled.',
  'C2C_EXPIRED': 'This request has expired. Plan the trip again.',
  'C2C_DRIVER_BUSY': 'This driver has just been booked for another trip at that time.',
  'C2C_ON_TRIP': 'The trip has started. Talk to your driver, or contact support.',
  'C2C_RATED': 'You have already rated this trip.',
};

/// One end of a trip as the rider picked it.
class C2cEnd {
  const C2cEnd({required this.name, this.address, required this.lat, required this.lng, this.place = const Geo()});

  final String name;
  final String? address;
  final double lat, lng;

  /// Its country, state, city and suburb (the geocoder's).
  final Geo place;

  Map<String, dynamic> get placeJson => {
    'country': ?place.country,
    'state': ?place.state,
    'city': ?place.city,
    'suburb': ?place.suburb,
  };

  /// "12 Jalan Ampang, Kuala Lumpur".
  String get line => c2cAddressLine(name, place);
}

/// The c2c_bookings row the rider app inserts (0307 checks it and sets the
/// rest).
Map<String, dynamic> c2cBookingRow({
  required C2cEnd pickup,
  required C2cEnd drop,
  required double distanceKm,
  required double durationMin,
  required DateTime leaveAt,
  required bool flexible,
  required int passengers,
  required C2cLuggage luggage,
  required double fare,
  required C2cPayment payment,
  String? timezone,
}) => {
  'pickup_name': pickup.name,
  'pickup_address': ?pickup.address,
  'pickup_lat': pickup.lat,
  'pickup_lng': pickup.lng,
  'pickup_place': pickup.placeJson,
  'drop_name': drop.name,
  'drop_address': ?drop.address,
  'drop_lat': drop.lat,
  'drop_lng': drop.lng,
  'drop_place': drop.placeJson,
  'distance_km': double.parse(distanceKm.toStringAsFixed(2)),
  'duration_min': double.parse(durationMin.toStringAsFixed(1)),
  'leave_at': leaveAt.toUtc().toIso8601String(),
  'flexible': flexible,
  'passengers': passengers.clamp(1, c2cMaxPassengers),
  'luggage': luggage.key,
  'fare': c2cRound2(fare),
  'payment': payment.key,
  'timezone': ?timezone,
};
