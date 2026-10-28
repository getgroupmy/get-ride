// Premium service rules and GET.Plus, the rider membership (migration 0316).
// Pure: the rules by place (Default and regions, the smallest place that
// sets a key wins), who may take a Premium request, the booking card's rule
// line, a member's price, and the server's answers read into models. The
// server works the same out (premium_plus_rules_at, premium_driver_check,
// plus_settle_ride) and is the one that enforces and charges;
// supabase/tests/premium_getplus_0316.sql checks it on the same cases.
import 'commission.dart' show Geo;
import 'format.dart' show formatMoney;

/// The admin page's key (grantable to sub-admins).
const premiumPlusPage = 'admin-settings-premium-plus';

/// The Vehicle Services flag that makes a service Premium (camelCase, as
/// closedBody).
const premiumServiceKey = 'premium';

/// Where the rules are kept.
const premiumPlusTable = 'premium_plus_places';

/// The place levels, broadest first.
const premiumPlusLevels = ['default', 'country', 'state', 'city', 'suburb'];

/// One editable number on the admin cards: its key, label, step and limits.
class PremiumPlusField {
  const PremiumPlusField(this.key, this.label, {required this.step, required this.min, required this.max, this.whole = false});
  final String key;
  final String label;
  final double step, min, max;

  /// Whole numbers only (years, trips, cancels, days).
  final bool whole;

  /// [v] as the card shows it.
  String show(double v) => switch (key) {
    'premiumMaxCarAge' => v <= 0 ? 'No limit' : '${v.round()} ${v.round() == 1 ? 'year' : 'years'} old',
    'premiumMinRating' => v <= 0 ? 'None' : _trim(v),
    'premiumMinTrips' => v <= 0 ? 'None' : '${v.round()}',
    'plusPrice' => formatMoney(v, 'MYR'),
    'plusDiscountPct' => '${_trim(v)}%',
    'plusMaxDiscount' => v <= 0 ? 'No cap' : formatMoney(v, 'MYR'),
    'plusFreeCancels' => '${v.round()}',
    'plusGraceDays' => v <= 0 ? 'None' : '${v.round()} ${v.round() == 1 ? 'day' : 'days'}',
    _ => _trim(v),
  };
}

/// The Premium card's numbers.
const premiumFields = [
  PremiumPlusField('premiumMaxCarAge', 'Car at most', step: 1, min: 0, max: 40, whole: true),
  PremiumPlusField('premiumMinRating', 'Driver rating at least', step: 0.1, min: 0, max: 5),
  PremiumPlusField('premiumMinTrips', 'Driver trips at least', step: 50, min: 0, max: 100000, whole: true),
];

/// The GET.Plus card's numbers.
const plusFields = [
  PremiumPlusField('plusPrice', 'Price a month', step: 1, min: 0, max: 1000),
  PremiumPlusField('plusDiscountPct', 'Discount on rides', step: 1, min: 0, max: 90),
  PremiumPlusField('plusMaxDiscount', 'Most off one ride', step: 1, min: 0, max: 1000),
  PremiumPlusField('plusFreeCancels', 'Free cancels a month', step: 1, min: 0, max: 50, whole: true),
  PremiumPlusField('plusGraceDays', 'Grace when the wallet is short', step: 1, min: 0, max: 30, whole: true),
];

/// Every key a place may set, as the server's check.
const premiumPlusKeys = {
  'premiumOn', 'premiumMaxCarAge', 'premiumModels', 'premiumMinRating', 'premiumMinTrips',
  'plusOn', 'plusPrice', 'plusDiscountPct', 'plusMaxDiscount', 'plusFreeCancels', 'plusPriority', 'plusGraceDays',
};

/// The built-in defaults (the seeded Default row): Premium on, 5 years,
/// 4.8, 200 trips, any model; GET.Plus off until the owner turns it on.
const premiumPlusDefaults = <String, Object>{
  'premiumOn': true,
  'premiumMaxCarAge': 5,
  'premiumModels': <String>[],
  'premiumMinRating': 4.8,
  'premiumMinTrips': 200,
  'plusOn': false,
  'plusPrice': 19.9,
  'plusDiscountPct': 10,
  'plusMaxDiscount': 0,
  'plusFreeCancels': 2,
  'plusPriority': true,
  'plusGraceDays': 3,
};

