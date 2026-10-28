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
//
// Money and reminders (migration 0309): the give-up and in-app payment
// rules by region ([c2cRegionRuleFor]), the give-up fee and its split
// ([c2cGiveUpFee]), how a fare is paid from the wallet and coins
// ([c2cPaySplit]), the pay sheet's lines, and the reminder schedule
// ([c2cReminderSchedule]); twins of c2c_giveup_rule_for, c2c_giveup_fee,
// c2c_pay_split and c2c_send_reminders (supabase/tests/city_to_city_money_0309.sql).
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

  /// 'whole_car', or 'per_seat': a route's own seat price for trips drivers
  /// post (0310; a fixed fare is the seat price, a set range the seat range).
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
    String? tripKind,
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
    tripKind: tripKind ?? this.tripKind,
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
    'trip_kind': tripKind,
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
    this.owedFromTopup = true,
    this.owedNextInApp = true,
    this.owedCashCollect = false,
    this.owedBlock = false,
    this.remindersOn = true,
    this.reminderPush = true,
    this.reminderInbox = true,
    this.reminderSms = false,
    this.reminders = c2cDefaultReminders,
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
      owedFromTopup: r['owed_from_topup'] != false,
      owedNextInApp: r['owed_next_in_app'] != false,
      owedCashCollect: r['owed_cash_collect'] == true,
      owedBlock: r['owed_block'] == true,
      remindersOn: r['reminders_on'] != false,
      reminderPush: r['reminder_push'] != false,
      reminderInbox: r['reminder_inbox'] != false,
      reminderSms: r['reminder_sms'] == true,
      reminders: r.containsKey('reminders') ? c2cRemindersFrom(r['reminders']) : c2cDefaultReminders,
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

  /// Cancel fees a rider owes (0309): taken from the next top-up, added to
  /// the next in-app payment, collected by the next cash trip's driver, and
  /// no new booking until paid. Any combination.
  final bool owedFromTopup, owedNextInApp, owedCashCollect, owedBlock;

  /// Trip reminders (0309): on/off, the channels and the list.
  final bool remindersOn, reminderPush, reminderInbox, reminderSms;
  final List<C2cReminder> reminders;

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
    bool? owedFromTopup,
    bool? owedNextInApp,
    bool? owedCashCollect,
    bool? owedBlock,
    bool? remindersOn,
    bool? reminderPush,
    bool? reminderInbox,
    bool? reminderSms,
    List<C2cReminder>? reminders,
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
    owedFromTopup: owedFromTopup ?? this.owedFromTopup,
    owedNextInApp: owedNextInApp ?? this.owedNextInApp,
    owedCashCollect: owedCashCollect ?? this.owedCashCollect,
    owedBlock: owedBlock ?? this.owedBlock,
    remindersOn: remindersOn ?? this.remindersOn,
    reminderPush: reminderPush ?? this.reminderPush,
    reminderInbox: reminderInbox ?? this.reminderInbox,
    reminderSms: reminderSms ?? this.reminderSms,
    reminders: reminders ?? this.reminders,
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
    'owed_from_topup': owedFromTopup,
    'owed_next_in_app': owedNextInApp,
    'owed_cash_collect': owedCashCollect,
    'owed_block': owedBlock,
    'reminders_on': remindersOn,
    'reminder_push': reminderPush,
    'reminder_inbox': reminderInbox,
    'reminder_sms': reminderSms,
    'reminders': [for (final r in reminders) r.toJson()],
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
    final rem = c2cRemindersProblem(reminders);
    if (rem != null) return rem;
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
///
/// [tripKind] 'per_seat' picks among the per-seat route rules instead (0310:
/// a route's own seat price).
({C2cRule rule, int from, int to})? c2cRuleFor(List<C2cRule> rules, Geo pickup, Geo drop,
    {String tripKind = 'whole_car'}) {
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
    if (!r.active || r.tripKind != tripKind) continue;
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
  // A seat request waiting for the driver (0310).
  requested('requested', 'Waiting for the driver'),
  booked('booked', 'Booked'),
  driverArriving('driver_arriving', 'Driver on the way'),
  onTrip('on_trip', 'On the trip'),
  completed('completed', 'Completed'),
  cancelled('cancelled', 'Cancelled'),
  expired('expired', 'Expired'),
  // A seat request the driver declined (0310).
  declined('declined', 'Declined');

  const C2cStatus(this.key, this.label);
  final String key;
  final String label;
  static C2cStatus of(Object? v) => values.firstWhere((s) => s.key == v, orElse: () => open);

  /// No driver yet: drivers offer, the rider picks.
  bool get waiting => this == open || this == offered;

  /// A driver is booked and the trip has not ended.
  bool get withDriver => this == booked || this == driverArriving || this == onTrip;

  /// Over: completed, cancelled, expired or declined.
  bool get ended => this == completed || this == cancelled || this == expired || this == declined;
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
  cash('cash', 'Cash'),
  // Family (0317): the member's own trip on the family host's GET.wallet;
  // an in-app way to pay, offered where In app is.
  family('family', 'Family');

  const C2cPayment(this.key, this.label);
  final String key;
  final String label;
  static C2cPayment of(Object? v) => switch (v) { 'in_app' => inApp, 'family' => family, _ => cash };
}

/// The payment methods the settings allow, In app first.
List<C2cPayment> c2cPayments(C2cSettings s) => [if (s.payInApp) C2cPayment.inApp, if (s.payCash) C2cPayment.cash];

