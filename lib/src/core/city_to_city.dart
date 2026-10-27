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
import 'dart:math' as math;

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