String _trim(num v) {
  final s = v.toStringAsFixed(2);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}

double _num(Object? v, [double fallback = 0]) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? fallback);

/// Why [rules] (one place's keys) can't be saved, or null. As the server's
/// premium_plus_rules_valid.
String? premiumPlusRulesProblem(Map<String, dynamic> rules) {
  for (final e in rules.entries) {
    if (!premiumPlusKeys.contains(e.key)) return 'Unknown setting ${e.key}.';
    if (e.key == 'premiumOn' || e.key == 'plusOn' || e.key == 'plusPriority') {
      if (e.value is! bool) return 'A switch is on or off.';
      continue;
    }
    if (e.key == 'premiumModels') {
      final v = e.value;
      if (v is! List) return 'Car models are a list.';
      if (v.length > 200) return 'List at most 200 car models.';
      for (final m in v) {
        final t = m is String ? m.trim() : '';
        if (t.isEmpty || t.length > 80) return 'Each car model has a name of 1 to 80 letters.';
      }
      continue;
    }
    final f = [...premiumFields, ...plusFields].firstWhere((f) => f.key == e.key);
    final v = e.value;
    if (v is! num || !v.isFinite) return '${f.label} must be a number.';
    if (v < f.min || v > f.max) return '${f.label} must be from ${_trim(f.min)} to ${_trim(f.max)}.';
    if (f.whole && v != v.roundToDouble()) return '${f.label} must be a whole number.';
  }
  return null;
}

/// One place's rules: Default, or a country, state, city or suburb, with the
/// keys it sets (a region rule only overrides what it sets).
class PremiumPlusPlace {
  const PremiumPlusPlace({this.id, required this.level, this.country, this.state, this.city, this.suburb, this.rules = const {}});

  factory PremiumPlusPlace.fromRow(Map<String, dynamic> r) => PremiumPlusPlace(
    id: r['id'] as String?,
    level: premiumPlusLevels.contains(r['level']) ? r['level'] as String : 'country',
    country: _nz(r['country']),
    state: _nz(r['state']),
    city: _nz(r['city']),
    suburb: _nz(r['suburb']),
    rules: r['rules'] is Map ? Map<String, dynamic>.from(r['rules'] as Map) : const {},
  );

  final String? id;
  final String level;
  final String? country, state, city, suburb;
  final Map<String, dynamic> rules;

  bool get isDefault => level == 'default';

  /// default 0, country 1 … suburb 4.
  int get rank => premiumPlusLevels.indexOf(level);

  String get name => switch (level) {
    'default' => 'Default',
    'suburb' => suburb ?? '',
    'city' => city ?? '',
    'state' => state ?? '',
    _ => country ?? '',
  };

  /// "Kuala Lumpur · city", or "Default".
  String get label => isDefault ? 'Default' : '$name · $level';

  /// The places it sits in, nearest first.
  String get within => [if (rank > 3) city, if (rank > 2) state, if (rank > 1) country].whereType<String>().join(', ');

  /// As the server keys it (ride_option_place_key).
  String get key => isDefault
      ? ''
      : [
          country,
          if (rank >= 2) state,
          if (rank >= 3) city,
          if (rank >= 4) suburb,
        ].map((s) => (s ?? '').trim().toLowerCase()).join('|');

  PremiumPlusPlace withRules(Map<String, dynamic> next) =>
      PremiumPlusPlace(id: id, level: level, country: country, state: state, city: city, suburb: suburb, rules: next);

  Map<String, dynamic> toRow() => {
    'level': level,
    'country': rank >= 1 ? country : null,
    'state': rank >= 2 ? state : null,
    'city': rank >= 3 ? city : null,
    'suburb': rank >= 4 ? suburb : null,
    'rules': rules,
  };
}

String? _nz(Object? v) {
  final t = '${v ?? ''}'.trim();
  return t.isEmpty ? null : t;
}

