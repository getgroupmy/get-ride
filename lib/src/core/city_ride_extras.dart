// City ride extras (migration 0314): tips, the waiting charge and luggage,
// set by place in Admin > Services & catalogue > City ride extras. Pure.
//
// Settings are kept one object per card ("section") in
// `city_ride_extra_places.rules`: {"tips": {...}, "waiting": {...},
// "luggage": {...}}. Default holds for everywhere; a country, state, city or
// suburb row lays only the keys it sets over the place above, key by key,
// as the server's `city_ride_extras_at` does. Later cards (rider audio,
// Premium, GET.Plus) add a section to [cityRideExtrasDefaults] and a card to
// [cityRideExtrasCards]; nothing else here changes.
import 'dart:math' as math;

import 'format.dart' show formatMoney;
import 'option_charge.dart' show cents;
import 'partner_type_rules.dart' show RegionScope;
import 'ride_option_charges.dart' show OptionChargeLine;
import 'ride_option_places.dart' show OptionPlaceScope;

/// The admin page's permission id (Admin access, sub-admin grants).
const cityRideExtrasPage = 'admin-settings-city-ride-extras';

/// Every card's built-in values, as the server's
/// `city_ride_extras_default_<section>()` (0314).
const cityRideExtrasDefaults = <String, Map<String, Object>>{
  'tips': {
    'on': true,
    'preset1': 2,
    'preset2': 5,
    'preset3': 10,
    'min': 1,
    'max': 100,
    'days': 3,
    'commissionPercent': 0,
  },
  'waiting': {'on': true, 'freeMinutes': 3, 'perMinute': 0.3, 'cap': 6, 'radiusM': 150},
  'luggage': {'on': true, 'freeBags': 2, 'perBag': 2, 'maxBags': 5},
};

double _n(Object? v, double fallback) => v is num && v.isFinite ? v.toDouble() : fallback;

Map<String, Map<String, Object?>> _sections(Object? raw) => {
  if (raw is Map)
    for (final e in raw.entries)
      if (e.value is Map) '${e.key}': Map<String, Object?>.from(e.value as Map),
};

/// One `city_ride_extra_places` row: a place and the keys it sets.
class ExtrasPlace {
  const ExtrasPlace({this.id, this.scope = RegionScope.all, this.rules = const {}});

  factory ExtrasPlace.fromRow(Map<String, dynamic> r) {
    String s(Object? v) => v is String ? v.trim() : '';
    final scope = RegionScope(country: s(r['country']), state: s(r['state']), city: s(r['city']), suburb: s(r['suburb']));
    return ExtrasPlace(
      id: r['id'] as String?,
      scope: r['level'] == 'default' ? RegionScope.all : scope,
      rules: _sections(r['rules']),
    );
  }

  final String? id;
  final RegionScope scope;

  /// Only what this place sets, per card.
  final Map<String, Map<String, Object?>> rules;

  bool get isDefault => scope.isAll;
  String get label => scope.placeName;

  /// Whether this place sets anything of [section].
  bool sets(String section) => rules[section]?.isNotEmpty ?? false;

  ExtrasPlace withSection(String section, Map<String, Object?>? values) {
    final next = {for (final e in rules.entries) e.key: e.value};
    if (values == null || values.isEmpty) {
      next.remove(section);
    } else {
      next[section] = values;
    }
    return ExtrasPlace(id: id, scope: scope, rules: next);
  }

  /// The row to insert (a new place) or the rules to write.
  Map<String, dynamic> toRow() {
    final p = scope.path;
    return {
      'level': scope.level,
      'country': p.isNotEmpty ? p[0] : null,
      'state': p.length > 1 ? p[1] : null,
      'city': p.length > 2 ? p[2] : null,
      'suburb': p.length > 3 ? p[3] : null,
      'rules': rules,
    };
  }
}

/// What holds at one place: every card's values.
class CityRideExtras {
  const CityRideExtras(this.values);

  /// Built-in values alone (nothing read yet, or an older server).
  static final standard = CityRideExtras.resolve(const [], RegionScope.all);

  /// [places] laid over the defaults for [at]: Default, then each place
  /// from the country down to [at] itself, key by key.
  factory CityRideExtras.resolve(List<ExtrasPlace> places, RegionScope at) {
    final v = <String, Map<String, Object?>>{
      for (final e in cityRideExtrasDefaults.entries) e.key: Map<String, Object?>.from(e.value),
    };
    final byKey = {for (final p in places) p.scope.key: p};
    for (final s in at.chain.reversed) {
      final p = byKey[s.key];
      if (p == null) continue;
      for (final e in p.rules.entries) {
        (v[e.key] ??= {}).addAll(e.value);
      }
    }
    return CityRideExtras(v);
  }