/// As [c2cPayments], with Family first when the family pays for the rider here.
List<C2cPayment> c2cPaymentsWithFamily(C2cSettings s, {required bool family}) =>
    [if (family && s.payInApp) C2cPayment.family, ...c2cPayments(s)];

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
    this.pickupLat,
    this.pickupLng,
    this.dropLat,
    this.dropLng,
    this.note,
    this.riderId,
    this.commissionRate,
    this.commissionAmount,
    this.driverDroppedAt,
    this.completedAt,
    this.payMode,
    this.payStatus,
    this.paidMethod,
    this.paidAmount,
    this.collectAmount,
    this.collectedAt,
    this.cancelFeePaidVia,
    this.tripId,
    this.item,
    this.seatPrice,
    this.pickupKind,
    this.doorKm,
    this.doorExtra,
    this.passengerNames = const [],
    this.cancelReason,
  });

  factory C2cBooking.fromRow(Map<String, dynamic> r) {
    Geo geo(Object? v) {
      final m = v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
      return Geo(country: _nz(m['country']), state: _nz(m['state']), city: _nz(m['city']), suburb: _nz(m['suburb']));
    }

    DateTime? at(Object? v) => DateTime.tryParse('${v ?? ''}')?.toLocal();
    final currency = (_nz(r['currency']) ?? 'MYR').toUpperCase();
    final perSeat = r['trip_kind'] == 'per_seat';
    final q = !perSeat && r['quote'] is Map ? Map<String, dynamic>.from(r['quote'] as Map) : null;
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
      pickupLat: _numOrNull(r['pickup_lat']),
      pickupLng: _numOrNull(r['pickup_lng']),
      dropLat: _numOrNull(r['drop_lat']),
      dropLng: _numOrNull(r['drop_lng']),
      note: _nz(r['note']),
      riderId: _nz(r['rider_id']),
      commissionRate: _numOrNull(r['commission_rate']),
      commissionAmount: _numOrNull(r['commission_amount']),
      driverDroppedAt: at(r['driver_dropped_at']),
      completedAt: at(r['completed_at']),
      payMode: _nz(r['pay_mode']),
      payStatus: _nz(r['pay_status']),
      paidMethod: _nz(r['paid_method']),
      paidAmount: _numOrNull(r['paid_amount']),
      collectAmount: _numOrNull(r['collect_amount']),
      collectedAt: at(r['collected_at']),
      cancelFeePaidVia: _nz(r['cancel_fee_paid_via']),
      tripId: perSeat ? _nz(r['trip_id']) : null,
      item: _nz(r['item']),
      seatPrice: _numOrNull(r['seat_price']),
      pickupKind: _nz(r['pickup_kind']),
      doorKm: _numOrNull(r['door_km']),
      doorExtra: _numOrNull(r['door_extra']),
      passengerNames: [
        if (r['passenger_names'] is List)
          for (final e in r['passenger_names'] as List)
            if (e is Map && _nz(e['name']) != null) _nz(e['name'])!,
      ],
      cancelReason: _nz(r['cancel_reason']),
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

  /// The points; null on a request the driver may not take (0308 leaves
  /// them out).
  final double? pickupLat, pickupLng, dropLat, dropLng;

  /// The rider's note for the driver.
  final String? note;
  final String? riderId;

  /// The commission locked as it was booked (0307), and charged at completion.
  final double? commissionRate, commissionAmount;

  /// When the booked driver last gave the trip up (0308): it went back to open.
  final DateTime? driverDroppedAt;
  final DateTime? completedAt;

  /// In-app payment (0309): 'hold' or 'after', kept at accept; held, paid,
  /// refunded, unpaid (pay after the trip) or cash (switched).
  final String? payMode, payStatus;

  /// get_wallet | get_coin | mix, and the fare paid or held.
  final String? paidMethod;
  final double? paidAmount;

  /// Cancel fees the rider owes that this cash trip's driver collects
  /// (0309), and when the driver marked them collected.
  final double? collectAmount;
  final DateTime? collectedAt;

  /// How an owed cancel fee was paid: topup, in_app, cash, pay_now.
  final String? cancelFeePaidVia;

  /// A seat or parcel on a trip a driver posted (0310): its trip, 'seat' or
  /// 'parcel', the seat price, 'meeting' or 'door', door pickup's km and
  /// extra, and who rides.
  final String? tripId, item;
  final double? seatPrice;
  final String? pickupKind;
  final double? doorKm, doorExtra;
  final List<String> passengerNames;
  final String? cancelReason;

  bool get perSeat => tripId != null;

  /// The rider still pays this completed trip in the app.
  bool get unpaid => payStatus == 'unpaid';

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
  'C2C_OWN_TRIP': "You can't offer on your own trip.",
  'C2C_NOT_FOR_YOU': 'This trip starts outside your service area.',
  'C2C_DRIVER_NOT_ELIGIBLE': "You can't take this route yet.",
  'C2C_LEAVE_OUT_OF_WINDOW': "That time is outside the rider's window.",
  'C2C_BAD_STEP': "This trip can't move to that step now.",
  'C2C_TOO_LATE': 'It is past the time to leave. Contact support to cancel this trip.',
  'C2C_DRIVING_SINCE_SET': 'Your driving start date is already on file. Ask support to change it.',
  'C2C_BAD_DATE': 'Enter the date your driving licence was first issued.',
  'C2C_WALLET_SHORT': "Your GET wallet doesn't hold enough. Top up, or switch this trip to cash.",
  'C2C_AMOUNT_CHANGED': 'The amount changed. Check it and try again.',
  'C2C_PAY_WAY': "That way to pay isn't offered here. Pick another.",
  'C2C_FEES_OWED': 'Pay the cancel fee you owe first. Open Wallet to pay it.',
  'C2C_NOTHING_TO_PAY': 'There is nothing to pay in the app for this trip.',
  'C2C_NOT_DONE': 'Pay once the trip is complete.',
  'C2C_DEFAULT_RULE': "The default rule can't be removed.",
  'C2C_SEATS_OFF': "Per-seat trips aren't offered here yet.",
  'C2C_NOT_A_DRIVER': 'Only approved drivers can post a trip.',
  'C2C_BOOKING_CLOSED': 'Booking for this trip has closed.',
  'C2C_NO_SEATS': 'Not enough seats are left on this trip.',
  'C2C_TOO_MANY_SEATS': 'That is more seats than one booking can take.',
  'C2C_WOMEN_ONLY': 'This trip is for women only.',
  'C2C_DOOR_OFF': 'This trip has no door pickup. Pick a meeting point.',
  'C2C_DOOR_TOO_FAR': 'Your address is too far off the route. Pick a meeting point.',
  'C2C_NO_PARCELS': "This trip can't take that parcel.",
  'C2C_NO_REPEAT': "That repeat isn't offered here.",
  'C2C_NAMES': 'Name each passenger, one a seat.',
  'C2C_ALREADY_BOOKED': 'You already have seats on this trip.',
  'C2C_SEAT_TRIP': 'Cancel the posted trip, or decline the request.',
  'DRIVER_BLOCKED': 'You blocked this driver. Unblock them in Settings › Blocked drivers to book them.',
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

// ---- The driver (migration 0308) -------------------------------------------------------------------

/// The driver's City to City page, under Drive.
const c2cDriverRoute = '/drive/city-to-city';

/// Whether a driver may take a trip, as the server says (0307's
/// c2c_driver_eligibility): the years of driving and the permits missing.
class C2cEligibility {
  const C2cEligibility({this.ok = true, this.minYears, this.years, this.experienceOk = true, this.needs = const []});

  factory C2cEligibility.fromJson(Object? v) {
    final m = v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
    return C2cEligibility(
      ok: m['ok'] == true,
      minYears: _numOrNull(m['minYears'])?.round(),
      years: _numOrNull(m['years'])?.round(),
      experienceOk: m['experienceOk'] != false,
      needs: [
        for (final n in m['needs'] is List ? m['needs'] as List : const [])
          if (n is Map && _nz(n['name']) != null) _nz(n['name'])!,
      ],
    );
  }

  final bool ok;
  final int? minYears, years;
  final bool experienceOk;

  /// The permits missing, by name.
  final List<String> needs;
}

/// What a request the driver may not take says on its card: "Needs:
/// Singapore permit", "Needs: 5 years of driving"; null when they may.
String? c2cLockLine(C2cEligibility e) {
  if (e.ok) return null;
  final parts = [
    ...e.needs,
    if (!e.experienceOk && e.minYears != null) '${e.minYears} ${e.minYears == 1 ? 'year' : 'years'} of driving',
  ];
  return parts.isEmpty ? "You can't take this route yet" : 'Needs: ${parts.join(', ')}';
}

/// The years of driving under a lock: "You have 2 years of driving.", or
/// "Add when your licence was first issued." when the server knows no date.
String? c2cYearsLine(C2cEligibility e) {
  if (e.experienceOk) return null;
  final y = e.years;
  if (y == null) return 'Add when your licence was first issued.';
  return 'You have $y ${y == 1 ? 'year' : 'years'} of driving.';
}

/// The driver's own open offer on a request.
class C2cMyOffer {
  const C2cMyOffer({required this.id, required this.price, required this.leaveAt});
  final String id;
  final double price;
  final DateTime leaveAt;
}

/// A request in the driver's list (c2c_driver_requests, 0308).
class C2cRequest {
  const C2cRequest({
    required this.booking,
    this.riderName = 'Rider',
    this.riderRating,
    this.eligibility = const C2cEligibility(),
    this.commissionRate,
    this.myOffer,
  });

  factory C2cRequest.fromJson(Map<String, dynamic> j) {
    final mine = j['my_offer'] is Map ? Map<String, dynamic>.from(j['my_offer'] as Map) : null;
    return C2cRequest(
      booking: C2cBooking.fromRow(j),
      riderName: _nz(j['rider_name']) ?? 'Rider',
      riderRating: _numOrNull(j['rider_rating']),
      eligibility: C2cEligibility.fromJson(j['eligibility']),
      commissionRate: _numOrNull(j['commission_rate_now']),
      myOffer: mine == null
          ? null
          : C2cMyOffer(
              id: '${mine['id']}',
              price: _num(mine['price']),
              leaveAt: DateTime.tryParse('${mine['leave_at'] ?? ''}')?.toLocal() ?? DateTime.now(),
            ),
    );
  }

  final C2cBooking booking;

  /// "Farah T.": the server never sends more.
  final String riderName;
  final double? riderRating;
  final C2cEligibility eligibility;

  /// What the driver would pay on it now (a fraction); null on a locked one.
  final double? commissionRate;
  final C2cMyOffer? myOffer;

  String get id => booking.id;
  bool get locked => !eligibility.ok;
}

/// The driver's list and what the page's header needs (0308).
class C2cDriverFeed {
  const C2cDriverFeed({
    this.approved = false,
    this.hasArea = false,
    this.years,
    this.canSetDrivingSince = false,
    this.requests = const [],
  });

  factory C2cDriverFeed.fromJson(Object? v) {
    final m = v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
    return C2cDriverFeed(
      approved: m['approved'] == true,
      hasArea: m['hasArea'] == true,
      years: _numOrNull(m['years'])?.round(),
      canSetDrivingSince: m['canSetDrivingSince'] == true,
      requests: [
        for (final r in m['requests'] is List ? m['requests'] as List : const [])
          if (r is Map) C2cRequest.fromJson(Map<String, dynamic>.from(r)),
      ],
    );
  }

  static const empty = C2cDriverFeed();

  final bool approved, hasArea;
  final int? years;

  /// The server knows no driving start date: the driver may give it once.
  final bool canSetDrivingSince;
  final List<C2cRequest> requests;
}

/// Why the driver gets no requests at all, or null.
String? c2cDriverBlock(C2cDriverFeed f) {
  if (!f.approved) return 'City to City opens once your partner account is approved.';
  if (!f.hasArea) return "Your service area isn't set. Ask support to add the states you drive in.";
  return null;
}

/// "1 person", "2 people".
String c2cPeople(int n) => n == 1 ? '1 person' : '$n people';

/// "Farah T. 4.8", or "Farah T., new rider".
String c2cRiderLine(String name, double? rating) =>
    rating == null || rating <= 0 ? '$name, new rider' : '$name ${rating.toStringAsFixed(1)}';

/// A request's time and size: "Fri 30 Oct, 9:00 (± 30 min), 2 people".
String c2cRequestWhen(C2cBooking b) =>
    '${c2cDayTime(b.leaveAt)}${b.flexible ? ' (± 30 min)' : ''}, ${c2cPeople(b.passengers)}';

/// A booked trip's time and size: "Thu 29 Oct, 18:00, whole car, 1 person".
String c2cBookedWhen(C2cBooking b) => '${c2cDayTime(b.leaves)}, whole car, ${c2cPeople(b.passengers)}';

/// "Ampang, Kuala Lumpur": the suburb and the city of [place], else [name].
String c2cAreaLine(Geo place, String name) {
  final parts = [?place.suburb, ?(place.city ?? place.state)];
  return parts.isEmpty ? name : parts.join(', ');
}

/// The page's header: "Commission 12%", or "Commission 10% to 12%" when
/// the requests differ; null when none is known.
String? c2cCommissionHeader(Iterable<double?> rates) {
  final known = [for (final r in rates) ?r]..sort();
  if (known.isEmpty) return null;
  final lo = _pct(c2cRound2(known.first * 100)), hi = _pct(c2cRound2(known.last * 100));
  return lo == hi ? 'Commission $lo%' : 'Commission $lo% to $hi%';
}

/// "RM 90, you keep RM 79.20 after 12%": the price less [rate]; the price
/// alone when the rate is not known.
String c2cKeepLine(double price, double? rate, [String currency = 'MYR']) {
  if (rate == null || rate <= 0) return c2cMoney(price, currency);
  return '${c2cMoney(price, currency)}, you keep ${c2cMoney(c2cRound2(price * (1 - rate)), currency)} '
      'after ${_pct(c2cRound2(rate * 100))}%';
}

/// The price an offer starts at: the fixed fare, else RM 10 over the
/// rider's fare, within the range.
double c2cOfferStart(C2cBooking b) {
  final q = b.quote;
  if (q == null) return b.fare;
  if (q.fareMode == C2cFareMode.fixed) return c2cRound2(q.suggested);
  return c2cClampFare(b.fare + 10, q);
}

/// Why [price] can't be offered on [b], as the server says it (0307,
/// C2C_FARE_OUT_OF_RANGE), or null.
String? c2cOfferPriceProblem(double price, C2cBooking b) {
  final q = b.quote;
  if (q == null) return null;
  if (q.fareMode == C2cFareMode.fixed) {
    return c2cRound2(price) == c2cRound2(q.suggested)
        ? null
        : 'This route has a fixed fare of ${c2cMoney(q.suggested, b.currency)}.';
  }
  final lo = q.low, hi = q.high;
  if (lo != null && hi != null && (price < lo || price > hi)) {
    return 'Offer between ${c2cMoney(lo, b.currency)} and ${c2cMoney(hi, b.currency)}.';
  }
  return null;
}

/// The times a driver may offer to leave: every 15 minutes within ± 30 of
/// the rider's time when they are flexible, else the rider's time.
List<DateTime> c2cLeaveChoices(DateTime leaveAt, bool flexible) => flexible
    ? [for (var m = -30; m <= 30; m += 15) leaveAt.add(Duration(minutes: m))]
    : [leaveAt];

/// "Offer of RM 150 sent. Waiting for the rider."
String c2cOfferSentLine(double price, [String currency = 'MYR']) =>
    'Offer of ${c2cMoney(price, currency)} sent. Waiting for the rider.';

/// The driver's next step on a booked trip and its button, or null.
({C2cStatus to, String label})? c2cNextStep(C2cStatus s) => switch (s) {
  C2cStatus.booked => (to: C2cStatus.driverArriving, label: 'On my way'),
  C2cStatus.driverArriving => (to: C2cStatus.onTrip, label: 'Rider picked up'),
  C2cStatus.onTrip => (to: C2cStatus.completed, label: 'Complete trip'),
  _ => null,
};

/// Whether the booked driver may give the trip up at [now] (0308): booked
/// or on the way, before the time to leave.
bool c2cDriverCanCancel(C2cBooking b, DateTime now) =>
    (b.status == C2cStatus.booked || b.status == C2cStatus.driverArriving) && now.isBefore(b.leaveAt);

/// A trip's tag in My trips.
String c2cDriverTag(C2cStatus s) => switch (s) {
  C2cStatus.open || C2cStatus.offered => 'Offered',
  C2cStatus.requested => 'Request',
  C2cStatus.booked => 'Booked',
  C2cStatus.driverArriving => 'On the way',
  C2cStatus.onTrip => 'On the trip',
  C2cStatus.completed => 'Done',
  C2cStatus.cancelled => 'Cancelled',
  C2cStatus.expired => 'Expired',
  C2cStatus.declined => 'Declined',
};

/// The driver's booked trips at [now]: today (under way, or leaving today
/// or earlier), later, and done (the last ten, newest first).
({List<C2cBooking> today, List<C2cBooking> later, List<C2cBooking> done}) c2cDriverTrips(
  List<C2cBooking> mine,
  DateTime now,
) {
  final endOfDay = DateTime(now.year, now.month, now.day + 1);
  final today = <C2cBooking>[], later = <C2cBooking>[], done = <C2cBooking>[];
  for (final b in mine) {
    // Seats on trips the driver posted are listed with those trips (0310).
    if (b.perSeat) continue;
    if (b.status.ended) {
      done.add(b);
    } else if (!b.status.withDriver) {
      continue;
    } else if (b.status != C2cStatus.booked || b.leaves.isBefore(endOfDay)) {
      today.add(b);
    } else {
      later.add(b);
    }
  }
  int soonest(C2cBooking a, C2cBooking b) => a.leaves.compareTo(b.leaves);
  today.sort(soonest);
  later.sort(soonest);
  done.sort((a, b) => b.leaves.compareTo(a.leaves));
  return (today: today, later: later, done: done.take(10).toList());
}

/// The trips tab: "My trips (3)", counting today's, later and offered.
String c2cTripsTabLabel(int n) => n == 0 ? 'My trips' : 'My trips ($n)';

/// What the rider's page says once their driver gave the trip up (0308).
const c2cDriverDroppedLine = 'Your request is open to drivers again, and no fee applies.';

// ---- Money and reminders (migration 0309) ---------------------------------------------------------

/// A rule kept per region: the default (no place) or one place.
abstract class C2cRegionRule {
  String? get id;

  /// Null: the default, for every pickup without a region rule.
  C2cPlace? get place;
  bool get active;
  DateTime? get createdAt;

  bool get isDefault => place == null;

  /// "Default", "Sabah".
  String get name => place?.name ?? 'Default';

  /// "Everywhere without its own rule", "State, Malaysia".
  String get scope {
    final p = place;
    if (p == null) return 'Everywhere without its own rule';
    final level = '${p.level[0].toUpperCase()}${p.level.substring(1)}';
    return p.within.isEmpty ? level : '$level, ${p.within}';
  }
}

C2cPlace? _placeOf(Object? v) => v is Map ? C2cPlace.fromJson(Map<String, dynamic>.from(v)) : null;

/// The rule for a pickup at [pickup] among [rules]: the most specific active
/// region rule that holds it (suburb, city, state, country), else the
/// default; null when there is none at all. As c2c_giveup_rule_for and
/// c2c_pay_rule_for: ties go to the older rule, then the lower id.
T? c2cRegionRuleFor<T extends C2cRegionRule>(List<T> rules, Geo pickup) {
  T? best;
  var bestRank = -1;
  for (final r in rules) {
    final p = r.place;
    final rank = p == null ? 0 : (r.active ? p.holds(pickup) : 0);
    if (p != null && rank == 0) continue;
    final better = best == null ||
        rank > bestRank ||
        (rank == bestRank &&
            ((r.createdAt ?? DateTime(0)).compareTo(best.createdAt ?? DateTime(0)) < 0 ||
                ((r.createdAt ?? DateTime(0)) == (best.createdAt ?? DateTime(0)) &&
                    (r.id ?? '').compareTo(best.id ?? '') < 0)));
    if (better) {
      best = r;
      bestRank = rank;
    }
  }
  return best;
}

/// When a driver pays for giving a trip up.
enum C2cGiveUpWhen {
  within('within', 'Only inside X hours'),
  always('always', 'Always');

  const C2cGiveUpWhen(this.key, this.label);
  final String key;
  final String label;
  static C2cGiveUpWhen of(Object? v) => v == 'always' ? always : within;
}

/// Where a give-up fee goes.
enum C2cFeeDest {
  rider('rider', 'Rider'),
  platform('platform', 'get.ride'),
  split('split', 'Split');

  const C2cFeeDest(this.key, this.label);
  final String key;
  final String label;
  static C2cFeeDest of(Object? v) => values.firstWhere((d) => d.key == v, orElse: () => rider);
}

/// If the driver's GET wallet is short.
enum C2cShortMode {
  negative('negative', 'Allow negative'),
  owed('owed', 'Record as owed');

  const C2cShortMode(this.key, this.label);
  final String key;
  final String label;
  static C2cShortMode of(Object? v) => v == 'owed' ? owed : negative;

  /// What the admin page says under the choice.
  String get note => this == negative
      ? 'The fee is taken in full: what the GET wallet lacks comes off GET.credit, which may go below zero '
            'as commission does. The rider is paid their share now.'
      : 'What is in the wallet is taken; the rest shows as owed on the driver and comes from their next earnings. '
            'The rider is paid as it comes in.';
}

/// What a driver pays to give a booked trip up (c2c_giveup_rules).
class C2cGiveUpRule extends C2cRegionRule {
  C2cGiveUpRule({
    this.id,
    this.place,
    this.charge = false,
    this.amount = 30,
    this.when = C2cGiveUpWhen.within,
    this.freeHours = 24,
    this.dest = C2cFeeDest.rider,
    this.splitFixed = false,
    this.splitPercent = 70,
    this.splitAmount = 20,
    this.shortMode = C2cShortMode.negative,
    this.active = true,
    this.createdAt,
  });

  factory C2cGiveUpRule.fromRow(Map<String, dynamic> r) => C2cGiveUpRule(
    id: _nz(r['id']),
    place: _placeOf(r['place']),
    charge: r['charge'] == true,
    amount: _num(r['amount'], 30),
    when: C2cGiveUpWhen.of(r['when_mode']),
    freeHours: _num(r['free_hours'], 24).round(),
    dest: C2cFeeDest.of(r['dest']),
    splitFixed: r['split_mode'] == 'fixed',
    splitPercent: _num(r['split_percent'], 70),
    splitAmount: _num(r['split_fixed'], 20),
    shortMode: C2cShortMode.of(r['short_mode']),
    active: r['active'] != false,
    createdAt: DateTime.tryParse('${r['created_at'] ?? ''}'),
  );

  @override
  final String? id;
  @override
  final C2cPlace? place;
  final bool charge;
  final double amount;
  final C2cGiveUpWhen when;
  final int freeHours;
  final C2cFeeDest dest;

  /// The rider's share of a split: a fixed RM ([splitAmount]) or a percent.
  final bool splitFixed;
  final double splitPercent, splitAmount;
  final C2cShortMode shortMode;
  @override
  final bool active;
  @override
  final DateTime? createdAt;

  C2cGiveUpRule copyWith({
    C2cPlace? place,
    bool? charge,
    double? amount,
    C2cGiveUpWhen? when,
    int? freeHours,
    C2cFeeDest? dest,
    bool? splitFixed,
    double? splitPercent,
    double? splitAmount,
    C2cShortMode? shortMode,
    bool? active,
  }) => C2cGiveUpRule(
    id: id,
    place: place ?? this.place,
    charge: charge ?? this.charge,
    amount: amount ?? this.amount,
    when: when ?? this.when,
    freeHours: freeHours ?? this.freeHours,
    dest: dest ?? this.dest,
    splitFixed: splitFixed ?? this.splitFixed,
    splitPercent: splitPercent ?? this.splitPercent,
    splitAmount: splitAmount ?? this.splitAmount,
    shortMode: shortMode ?? this.shortMode,
    active: active ?? this.active,
    createdAt: createdAt,
  );

  /// The row as stored (without the server's stamps).
  Map<String, dynamic> toRow() => {
    if (id != null) 'id': id,
    'place': place?.toJson(),
    'charge': charge,
    'amount': amount,
    'when_mode': when.key,
    'free_hours': freeHours,
    'dest': dest.key,
    'split_mode': splitFixed ? 'fixed' : 'percent',
    'split_percent': splitPercent,
    'split_fixed': splitAmount,
    'short_mode': shortMode.key,
    'active': active,
  };

  /// Why it can't be saved, or null.
  String? get problem {
    final why = place?.problem;
    if (why != null) return why;
    if (charge && amount <= 0) return 'Set the fee, or turn the charge off.';
    if (splitPercent < 0 || splitPercent > 100) return "The rider's share is 0 to 100%.";
    if (splitAmount < 0) return "The rider's share can't be below 0.";
    return null;
  }
}

/// The fee under [r] to give up at [at] a trip leaving at [leaveAt], and
/// how it splits (c2c_giveup_fee's twin).
({double fee, double toRider, double toPlatform}) c2cGiveUpFee(C2cGiveUpRule? r, DateTime leaveAt, DateTime at) {
  if (r == null || !r.charge || r.amount <= 0) return (fee: 0, toRider: 0, toPlatform: 0);
  if (r.when == C2cGiveUpWhen.within && at.isBefore(leaveAt.subtract(Duration(hours: r.freeHours)))) {
    return (fee: 0, toRider: 0, toPlatform: 0);
  }
  final fee = c2cRound2(r.amount);
  final rider = switch (r.dest) {
    C2cFeeDest.rider => fee,
    C2cFeeDest.platform => 0.0,
    C2cFeeDest.split => r.splitFixed ? math.min(c2cRound2(r.splitAmount), fee) : c2cRound2(fee * r.splitPercent / 100),
  };
  return (fee: fee, toRider: rider, toPlatform: c2cRound2(fee - rider));
}

/// What the driver sees before Give up trip: "Giving up this trip is
/// free.", "Giving up this trip costs RM 30.", "Free until 24 hours before
/// leaving, then RM 30."
String c2cGiveUpLine(C2cGiveUpRule? r, [String currency = 'MYR']) {
  if (r == null || !r.charge || r.amount <= 0) return 'Giving up this trip is free.';
  final fee = c2cMoney(r.amount, currency);
  if (r.when == C2cGiveUpWhen.always) return 'Giving up this trip costs $fee.';
  return 'Free until ${r.freeHours} ${r.freeHours == 1 ? 'hour' : 'hours'} before leaving, then $fee.';
}

/// The rules list's line: "RM 30, inside 24 h, to rider, may go negative".
String c2cGiveUpSummary(C2cGiveUpRule r, [String currency = 'MYR']) {
  if (!r.charge) return 'No charge';
  final to = switch (r.dest) {
    C2cFeeDest.rider => 'rider',
    C2cFeeDest.platform => 'get.ride',
    C2cFeeDest.split => 'split',
  };
  return '${c2cMoney(r.amount, currency)}'
      '${r.when == C2cGiveUpWhen.always ? ', always' : ', inside ${r.freeHours} h'}, to $to'
      '${r.shortMode == C2cShortMode.negative ? ', may go negative' : ', rest owed'}';
}

/// The admin page's example: a driver giving up [hoursBefore] hours before
/// leaving with [wallet] in their GET wallet. Two lines.
(String, String) c2cGiveUpExample(C2cGiveUpRule r, {double hoursBefore = 3, double wallet = 12, String currency = 'MYR'}) {
  final leave = DateTime(2026, 1, 1, 12);
  final f = c2cGiveUpFee(r, leave, leave.subtract(Duration(minutes: (hoursBefore * 60).round())));
  const back = 'The trip goes back to open for other drivers.';
  if (!r.charge) return ('No charge.', back);
  if (f.fee == 0) return ('No charge: more than ${r.freeHours} h before leaving.', back);
  String m(double v) => c2cMoney(c2cRound2(v), currency);
  final first = 'Driver charged ${m(f.fee)}: ${m(f.toRider)} to the rider, ${m(f.toPlatform)} to get.ride.';
  if (wallet >= f.fee) return (first, '${m(f.fee)} taken from the GET wallet.');
  final rest = f.fee - wallet;
  return (
    first,
    r.shortMode == C2cShortMode.negative
        ? '${m(wallet)} from the GET wallet, ${m(rest)} from GET.credit (below zero until paid back).'
        : '${m(wallet)} taken now, ${m(rest)} recorded as owed by the driver.',
  );
}

/// When the rider pays an In app trip.
enum C2cPayWhen {
  hold('hold', 'Hold at booking'),
  after('after', 'Pay after the trip');

  const C2cPayWhen(this.key, this.label);
  final String key;
  final String label;
  static C2cPayWhen of(Object? v) => v == 'after' ? after : hold;

  /// What the admin page says about it.
  String get note => this == hold
      ? 'The fare is taken from the rider when they accept an offer and held. It goes to the driver at Complete '
            'trip, less commission. If the trip is cancelled it goes back to the rider, less any cancel fee. The '
            'driver sees "Paid in app, held".'
      : 'As city rides: the rider pays after Complete trip. The driver sees "In app, paid after the trip".';
}

/// How a trip paid In app is charged (c2c_pay_rules).
class C2cPayRule extends C2cRegionRule {
  C2cPayRule({
    this.id,
    this.place,
    this.when = C2cPayWhen.hold,
    this.wallet = true,
    this.coin = true,
    this.mix = true,
    this.offerTopup = true,
    this.offerCash = true,
    this.active = true,
    this.createdAt,
  });

  factory C2cPayRule.fromRow(Map<String, dynamic> r) => C2cPayRule(
    id: _nz(r['id']),
    place: _placeOf(r['place']),
    when: C2cPayWhen.of(r['when_mode']),
    wallet: r['pay_wallet'] != false,
    coin: r['pay_coin'] != false,
    mix: r['pay_mix'] != false,
    offerTopup: r['offer_topup'] != false,
    offerCash: r['offer_cash'] != false,
    active: r['active'] != false,
    createdAt: DateTime.tryParse('${r['created_at'] ?? ''}'),
  );

  @override
  final String? id;
  @override
  final C2cPlace? place;
  final C2cPayWhen when;

  /// Ways to pay: GET.wallet, GET.coin, and coins first then the wallet.
  final bool wallet, coin, mix;

  /// When the wallet is short: offer Top up, offer Switch to cash.
  final bool offerTopup, offerCash;
  @override
  final bool active;
  @override
  final DateTime? createdAt;

  C2cPayRule copyWith({
    C2cPlace? place,
    C2cPayWhen? when,
    bool? wallet,
    bool? coin,
    bool? mix,
    bool? offerTopup,
    bool? offerCash,
    bool? active,
  }) {
    final w = wallet ?? this.wallet, c = coin ?? this.coin;
    return C2cPayRule(
      id: id,
      place: place ?? this.place,
      when: when ?? this.when,
      wallet: w,
      coin: c,
      // Mix needs both ways on.
      mix: (mix ?? this.mix) && w && c,
      offerTopup: offerTopup ?? this.offerTopup,
      offerCash: offerCash ?? this.offerCash,
      active: active ?? this.active,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toRow() => {
    if (id != null) 'id': id,
    'place': place?.toJson(),
    'when_mode': when.key,
    'pay_wallet': wallet,
    'pay_coin': coin,
    'pay_mix': mix && wallet && coin,
    'offer_topup': offerTopup,
    'offer_cash': offerCash,
    'active': active,
  };

  String? get problem {
    final why = place?.problem;
    if (why != null) return why;
    if (!wallet && !coin) return 'Keep at least one way on, or turn In app off in Payment methods.';
    return null;
  }
}

/// The rules list's line: "Held at booking; wallet, coin, mix".
String c2cPayRuleSummary(C2cPayRule r) {
  final ways = [if (r.wallet) 'wallet', if (r.coin) 'coin', if (r.mix) 'mix'];
  return '${r.when == C2cPayWhen.hold ? 'Held at booking' : 'Paid after the trip'}; '
      '${ways.isEmpty ? 'no way set' : ways.join(', ')}';
}

/// A way to pay in the app.
enum C2cPayWay {
  mix('mix', 'Coins first, then GET.wallet'),
  wallet('get_wallet', 'GET.wallet'),
  coin('get_coin', 'GET.coin');

  const C2cPayWay(this.key, this.label);
  final String key;
  final String label;
  static C2cPayWay? of(Object? v) => values.where((w) => w.key == v).firstOrNull;
}

/// How [total] is paid by [way] from a wallet of [wallet] and [coins] coins
/// at [rate] coins per unit: the wallet part, the coins' value, the coins
/// (rounded up) and how much is short (c2c_pay_split's twin).
({double walletPart, double coinValue, double coins, double short}) c2cPaySplit(
  double total,
  C2cPayWay way,
  double wallet,
  double coins,
  double? rate,
) {
  final t = c2cRound2(math.max(total, 0));
  final r = rate ?? 0;
  final w = math.max(wallet, 0);
  final max = r > 0 ? (math.max(coins, 0) / r * 100 + 1e-9).floor() / 100 : 0.0;
  double coinsFor(double v) => r > 0 ? (v * r * 100 - 1e-9).ceil() / 100 : 0;
  switch (way) {
    case C2cPayWay.coin:
      return (walletPart: 0, coinValue: t, coins: coinsFor(t), short: c2cRound2(math.max(t - max, 0)));
    case C2cPayWay.mix:
      final cv = math.min(max, t);
      return (
        walletPart: c2cRound2(t - cv),
        coinValue: cv,
        coins: coinsFor(cv),
        short: c2cRound2(math.max(t - cv - w, 0)),
      );
    case C2cPayWay.wallet:
      return (walletPart: t, coinValue: 0, coins: 0, short: c2cRound2(math.max(t - w, 0)));
  }
}

/// A cancel fee the rider owes (0307's 'due').
class C2cDue {
  const C2cDue({required this.id, required this.ref, required this.fee, this.cancelledAt, this.route, this.currency = 'MYR'});

  factory C2cDue.fromJson(Map<String, dynamic> j) => C2cDue(
    id: '${j['id']}',
    ref: _nz(j['ref']) ?? '',
    fee: _num(j['fee']),
    cancelledAt: DateTime.tryParse('${j['cancelledAt'] ?? ''}')?.toLocal(),
    route: _nz(j['route']),
    currency: (_nz(j['currency']) ?? 'MYR').toUpperCase(),
  );

  final String id, ref;
  final double fee;
  final DateTime? cancelledAt;
  final String? route;
  final String currency;
}

/// What the rider's pay sheet needs (c2c_pay_info).
class C2cPayInfo {
  const C2cPayInfo({
    this.when = C2cPayWhen.hold,
    this.wallet = true,
    this.coin = true,
    this.mix = true,
    this.offerTopup = true,
    this.offerCash = true,
    this.walletBalance = 0,
    this.coinBalance = 0,
    this.coinRate,
    this.dues = const [],
    this.payStatus,
  });

  factory C2cPayInfo.fromJson(Object? v) {
    final m = v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
    return C2cPayInfo(
      when: C2cPayWhen.of(m['when']),
      wallet: m['wallet'] != false,
      coin: m['coin'] != false,
      mix: m['mix'] != false,
      offerTopup: m['offerTopup'] != false,
      offerCash: m['offerCash'] != false,
      walletBalance: _num(m['walletBalance']),
      coinBalance: _num(m['coinBalance']),
      coinRate: _numOrNull(m['coinRate']),
      dues: [
        for (final d in m['dues'] is List ? m['dues'] as List : const [])
          if (d is Map) C2cDue.fromJson(Map<String, dynamic>.from(d)),
      ],
      payStatus: _nz(m['payStatus']),
    );
  }

  final C2cPayWhen when;
  final bool wallet, coin, mix, offerTopup, offerCash;
  final double walletBalance, coinBalance;

  /// Coins per unit of money; null or 0: coins can't pay.
  final double? coinRate;

  /// The cancel fees owed added to this payment.
  final List<C2cDue> dues;
  final String? payStatus;

  double get duesTotal => c2cRound2(dues.fold(0.0, (s, d) => s + d.fee));

  /// The ways offered, mix first.
  List<C2cPayWay> get ways => [
    if (mix && wallet && coin && (coinRate ?? 0) > 0) C2cPayWay.mix,
    if (wallet) C2cPayWay.wallet,
    if (coin && (coinRate ?? 0) > 0) C2cPayWay.coin,
  ];
}

/// A coin count as people read it: "500", "1,250.5".
String c2cCoins(double v) {
  final whole = v == v.roundToDouble();
  final s = whole ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
  final parts = s.split('.');
  final digits = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  return parts.length > 1 ? '$digits.${parts[1]}' : digits;
}

/// The line under a way: "500 coins (RM 5) + RM 135 from the wallet",
/// "Balance RM 100", "500 coins = RM 5: not enough".
String c2cPayWayNote(C2cPayWay way, C2cPayInfo info, double total, [String currency = 'MYR']) {
  final sp = c2cPaySplit(total, way, info.walletBalance, info.coinBalance, info.coinRate);
  final r = info.coinRate ?? 0;
  final have = r > 0 ? (info.coinBalance / r * 100).floor() / 100 : 0.0;
  return switch (way) {
    C2cPayWay.mix => sp.coins > 0
        ? '${c2cCoins(sp.coins)} coins (${c2cMoney(sp.coinValue, currency)}) + ${c2cMoney(sp.walletPart, currency)} from the wallet'
        : 'No coins: ${c2cMoney(sp.walletPart, currency)} from the wallet',
    C2cPayWay.wallet => 'Balance ${c2cMoney(info.walletBalance, currency)}',
    C2cPayWay.coin => sp.short > 0
        ? '${c2cCoins(info.coinBalance)} coins = ${c2cMoney(have, currency)}: not enough'
        : '${c2cCoins(sp.coins)} coins',
  };
}

/// The pay sheet's lines for [fare] (and the fees owed added) by [way]:
/// "Trip fare", "Cancel fee owed", "From coins", then "Short by", "You pay
/// now" or "Held from GET.wallet" (in coins: "Held in coins").
List<(String, String)> c2cPayLines(
  double fare,
  C2cPayWay way,
  C2cPayInfo info, {
  bool after = false,
  String currency = 'MYR',
}) {
  final total = c2cRound2(fare + info.duesTotal);
  final sp = c2cPaySplit(total, way, info.walletBalance, info.coinBalance, info.coinRate);
  final r = info.coinRate ?? 0;
  // What the coins cover: all they are worth when they fall short.
  final fromCoins = way == C2cPayWay.wallet
      ? 0.0
      : math.min(total, r > 0 ? (math.max(info.coinBalance, 0) / r * 100 + 1e-9).floor() / 100 : 0.0);
  return [
    ('Trip fare', c2cMoney(fare, currency)),
    if (info.duesTotal > 0) ('Cancel fee owed', c2cMoney(info.duesTotal, currency)),
    if (fromCoins > 0) ('From coins', '- ${c2cMoney(fromCoins, currency)}'),
    if (sp.short > 0)
      ('Short by', c2cMoney(sp.short, currency))
    else if (way == C2cPayWay.coin)
      (after ? 'Paid in coins' : 'Held in coins', c2cMoney(sp.coinValue, currency))
    else if (after)
      ('You pay now', c2cMoney(sp.walletPart, currency))
    else
      ('Held from GET.wallet', c2cMoney(sp.walletPart, currency)),
  ];
}

/// The pay sheet's main button: "Top up RM 35", "Pay RM 140", "Accept and
/// hold RM 140".
String c2cPayButton(double total, C2cPayWay way, C2cPayInfo info, {bool after = false, String currency = 'MYR'}) {
  final sp = c2cPaySplit(total, way, info.walletBalance, info.coinBalance, info.coinRate);
  if (sp.short > 0) return 'Top up ${c2cMoney(sp.short, currency)}';
  final pay = way == C2cPayWay.coin ? sp.coinValue : sp.walletPart;
  return after ? 'Pay ${c2cMoney(total, currency)}' : 'Accept and hold ${c2cMoney(pay, currency)}';
}

/// "Includes RM 20 cancel fee you owe from CC-20014 (Sat 18 Oct)."
String? c2cDuesLine(C2cPayInfo info, [String currency = 'MYR']) {
  if (info.dues.isEmpty) return null;
  final refs = info.dues.map((d) => d.cancelledAt == null ? d.ref : '${d.ref} (${DateFormat('EEE d MMM').format(d.cancelledAt!)})');
  return 'Includes ${c2cMoney(info.duesTotal, currency)} cancel ${info.dues.length == 1 ? 'fee' : 'fees'} you owe from '
      '${refs.join(', ')}.';
}

/// The admin page's example for [r]: a RM 140 trip, the rider with RM 100
/// and 500 coins (100 coins = RM 1). Two lines.
(String, String) c2cPayExample(C2cPayRule r) {
  final String first;
  if (r.mix && r.wallet && r.coin) {
    first = 'RM 5 in coins + RM 100 from the wallet: RM 35 short.';
  } else if (r.wallet) {
    first = 'RM 100 in the wallet: RM 40 short.';
  } else if (r.coin) {
    first = '500 coins = RM 5: RM 135 short.';
  } else {
    first = 'No in-app way on.';
  }
  final opts = [if (r.offerTopup) 'Top up', if (r.offerCash) 'Switch to cash'];
  return (
    first,
    opts.isEmpty
        ? "Rider can't accept until the wallet has enough."
        : 'Rider sees: ${opts.join(' or ')}'
              '${r.when == C2cPayWhen.hold ? ', before the booking is made.' : ', when they pay after the trip.'}',
  );
}

/// How the driver's trip says it is paid: "collect RM 140 in cash",
/// "Paid in app, held", "In app, paid after the trip", "Paid in app".
String c2cDriverPayLine(C2cBooking b) {
  if (b.payment == C2cPayment.cash) return 'collect ${c2cMoney(b.price, b.currency)} in cash';
  return switch (b.payStatus) {
    'held' => 'Paid in app, held',
    'paid' => 'Paid in app',
    'refunded' => 'Paid in app, given back',
    _ => b.payMode == 'after' ? 'In app, paid after the trip' : 'the rider pays in the app',
  };
}

/// The rider's Payment tile: "Cash", "In app, held", "In app, after the
/// trip", "In app, paid".
String c2cRiderPayLabel(C2cBooking b) {
  if (b.payment == C2cPayment.cash) return 'Cash';
  return switch (b.payStatus) {
    'held' => 'In app, held',
    'paid' => 'In app, paid',
    _ => b.payMode == 'after' ? 'In app, after the trip' : 'In app',
  };
}

/// What the cash trip's driver collects for the rider's owed cancel fees,
/// or null: "Also collect RM 20 the rider owes for a cancelled trip."
String? c2cCollectLine(C2cBooking b) {
  final v = b.collectAmount ?? 0;
  if (b.payment != C2cPayment.cash || v <= 0 || b.collectedAt != null) return null;
  return 'Also collect ${c2cMoney(v, b.currency)} the rider owes for a cancelled trip.';
}

// ---- Reminders ------------------------------------------------------------------------------------

/// A trip reminder: [minutes] before the time to leave, to the rider, the
/// driver or both.
class C2cReminder {
  const C2cReminder(this.minutes, [this.to = 'both']);

  factory C2cReminder.fromJson(Map<String, dynamic> j) =>
      C2cReminder(_num(j['minutes'], 60).round(), const {'rider', 'driver'}.contains(j['to']) ? j['to'] as String : 'both');

  final int minutes;

  /// rider | driver | both.
  final String to;

  bool get toRider => to != 'driver';
  bool get toDriver => to != 'rider';

  C2cReminder copyWith({int? minutes, String? to}) => C2cReminder(minutes ?? this.minutes, to ?? this.to);

  Map<String, dynamic> toJson() => {'minutes': minutes, 'to': to};

  @override
  bool operator ==(Object other) => other is C2cReminder && other.minutes == minutes && other.to == to;

  @override
  int get hashCode => Object.hash(minutes, to);
}

/// The reminders a new install starts with: 1 day and 2 h to both, 30 min
/// to the driver.
const c2cDefaultReminders = [C2cReminder(1440), C2cReminder(120), C2cReminder(30, 'driver')];

/// The times the admin page steps through.
const c2cReminderSteps = [10, 15, 30, 45, 60, 120, 180, 360, 720, 1440, 2880];

List<C2cReminder> c2cRemindersFrom(Object? raw) => [
  if (raw is List)
    for (final e in raw)
      if (e is Map) C2cReminder.fromJson(Map<String, dynamic>.from(e)),
];

/// Why [list] can't be saved, or null (the server's c2c_reminders_valid).
String? c2cRemindersProblem(List<C2cReminder> list) {
  if (list.length > 10) return 'Up to 10 reminders.';
  if (list.any((r) => r.minutes < 5 || r.minutes > 10080)) return 'A reminder is 5 minutes to 7 days before.';
  if (list.map((r) => r.minutes).toSet().length != list.length) return 'Each reminder needs its own time.';
  return null;
}

/// [minutes] moved one step along [c2cReminderSteps].
int c2cReminderStep(int minutes, int by) {
  final steps = c2cReminderSteps;
  if (by > 0) return steps.firstWhere((s) => s > minutes, orElse: () => minutes);
  return steps.lastWhere((s) => s < minutes, orElse: () => minutes);
}

/// "1 day", "2 days", "2 h", "1 h 30 min", "30 min" (c2c_reminder_when's twin).
String c2cReminderWhen(int minutes) {
  if (minutes >= 1440 && minutes % 1440 == 0) return '${minutes ~/ 1440} ${minutes == 1440 ? 'day' : 'days'}';
  if (minutes >= 60 && minutes % 60 == 0) return '${minutes ~/ 60} h';
  if (minutes > 60) return '${minutes ~/ 60} h ${minutes % 60} min';
  return '$minutes min';
}

/// When each reminder of [list] goes for a trip leaving at [leaves], booked
/// at [bookedAt]: a reminder whose time had passed at booking is skipped
/// (c2c_send_reminders). Soonest first.
List<({int minutes, DateTime at, String to, bool skipped})> c2cReminderSchedule(
  List<C2cReminder> list,
  DateTime leaves,
  DateTime bookedAt,
) {
  final out = [
    for (final r in list)
      (
        minutes: r.minutes,
        at: leaves.subtract(Duration(minutes: r.minutes)),
        to: r.to,
        skipped: leaves.subtract(Duration(minutes: r.minutes)).isBefore(bookedAt),
      ),
  ]..sort((a, b) => a.at.compareTo(b.at));
  return out;
}

/// The words of a reminder [minutes] before, as the server sends them:
/// the rider's and the driver's title and text.
({String riderTitle, String riderBody, String driverTitle, String driverBody}) c2cReminderTexts({
  required int minutes,
  required String dropCity,
  required String driverName,
  required String riderName,
  required DateTime leaves,
  required String pickup,
  String? car,
  required double fare,
  required String payLine,
  String currency = 'MYR',
}) {
  final when = c2cReminderWhen(minutes);
  final clock = c2cClock(leaves);
  return (
    riderTitle: 'Your trip to $dropCity is in $when',
    riderBody: '${c2cShortName(driverName)} picks you up at $clock from $pickup.${car == null ? '' : ' $car.'} '
        'Tap to see the trip or chat.',
    driverTitle: 'City to City trip in $when',
    driverBody: 'Pick up ${c2cShortName(riderName)} at $clock, $pickup, to $dropCity. '
        '${c2cMoney(fare, currency)}, $payLine. Tap to start On my way.',
  );
}

/// "Farah T." for "Farah Tan Contoh" (0308's c2c_short_name).
String c2cShortName(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return 'Rider';
  return words.length == 1 ? words.first : '${words.first} ${words[1][0].toUpperCase()}.';
}

// ---- Fees owed --------------------------------------------------------------------------------------

/// A give-up fee a driver still owes (c2c_driver_fees).
class C2cDriverOwed {
  const C2cDriverOwed({required this.id, required this.ref, required this.fee, required this.owed});
  final String id, ref;
  final double fee, owed;
}

/// What the signed-in account owes City to City (c2c_my_owed).
class C2cOwed {
  const C2cOwed({
    this.rider = const [],
    this.driver = const [],
    this.fromTopup = false,
    this.nextInApp = false,
    this.cash = false,
    this.block = false,
  });

  factory C2cOwed.fromJson(Object? v) {
    final m = v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
    final o = m['options'] is Map ? Map<String, dynamic>.from(m['options'] as Map) : const <String, dynamic>{};
    return C2cOwed(
      rider: [
        for (final d in m['rider'] is List ? m['rider'] as List : const [])
          if (d is Map) C2cDue.fromJson(Map<String, dynamic>.from(d)),
      ],
      driver: [
        for (final d in m['driver'] is List ? m['driver'] as List : const [])
          if (d is Map)
            C2cDriverOwed(id: '${d['id']}', ref: _nz(d['ref']) ?? '', fee: _num(d['fee']), owed: _num(d['owed'])),
      ],
      fromTopup: o['topup'] == true,
      nextInApp: o['nextInApp'] == true,
      cash: o['cash'] == true,
      block: o['block'] == true,
    );
  }

  static const none = C2cOwed();

  final List<C2cDue> rider;
  final List<C2cDriverOwed> driver;
  final bool fromTopup, nextInApp, cash, block;

  double get riderTotal => c2cRound2(rider.fold(0.0, (s, d) => s + d.fee));
  double get driverTotal => c2cRound2(driver.fold(0.0, (s, d) => s + d.owed));
  double get total => c2cRound2(riderTotal + driverTotal);
  bool get any => total > 0;

  /// How the rider's fees are collected, as the settings say.
  String? get howLine {
    if (rider.isEmpty) return null;
    final ways = [
      if (fromTopup) 'taken from your next top-up',
      if (nextInApp) 'added to your next in-app payment',
      if (cash) 'collected by the driver of your next cash trip',
    ];
    final how = ways.isEmpty ? '' : 'Otherwise it is ${ways.join(', or ')}. ';
    return '$how${block ? 'New City to City trips can be booked once it is paid.' : ''}'.trim();
  }
}

/// What the admin page says about the owed-fee options.
String c2cOwedNote(C2cSettings s) =>
    'The rider always sees what they owe, why, and a Pay now button in Wallet'
    '${s.owedBlock ? '; booking shows "Pay ${c2cMoney(s.cancelFeeAmount, s.currency)} owed first".' : '.'}';