/// The rules at a place: each key from the smallest place that sets it,
/// over the defaults. As premium_plus_rules_at.
PremiumPlusRules premiumPlusRulesAt(List<PremiumPlusPlace> places, Geo at) {
  String k(String? s) => (s ?? '').trim().toLowerCase();
  final keys = <String>{''};
  if (k(at.country).isNotEmpty) {
    keys.add(k(at.country));
    if (k(at.state).isNotEmpty) {
      keys.add('${k(at.country)}|${k(at.state)}');
      if (k(at.city).isNotEmpty) {
        keys.add('${k(at.country)}|${k(at.state)}|${k(at.city)}');
        if (k(at.suburb).isNotEmpty) keys.add('${k(at.country)}|${k(at.state)}|${k(at.city)}|${k(at.suburb)}');
      }
    }
  }
  final hits = places.where((p) => keys.contains(p.key)).toList()..sort((a, b) => a.rank.compareTo(b.rank));
  final v = <String, dynamic>{...premiumPlusDefaults};
  for (final p in hits) {
    v.addAll(p.rules);
  }
  return PremiumPlusRules.fromJson(v);
}

/// The values that hold at a place (every key filled in).
class PremiumPlusRules {
  const PremiumPlusRules({
    this.premiumOn = true,
    this.maxCarAge = 5,
    this.models = const [],
    this.minRating = 4.8,
    this.minTrips = 200,
    this.plusOn = false,
    this.price = 19.9,
    this.discountPct = 10,
    this.maxDiscount = 0,
    this.freeCancels = 2,
    this.priority = true,
    this.graceDays = 3,
  });

  factory PremiumPlusRules.fromJson(Map<String, dynamic> v) => PremiumPlusRules(
    premiumOn: v['premiumOn'] is bool ? v['premiumOn'] as bool : true,
    maxCarAge: _num(v['premiumMaxCarAge'], 5).round(),
    models: v['premiumModels'] is List ? [for (final m in v['premiumModels'] as List) '$m'] : const [],
    minRating: _num(v['premiumMinRating'], 4.8),
    minTrips: _num(v['premiumMinTrips'], 200).round(),
    plusOn: v['plusOn'] == true,
    price: _num(v['plusPrice'], 19.9),
    discountPct: _num(v['plusDiscountPct'], 10),
    maxDiscount: _num(v['plusMaxDiscount']),
    freeCancels: _num(v['plusFreeCancels'], 2).round(),
    priority: v['plusPriority'] is bool ? v['plusPriority'] as bool : true,
    graceDays: _num(v['plusGraceDays'], 3).round(),
  );

  final bool premiumOn;
  final int maxCarAge;
  final List<String> models;
  final double minRating;
  final int minTrips;
  final bool plusOn;
  final double price;
  final double discountPct;
  final double maxDiscount;
  final int freeCancels;
  final bool priority;
  final int graceDays;

  /// The number for an admin field's [key].
  double number(String key) => switch (key) {
    'premiumMaxCarAge' => maxCarAge.toDouble(),
    'premiumMinRating' => minRating,
    'premiumMinTrips' => minTrips.toDouble(),
    'plusPrice' => price,
    'plusDiscountPct' => discountPct,
    'plusMaxDiscount' => maxDiscount,
    'plusFreeCancels' => freeCancels.toDouble(),
    'plusGraceDays' => graceDays.toDouble(),
    _ => 0,
  };

  bool flag(String key) => switch (key) {
    'premiumOn' => premiumOn,
    'plusOn' => plusOn,
    'plusPriority' => priority,
    _ => false,
  };
}

/// "Toyota  Camry" and "toyota camry" are one name.
String premiumNameKey(String? s) => (s ?? '').trim().replaceAll(RegExp(r'[\s\-]+'), ' ').toLowerCase();

/// Whether a car of [make] [model] is on [list]: a make alone allows its
/// every model; an empty list allows every car. As premium_model_allowed.
bool premiumModelAllowed(List<String> list, String? make, String? model) {
  if (list.isEmpty) return true;
  final m = premiumNameKey(make);
  final mm = premiumNameKey('${make ?? ''} ${model ?? ''}');
  return list.any((x) {
    final k = premiumNameKey(x);
    return k.isNotEmpty && (k == m || k == mm);
  });
}