  /// As the server's `city_ride_extras_here` answers.
  factory CityRideExtras.fromJson(Object? json) {
    final v = <String, Map<String, Object?>>{
      for (final e in cityRideExtrasDefaults.entries) e.key: Map<String, Object?>.from(e.value),
    };
    for (final e in _sections(json).entries) {
      (v[e.key] ??= {}).addAll(e.value);
    }
    return CityRideExtras(v);
  }

  final Map<String, Map<String, Object?>> values;

  Map<String, Object?> section(String id) => values[id] ?? const {};

  TipRules get tips => TipRules.fromJson(section('tips'));
  WaitingRules get waiting => WaitingRules.fromJson(section('waiting'));
  LuggageRules get luggage => LuggageRules.fromJson(section('luggage'));
}

// ---- Tips ------------------------------------------------------------------------------------------

class TipRules {
  const TipRules({
    this.on = true,
    this.presets = const [2, 5, 10],
    this.min = 1,
    this.max = 100,
    this.days = 3,
    this.commissionPercent = 0,
  });

  factory TipRules.fromJson(Map<String, Object?> j) => TipRules(
    on: j['on'] != false,
    presets: [_n(j['preset1'], 2), _n(j['preset2'], 5), _n(j['preset3'], 10)],
    min: _n(j['min'], 1),
    max: _n(j['max'], 100),
    days: _n(j['days'], 3).round(),
    commissionPercent: _n(j['commissionPercent'], 0),
  );

  final bool on;
  final List<double> presets;
  final double min, max;
  final int days;
  final double commissionPercent;
}

/// What `ride_tip_terms` answers for one ride.
class TipTerms {
  const TipTerms({
    this.on = false,
    this.presets = const [2, 5, 10],
    this.min = 1,
    this.max = 100,
    this.days = 3,
    this.commissionPercent = 0,
    this.until,
    this.currency = 'MYR',
    this.driverName,
    this.canTip = false,
    this.why,
    this.tip,
    this.cashTip,
  });

  factory TipTerms.fromJson(Object? json) {
    if (json is! Map) return const TipTerms();
    final presets = json['presets'];
    return TipTerms(
      on: json['on'] == true,
      presets: presets is List ? [for (final p in presets) _n(p, 0)].where((p) => p > 0).toList() : const [2, 5, 10],
      min: _n(json['min'], 1),
      max: _n(json['max'], 100),
      days: _n(json['days'], 3).round(),
      commissionPercent: _n(json['commissionPercent'], 0),
      until: DateTime.tryParse('${json['until'] ?? ''}'),
      currency: json['currency'] is String ? json['currency'] as String : 'MYR',
      driverName: json['driverName'] is String ? (json['driverName'] as String).trim() : null,
      canTip: json['canTip'] == true,
      why: json['why'] as String?,
      tip: GivenTip.fromJson(json['tip']),
      cashTip: CashTipMark.fromJson(json['cashTip']),
    );
  }

  final bool on;
  final List<double> presets;
  final double min, max;
  final int days;
  final double commissionPercent;
  final DateTime? until;
  final String currency;
  final String? driverName;
  final bool canTip;

  /// Why not: 'off', 'not_completed', 'no_driver', 'own_trip', 'tipped',
  /// 'expired' or 'not_rider'.
  final String? why;
  final GivenTip? tip;

  /// The driver's own "Got a cash tip" mark (the driver's view only).
  final CashTipMark? cashTip;

  /// "Hafiz", or "your driver".
  String get driverFirstName {
    final n = driverName?.split(RegExp(r'\s+')).first ?? '';
    return n.isEmpty ? 'your driver' : n;
  }

  /// Whether [amount] can be given.
  bool allows(double amount) => amount >= min - 0.0001 && amount <= max + 0.0001;

  /// "All of it goes to Hafiz." or "Hafiz gets 90% of it."
  String get shareLine {
    final name = driverFirstName;
    final who = name == 'your driver' ? 'Your driver' : name;
    if (commissionPercent <= 0) return 'All of it goes to ${name == 'your driver' ? 'your driver' : name}.';
    final keep = 100 - commissionPercent;
    return '$who gets ${keep == keep.roundToDouble() ? keep.round() : keep.toStringAsFixed(1)}% of it.';
  }

  /// "You can also tip from the receipt for 3 days."
  String get laterLine => 'You can also tip from the receipt for $days ${days == 1 ? 'day' : 'days'}.';
}

class GivenTip {
  const GivenTip({required this.amount, required this.method, this.driverAmount, this.at});