/// The car's age in whole years: from its registration date, else 1 January
/// of its year. Null when neither is known.
int? premiumCarAge({DateTime? registered, String? year, required DateTime today}) {
  var from = registered;
  if (from == null) {
    final y = RegExp(r'(\d{4})').firstMatch(year ?? '')?.group(1);
    if (y == null) return null;
    from = DateTime(int.parse(y));
  }
  var age = today.year - from.year;
  if (today.month < from.month || (today.month == from.month && today.day < from.day)) age--;
  return age < 0 ? 0 : age;
}

/// Why a driver doesn't qualify for Premium under [r] (empty: they do), in
/// the server's words (premium_driver_check). [hasCar]: a car in session or
/// approved.
List<String> premiumReasons(
  PremiumPlusRules r, {
  required bool hasCar,
  int? carAge,
  String? make,
  String? model,
  double rating = 0,
  int trips = 0,
}) {
  if (!r.premiumOn) return const [];
  final out = <String>[];
  if (!hasCar && (r.maxCarAge > 0 || r.models.isNotEmpty)) {
    out.add('Choose the car you\'re driving first.');
  } else {
    if (r.maxCarAge > 0 && carAge == null) {
      out.add('Your car\'s year isn\'t on record. Ask support to add it.');
    } else if (r.maxCarAge > 0 && carAge! > r.maxCarAge) {
      out.add('Your car is $carAge years old. Premium takes cars ${r.maxCarAge} years old or newer.');
    }
    if (!premiumModelAllowed(r.models, make, model)) {
      final car = [make, model].whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty).join(' ');
      out.add('Premium takes listed car models only, and your ${car.isEmpty ? 'car' : car} isn\'t on the list.');
    }
  }
  if (r.minRating > 0 && rating < r.minRating) {
    out.add('Your rating is ${_trim(rating)}. Premium needs ${_trim(r.minRating)} or more.');
  }
  if (r.minTrips > 0 && trips < r.minTrips) out.add('You have $trips trips. Premium needs ${r.minTrips} or more.');
  return out;
}

/// The Premium rules at the pickup, as the rider's booking card reads them.
class PremiumTerms {
  const PremiumTerms({this.on = true, this.maxCarAge = 0, this.modelsListed = false, this.minRating = 0, this.minTrips = 0});

  factory PremiumTerms.fromJson(Object? j) {
    final m = j is Map ? j : const {};
    return PremiumTerms(
      on: m['on'] != false,
      maxCarAge: _num(m['maxCarAge']).round(),
      modelsListed: m['modelsListed'] == true,
      minRating: _num(m['minRating']),
      minTrips: _num(m['minTrips']).round(),
    );
  }

  final bool on;
  final int maxCarAge;
  final bool modelsListed;
  final double minRating;
  final int minTrips;
}

/// The line under a Premium service on the booking card: "Cars 5 years or
/// newer, listed models, drivers rated 4.8+ with 200+ trips". Null when the
/// rules are off there or set nothing.
String? premiumRuleLine(PremiumTerms t) {
  if (!t.on) return null;
  final parts = <String>[
    if (t.maxCarAge > 0) 'Cars ${t.maxCarAge} ${t.maxCarAge == 1 ? 'year' : 'years'} or newer',
    if (t.modelsListed) t.maxCarAge > 0 ? 'listed models' : 'Listed car models',
  ];
  final driver = [
    if (t.minRating > 0) 'rated ${_trim(t.minRating)}+',
    if (t.minTrips > 0) 'with ${t.minTrips}+ trips',
  ].join(' ');
  if (driver.isNotEmpty) parts.add(parts.isEmpty ? 'Drivers $driver' : 'drivers $driver');
  return parts.isEmpty ? null : parts.join(', ');
}

/// GET.Plus at a place, as the admin set it.
class PlusOffer {
  const PlusOffer({
    this.on = false,
    this.price = 0,
    this.discountPct = 0,
    this.maxDiscount = 0,
    this.freeCancels = 0,
    this.priority = false,
    this.graceDays = 0,
  });

  factory PlusOffer.fromJson(Object? j) {
    final m = j is Map ? j : const {};
    return PlusOffer(
      on: m['on'] == true,
      price: _num(m['price']),
      discountPct: _num(m['discountPct']),
      maxDiscount: _num(m['maxDiscount']),
      freeCancels: _num(m['freeCancels']).round(),
      priority: m['priority'] == true,
      graceDays: _num(m['graceDays']).round(),
    );
  }

  final bool on;
  final double price;
  final double discountPct;
  final double maxDiscount;
  final int freeCancels;
  final bool priority;
  final int graceDays;
}

enum PlusStatus {
  active('Active'),
  grace('Payment due'),
  ended('Ended'),
  expired('Expired');

  const PlusStatus(this.label);
  final String label;

  static PlusStatus parse(Object? s) => values.where((v) => v.name == s).firstOrNull ?? PlusStatus.ended;
}

/// The rider's membership.
class PlusMembership {
  const PlusMembership({
    required this.status,
    required this.live,
    required this.autoRenew,
    this.joinedAt,
    this.periodStart,
    this.periodEnd,
    this.graceUntil,
    this.price = 0,
    this.freeCancelsUsed = 0,
    this.lastError,
  });

  static PlusMembership? fromJson(Object? j) {
    if (j is! Map) return null;
    DateTime? t(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();
    return PlusMembership(
      status: PlusStatus.parse(j['status']),
      live: j['live'] == true,
      autoRenew: j['autoRenew'] == true,
      joinedAt: t(j['joinedAt']),
      periodStart: t(j['periodStart']),
      periodEnd: t(j['periodEnd']),
      graceUntil: t(j['graceUntil']),
      price: _num(j['price']),
      freeCancelsUsed: _num(j['freeCancelsUsed']).round(),
      lastError: _nz(j['lastError']),
    );
  }

  final PlusStatus status;

  /// Its benefits hold now.
  final bool live;
  final bool autoRenew;
  final DateTime? joinedAt, periodStart, periodEnd, graceUntil;
  final double price;
  final int freeCancelsUsed;
  final String? lastError;

  /// A member who cancelled and still has the month.
  bool get cancelling => status == PlusStatus.active && !autoRenew;
}

/// What a live membership gives at a place.
class PlusBenefits {
  const PlusBenefits({this.pct = 0, this.maxDiscount = 0, this.priority = false, this.freeCancels = 0, this.freeCancelsLeft = 0});

  static PlusBenefits? fromJson(Object? j) {
    if (j is! Map) return null;
    return PlusBenefits(
      pct: _num(j['pct']),
      maxDiscount: _num(j['maxDiscount']),
      priority: j['priority'] == true,
      freeCancels: _num(j['freeCancels']).round(),
      freeCancelsLeft: _num(j['freeCancelsLeft']).round(),
    );
  }

  final double pct;
  final double maxDiscount;
  final bool priority;
  final int freeCancels;
  final int freeCancelsLeft;

  /// What a member pays for a ride of [fare] (the driver's fare): less the
  /// discount, at most [maxDiscount] off when set. As plus_settle_ride.
  double price(double fare) => plusMemberPrice(fare, pct: pct, maxDiscount: maxDiscount);
}

/// [fare] less [pct] %, never more than [maxDiscount] off (0: no cap).
double plusMemberPrice(double fare, {required double pct, double maxDiscount = 0}) {
  if (fare <= 0 || pct <= 0) return fare;
  var off = (fare * pct).round() / 100;
  if (maxDiscount > 0 && off > maxDiscount) off = maxDiscount;
  if (off > fare) off = fare;
  return ((fare - off) * 100).round() / 100;
}

/// The member banner on the booking card: "GET.Plus member: 10% off,
/// priority matching, 2 free cancels left this month".
String plusBannerLine(PlusBenefits b) {
  final parts = <String>[
    if (b.pct > 0) '${_trim(b.pct)}% off${b.maxDiscount > 0 ? ' (up to ${formatMoney(b.maxDiscount, 'MYR')})' : ''}',
    if (b.priority) 'priority matching',
    if (b.freeCancels > 0)
      b.freeCancelsLeft <= 0
          ? 'no free cancels left this month'
          : '${b.freeCancelsLeft} free ${b.freeCancelsLeft == 1 ? 'cancel' : 'cancels'} left this month',
  ];
  return parts.isEmpty ? 'GET.Plus member' : 'GET.Plus member: ${parts.join(', ')}';
}

/// premium_plus_terms: the rules at a place and the caller's membership.
class PremiumPlusTerms {
  const PremiumPlusTerms({
    this.premium = const PremiumTerms(),
    this.plus = const PlusOffer(),
    this.membership,
    this.benefits,
    this.walletBalance = 0,
  });