  static GivenTip? fromJson(Object? v) {
    if (v is! Map || v['amount'] is! num) return null;
    return GivenTip(
      amount: (v['amount'] as num).toDouble(),
      method: '${v['method'] ?? ''}',
      driverAmount: v['driverAmount'] is num ? (v['driverAmount'] as num).toDouble() : null,
      at: DateTime.tryParse('${v['at'] ?? ''}'),
    );
  }

  final double amount;

  /// 'get_wallet' or 'get_coin'.
  final String method;
  final double? driverAmount;
  final DateTime? at;

  String get methodLabel => method == 'get_coin' ? 'GET.coin' : 'GET.wallet';
}

class CashTipMark {
  const CashTipMark({this.amount});

  static CashTipMark? fromJson(Object? v) =>
      v is Map ? CashTipMark(amount: v['amount'] is num ? (v['amount'] as num).toDouble() : null) : null;

  final double? amount;
}

/// How a tip can be paid.
enum TipMethod {
  wallet('get_wallet', 'GET.wallet'),
  coin('get_coin', 'GET.coin');

  const TipMethod(this.db, this.label);
  final String db;
  final String label;
}

/// What the server's tip refusal means for the rider.
String tipErrorMessage(Object error) {
  final s = '$error';
  if (s.contains('insufficient_balance')) return 'Not enough balance for this tip. Top up, or pick the other balance.';
  if (s.contains('TIP_EXPIRED')) return 'The time to tip this trip has passed.';
  if (s.contains('TIP_AMOUNT')) return 'That amount can\'t be given as a tip here.';
  if (s.contains('TIP_OFF')) return 'Tips aren\'t taken here.';
  if (s.contains('TIP_OWN_TRIP')) return 'You can\'t tip your own trip.';
  if (s.contains('coins_unavailable')) return 'GET.coin can\'t be used right now.';
  return 'The tip didn\'t go through. Please try again.';
}

// ---- Waiting ---------------------------------------------------------------------------------------

class WaitingRules {
  const WaitingRules({this.on = true, this.freeMinutes = 3, this.perMinute = 0.3, this.cap = 6, this.radiusM = 150});

  factory WaitingRules.fromJson(Map<String, Object?> j) => WaitingRules(
    on: j['on'] != false,
    freeMinutes: _n(j['freeMinutes'], 3),
    perMinute: _n(j['perMinute'], 0.3),
    cap: _n(j['cap'], 6),
    radiusM: _n(j['radiusM'], 150),
  );

  final bool on;
  final double freeMinutes, perMinute, cap, radiusM;

  /// Whether waiting ever costs anything here.
  bool get charges => on && perMinute > 0 && cap > 0;

  /// The booking screen's line, or null when waiting is free here.
  String? ruleLine(String Function(double) money) {
    if (!charges) return null;
    final free = _whole(freeMinutes);
    return 'Waiting: the first $free ${free == '1' ? 'minute' : 'minutes'} after your driver arrives are free, '
        'then ${money(perMinute)} a minute (up to ${money(cap)}). Scheduled rides count from the booked time.';
  }
}