  factory PremiumPlusTerms.fromJson(Object? j) {
    final m = j is Map ? j : const {};
    return PremiumPlusTerms(
      premium: PremiumTerms.fromJson(m['premium']),
      plus: PlusOffer.fromJson(m['plus']),
      membership: PlusMembership.fromJson(m['membership']),
      benefits: PlusBenefits.fromJson(m['benefits']),
      walletBalance: _num(m['walletBalance']),
    );
  }

  static const none = PremiumPlusTerms();

  final PremiumTerms premium;
  final PlusOffer plus;
  final PlusMembership? membership;

  /// What the membership gives here; null when none holds or GET.Plus is off.
  final PlusBenefits? benefits;
  final double walletBalance;
}

/// One receipt (plus_charges).
class PlusReceipt {
  const PlusReceipt({
    required this.id,
    required this.number,
    required this.kind,
    required this.paid,
    required this.amount,
    required this.createdAt,
    this.periodStart,
    this.periodEnd,
    this.note,
  });

  factory PlusReceipt.fromRow(Map<String, dynamic> r) => PlusReceipt(
    id: '${r['id']}',
    number: _num(r['receipt_no']).round(),
    kind: '${r['kind'] ?? 'join'}',
    paid: r['status'] == 'paid',
    amount: _num(r['amount']),
    createdAt: DateTime.tryParse('${r['created_at']}')?.toLocal() ?? DateTime(2000),
    periodStart: DateTime.tryParse('${r['period_start'] ?? ''}')?.toLocal(),
    periodEnd: DateTime.tryParse('${r['period_end'] ?? ''}')?.toLocal(),
    note: _nz(r['note']),
  );

  final String id;
  final int number;
  final String kind;
  final bool paid;
  final double amount;
  final DateTime createdAt;
  final DateTime? periodStart, periodEnd;
  final String? note;

  /// "GP-000123".
  String get label => 'GP-${number.toString().padLeft(6, '0')}';
}

/// A row of Admin › GET.Plus members.
class PlusMemberRow {
  const PlusMemberRow({
    required this.riderId,
    this.name,
    this.phone,
    required this.status,
    this.live = false,
    this.autoRenew = true,
    this.joinedAt,
    this.periodEnd,
    this.graceUntil,
    this.price = 0,
    this.freeCancelsUsed = 0,
    this.place,
    this.paid = 0,
    this.saved = 0,
  });

  factory PlusMemberRow.fromJson(Map<String, dynamic> j) {
    DateTime? t(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();
    return PlusMemberRow(
      riderId: '${j['riderId']}',
      name: _nz(j['name']),
      phone: _nz(j['phone']),
      status: PlusStatus.parse(j['status']),
      live: j['live'] == true,
      autoRenew: j['autoRenew'] != false,
      joinedAt: t(j['joinedAt']),
      periodEnd: t(j['periodEnd']),
      graceUntil: t(j['graceUntil']),
      price: _num(j['price']),
      freeCancelsUsed: _num(j['freeCancelsUsed']).round(),
      place: _nz(j['place']),
      paid: _num(j['paid']),
      saved: _num(j['saved']),
    );
  }

  final String riderId;
  final String? name, phone;
  final PlusStatus status;
  final bool live, autoRenew;
  final DateTime? joinedAt, periodEnd, graceUntil;
  final double price;
  final int freeCancelsUsed;
  final String? place;
  final double paid, saved;
}

/// A page of members and how many there are in all.
typedef PlusMembersPage = ({int total, List<PlusMemberRow> rows});

PlusMembersPage plusMembersPageFromJson(Object? j) {
  final m = j is Map ? j : const {};
  final rows = m['rows'] is List ? m['rows'] as List : const [];
  return (
    total: _num(m['total']).round(),
    rows: [for (final r in rows) if (r is Map) PlusMemberRow.fromJson(Map<String, dynamic>.from(r))],
  );
}

/// Admin › GET.Plus revenue over [days].
class PlusRevenue {
  const PlusRevenue({
    this.days = 30,
    this.active = 0,
    this.grace = 0,
    this.cancelling = 0,
    this.joins = 0,
    this.renewals = 0,
    this.failed = 0,
    this.fees = 0,
    this.discounts = 0,
    this.discountedRides = 0,
    this.waivedPaid = 0,
    this.freeCancels = 0,
    this.commissionOnMemberRides = 0,
    this.net = 0,
  });