String _whole(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

/// The terms stamped on a ride when the driver's Arrived was checked
/// (`ride_requests.waiting_terms`).
class WaitingTerms {
  const WaitingTerms({this.freeMinutes = 0, this.perMinute = 0, this.cap = 0});

  static WaitingTerms? fromJson(Object? v) {
    if (v is! Map) return null;
    return WaitingTerms(freeMinutes: _n(v['freeMinutes'], 0), perMinute: _n(v['perMinute'], 0), cap: _n(v['cap'], 0));
  }

  final double freeMinutes, perMinute, cap;
}

/// The whole minutes waited from [from] to [at] and what they cost: past
/// the free ones, at the rate, at most the cap. Kept in step with the
/// server's `ride_waiting_charge` (0314).
({int minutes, double charge}) waitingCharge(WaitingTerms terms, DateTime from, DateTime at) {
  final secs = at.difference(from).inSeconds;
  final minutes = secs <= 0 ? 0 : secs ~/ 60;
  final billed = math.max(0.0, minutes - terms.freeMinutes);
  return (minutes: minutes, charge: cents(math.min(terms.cap, billed * terms.perMinute)));
}

/// What the rider's and the driver's waiting clock shows at [now].
class WaitingClock {
  const WaitingClock({required this.terms, required this.from, required this.now});

  final WaitingTerms terms;
  final DateTime from;
  final DateTime now;

  /// Before the clock starts (a scheduled ride's booked time ahead).
  bool get notStarted => now.isBefore(from);

  Duration get freeLeft {
    final end = from.add(Duration(milliseconds: (terms.freeMinutes * 60000).round()));
    final left = end.difference(now.isBefore(from) ? from : now);
    return left.isNegative ? Duration.zero : left;
  }

  bool get charging => !notStarted && freeLeft == Duration.zero && terms.perMinute > 0;

  ({int minutes, double charge}) get sofar => waitingCharge(terms, from, now);

  bool get capped => terms.cap > 0 && sofar.charge >= terms.cap;

  /// "Free waiting" / "Waiting charge running".
  String get label => notStarted
      ? 'Waiting starts at the booked time'
      : charging
      ? (capped ? 'Waiting charge (at its most)' : 'Waiting charge running')
      : 'Free waiting';

  /// The big figure: "2:41 free left", or the charge so far.
  String headline(String Function(double) money) {
    if (notStarted || !charging) return '${_minSec(freeLeft)} free left';
    return money(sofar.charge);
  }

  /// "Waited 9 min. Free 3 min, then RM0.30 a minute, up to RM6.00."
  String note(String Function(double) money) {
    final free = _whole(terms.freeMinutes);
    return 'Waited ${sofar.minutes} min. Free $free min, then ${money(terms.perMinute)} a minute, '
        'up to ${money(terms.cap)}.';
  }
}

String _minSec(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// What Arrived's refusal means for the driver (RIDE_ARRIVED_TOO_FAR).
String? arrivedRefusal(Object error) {
  final s = '$error';
  if (!s.contains('RIDE_ARRIVED_TOO_FAR')) return null;
  final m = RegExp(r"You're about [^\n]*?of it\.").firstMatch(s);
  return m?.group(0) ?? 'You\'re too far from the pickup to tap Arrived. Get closer first.';
}

// ---- Luggage ---------------------------------------------------------------------------------------

/// The kind of the luggage line in `option_charges`.
const luggageChargeKind = 'luggage';

class LuggageRules {
  const LuggageRules({this.on = true, this.freeBags = 2, this.perBag = 2, this.maxBags = 5});

  factory LuggageRules.fromJson(Map<String, Object?> j) => LuggageRules(
    on: j['on'] != false,
    freeBags: _n(j['freeBags'], 2).round(),
    perBag: _n(j['perBag'], 2),
    maxBags: _n(j['maxBags'], 5).round(),
  );

  final bool on;
  final int freeBags;
  final double perBag;
  final int maxBags;

  /// Bags beyond the free ones.
  int extraBags(int bags) => math.max(0, bags - freeBags);

  /// What [bags] add to the fare.
  double charge(int bags) => on ? cents(extraBags(bags) * perBag) : 0;

  /// [bags] held to what can be booked.
  int clamp(int bags) => bags.clamp(0, on ? maxBags : 0);

  /// The line on the ride, or null when the bags cost nothing.
  OptionChargeLine? line(int bags) {
    final c = charge(bags);
    if (c <= 0) return null;
    return OptionChargeLine(kind: luggageChargeKind, name: luggageLineName(bags, freeBags), amount: c);
  }

  /// "2 free, then RM2.00 a bag · + RM2.00".
  String note(int bags, String Function(double) money) {
    final rule = perBag <= 0
        ? 'Free'
        : freeBags > 0
        ? '$freeBags free, then ${money(perBag)} a bag'
        : '${money(perBag)} a bag';
    final c = charge(bags);
    return c > 0 ? '$rule · + ${money(c)}' : rule;
  }
}

/// "Luggage: 3 bags (2 free)".
String luggageLineName(int bags, int free) =>
    'Luggage: $bags ${bags == 1 ? 'bag' : 'bags'}${free > 0 ? ' ($free free)' : ''}';

/// The rider's or driver's line for a booking's bags: "3 bags".
String bagsLabel(int bags) => '$bags ${bags == 1 ? 'bag' : 'bags'}';

// ---- The admin page's cards --------------------------------------------------------------------------

/// One value a card edits with − and +.
class ExtrasField {
  const ExtrasField(this.key, this.label, {required this.step, required this.min, required this.max, this.unit = ExtrasUnit.number});

  final String key;
  final String label;
  final double step, min, max;
  final ExtrasUnit unit;

  /// [v] one step down or up, held to the limits; null at a limit.
  double? stepped(double v, int dir) {
    final n = ((v + dir * step) * 100).roundToDouble() / 100;
    if (n < min - 1e-9 || n > max + 1e-9) return null;
    return n;
  }

  String show(double v, String Function(double) money) => switch (unit) {
    ExtrasUnit.money => money(v),
    ExtrasUnit.percent => '${_whole(v)}%',
    ExtrasUnit.minutes => '${_whole(v)} min',
    ExtrasUnit.days => '${_whole(v)} ${v == 1 ? 'day' : 'days'}',
    ExtrasUnit.metres => '${_whole(v)} m',
    ExtrasUnit.number => _whole(v),
  };
}

enum ExtrasUnit { number, money, percent, minutes, days, metres }

/// A card of the admin page: one section of the rules.
class ExtrasCard {
  const ExtrasCard({required this.section, required this.title, required this.note, required this.fields});

  final String section;
  final String title;
  final String note;
  final List<ExtrasField> fields;
}

/// The page's cards, in order. Ranges mirror the server's checkers.
const cityRideExtrasCards = <ExtrasCard>[
  ExtrasCard(
    section: 'tips',
    title: 'Tips',
    note: 'Paid with GET.wallet or GET.coin after the trip; drivers can mark cash tips for their own earnings view.',
    fields: [
      ExtrasField('preset1', 'Preset 1', step: 1, min: 1, max: 200, unit: ExtrasUnit.money),
      ExtrasField('preset2', 'Preset 2', step: 1, min: 1, max: 200, unit: ExtrasUnit.money),
      ExtrasField('preset3', 'Preset 3', step: 1, min: 1, max: 200, unit: ExtrasUnit.money),
      ExtrasField('min', 'Smallest other amount', step: 0.5, min: 0.5, max: 100, unit: ExtrasUnit.money),
      ExtrasField('max', 'Largest other amount', step: 5, min: 1, max: 1000, unit: ExtrasUnit.money),
      ExtrasField('days', 'Tip from the receipt for', step: 1, min: 1, max: 30, unit: ExtrasUnit.days),
      ExtrasField('commissionPercent', 'Commission on tips', step: 1, min: 0, max: 50, unit: ExtrasUnit.percent),
    ],
  ),
  ExtrasCard(
    section: 'waiting',
    title: 'Waiting charge',
    note: 'Rides now: from Arrived. Scheduled rides: from the booked time if the driver is there. '
        'Added to the fare when the driver taps that the rider is picked up.',
    fields: [
      ExtrasField('freeMinutes', 'Free waiting', step: 1, min: 0, max: 30, unit: ExtrasUnit.minutes),
      ExtrasField('perMinute', 'Then per minute', step: 0.05, min: 0, max: 5, unit: ExtrasUnit.money),
      ExtrasField('cap', 'Most charged', step: 1, min: 0, max: 100, unit: ExtrasUnit.money),
      ExtrasField('radiusM', 'Arrived only within', step: 25, min: 25, max: 1000, unit: ExtrasUnit.metres),
    ],
  ),
  ExtrasCard(
    section: 'luggage',
    title: 'Luggage',
    note: 'The rider picks the bags when booking; the driver sees them on the request. Default started from the '
        'meter\'s luggage numbers.',
    fields: [
      ExtrasField('freeBags', 'Free bags', step: 1, min: 0, max: 10),
      ExtrasField('perBag', 'Per extra bag', step: 0.5, min: 0, max: 50, unit: ExtrasUnit.money),
      ExtrasField('maxBags', 'Most bags', step: 1, min: 1, max: 20),
    ],
  ),
];

/// What is wrong with one card's values, or null (as the server's checkers).
String? extrasSectionProblem(String section, Map<String, Object?> values) {
  final card = cityRideExtrasCards.where((c) => c.section == section).firstOrNull;
  if (card == null) return null;
  for (final e in values.entries) {
    if (e.key == 'on') {
      if (e.value is! bool) return 'On or off is missing';
      continue;
    }
    final f = card.fields.where((f) => f.key == e.key).firstOrNull;
    final v = e.value;
    if (f == null) return '${e.key} is not a setting of ${card.title}';
    if (v is! num || v < f.min || v > f.max) return '${f.label} must be from ${_whole(f.min)} to ${_whole(f.max)}';
  }
  num? g(String k) => values[k] is num ? values[k] as num : null;
  if (section == 'tips' && g('min') != null && g('max') != null && g('min')! > g('max')!) {
    return 'The smallest tip is more than the largest';
  }
  if (section == 'luggage' && g('freeBags') != null && g('maxBags') != null && g('freeBags')! > g('maxBags')!) {
    return 'More free bags than bags allowed';
  }
  return null;
}

/// Money for the admin page, where no ride gives a currency.
String extrasMoney(double v, [String currency = 'MYR']) => formatMoney(v, currency, v == v.roundToDouble() ? 0 : 2);