  factory PlusRevenue.fromJson(Object? j) {
    final m = j is Map ? j : const {};
    int i(String k) => _num(m[k]).round();
    double d(String k) => _num(m[k]);
    return PlusRevenue(
      days: i('days'),
      active: i('active'),
      grace: i('grace'),
      cancelling: i('cancelling'),
      joins: i('joins'),
      renewals: i('renewals'),
      failed: i('failed'),
      fees: d('fees'),
      discounts: d('discounts'),
      discountedRides: i('discountedRides'),
      waivedPaid: d('waivedPaid'),
      freeCancels: i('freeCancels'),
      commissionOnMemberRides: d('commissionOnMemberRides'),
      net: d('net'),
    );
  }

  final int days, active, grace, cancelling, joins, renewals, failed;
  final double fees, discounts;
  final int discountedRides;
  final double waivedPaid;
  final int freeCancels;
  final double commissionOnMemberRides, net;
}

/// One Premium service and whether the signed-in driver qualifies
/// (my_premium_status).
class PremiumStatus {
  const PremiumStatus({required this.service, required this.ok, this.rulesOn = true, this.reasons = const []});

  factory PremiumStatus.fromJson(Map<String, dynamic> j) => PremiumStatus(
    service: '${j['service'] ?? 'Premium'}',
    ok: j['ok'] != false,
    rulesOn: j['rulesOn'] != false,
    reasons: j['reasons'] is List ? [for (final r in j['reasons'] as List) '$r'] : const [],
  );

  final String service;
  final bool ok;
  final bool rulesOn;
  final List<String> reasons;
}

/// The server's words when a Premium offer or take was refused
/// (PREMIUM_NOT_ELIGIBLE), else null.
String? premiumRefusalReason(Object e) {
  final s = '$e';
  if (!s.contains('PREMIUM_NOT_ELIGIBLE')) return null;
  final hint = RegExp(r'hint: (.+?)\)?$').firstMatch(s)?.group(1)?.trim();
  return hint != null && hint.startsWith('You can')
      ? hint
      : 'You can\'t take Premium requests yet. See Services for what Premium needs.';
}

/// A join or a cancel the server refused, in words.
String plusError(Object e, {double? price}) {
  final s = '$e';
  if (s.contains('insufficient_balance')) {
    return price == null
        ? 'Top up GET.wallet to join GET.Plus.'
        : 'Top up GET.wallet: GET.Plus is ${formatMoney(price, 'MYR')} a month.';
  }
  if (s.contains('PLUS_PRICE_CHANGED')) return 'The price of GET.Plus just changed. Check it and try again.';
  if (s.contains('PLUS_OFF')) return 'GET.Plus isn\'t offered here yet.';
  if (s.contains('PLUS_NOT_MEMBER')) return 'You aren\'t a GET.Plus member.';
  return 'Couldn\'t do that. Check your connection and try again.';
}

/// Queue order for drivers: GET.Plus members' requests first, the rest in
/// the order they came (stable).
List<T> plusPriorityFirst<T>(List<T> list, bool Function(T) priority) => [
  ...list.where(priority),
  ...list.where((r) => !priority(r)),
];
