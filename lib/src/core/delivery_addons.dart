/// Freight and Courier add-ons (migration 0312): parcel cover, round trip,
/// stairs, the cold truck and cash on delivery for the item. The admin keeps
/// a Default rule and a rule per region (`delivery_addon_rules`); a region
/// rule keeps only what it sets, field by field, the rest follows the rule
/// above, and each add-on has its own switch per region. The amounts are
/// worked out here exactly as the server checks them
/// (delivery_addons_problem), and the booked lines go on the ride's
/// `option_charges` beside the freight options. Pure.
library;

import 'option_charge.dart' show cents, trimNumber;
import 'partner_type_rules.dart' show RegionScope;
import 'ride_option_charges.dart' show OptionChargeLine, optionChargesTotal;
import 'ride_option_places.dart' show OptionPlaceScope;

/// The five add-ons, as the rules' JSON keys them.
enum DeliveryAddon {
  cover('cover', 'Parcel cover'),
  roundTrip('roundTrip', 'Round trip'),
  stairs('stairs', 'Stairs (Freight)'),
  cold('cold', 'Cold truck (Freight)'),
  cod('cod', 'Item cash on delivery (Courier)');

  const DeliveryAddon(this.key, this.title);
  final String key;
  final String title;

  /// Offered on Freight ([freight] true) or Courier bookings.
  bool forKind({required bool freight}) => switch (this) {
    cover || roundTrip => true,
    stairs || cold => freight,
    cod => !freight,
  };
}

/// The option_charges kinds of the add-ons (as the server's
/// delivery_addon_kinds).
abstract final class AddonLineKind {
  static const cover = 'parcel-cover';
  static const roundTrip = 'round-trip';
  static const stairs = 'stairs';
  static const cold = 'cold-truck';
  static const all = [cover, roundTrip, stairs, cold];
}

/// The built-in values (as delivery_addon_defaults); every add-on off.
const Map<String, Map<String, Object>> deliveryAddonDefaults = {
  'cover': {
    'on': false,
    'pct': 1,
    'min': 2,
    'max': 5000,
    'claimDays': 7,
    'excluded': [
      'Cash, cards and vouchers',
      'Jewellery, watches and precious metals',
      'Glass and fragile items not packed for transport',
      'Perishable food and plants',
      'Original documents and IDs',
    ],
  },
  'roundTrip': {'on': false, 'returnPct': 80, 'freeWait': 15, 'waitPerMin': 0.5, 'maxWait': 120},
  'stairs': {'on': false, 'perFloor': 15, 'maxFloors': 10, 'helperFrom': 3},
  'cold': {
    'on': false,
    'levels': [
      {'id': 'chilled', 'name': 'Chilled 0 to 8 °C', 'charge': 60},
      {'id': 'frozen', 'name': 'Frozen -18 °C', 'charge': 90},
    ],
  },
  'cod': {'on': false, 'pct': 2, 'min': 1, 'max': 1000, 'carry': 1000},
};

/// [base] with each add-on's fields that [over] sets laid over it.
Map<String, Map<String, Object?>> mergeAddonValues(Map<String, Map<String, Object?>> base, Object? over) => {
  for (final e in base.entries)
    e.key: {...e.value, if (over is Map && over[e.key] is Map) ...Map<String, Object?>.from(over[e.key] as Map)},
};

double _n(Object? v) => v is num && v.isFinite ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

/// A temperature level of the cold truck.
class ColdLevel {
  const ColdLevel({required this.id, required this.name, required this.charge});
  final String id, name;
  final double charge;

  factory ColdLevel.fromJson(Map m) => ColdLevel(id: '${m['id'] ?? ''}', name: '${m['name'] ?? ''}', charge: _n(m['charge']));

  Map<String, Object> toJson() => {'id': id, 'name': name, 'charge': charge};
}

/// An id for a new level named [name], not among [taken].
String coldLevelId(String name, Iterable<String> taken) {
  var base = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (base.isEmpty) base = 'level';
  if (base.length > 34) base = base.substring(0, 34);
  var id = base;
  for (var i = 2; taken.contains(id); i++) {
    id = '$base-$i';
  }
  return id;
}

/// What holds at a place: every add-on with every field.
class DeliveryAddons {
  const DeliveryAddons(this.values);

  /// The built-in values alone.
  static final builtIn = DeliveryAddons(mergeAddonValues(_defaults, null));

  static Map<String, Map<String, Object?>> get _defaults => {
    for (final e in deliveryAddonDefaults.entries) e.key: Map<String, Object?>.from(e.value),
  };

  /// From the server's merged JSON (addon_terms); the built-in values fill
  /// what it lacks.
  factory DeliveryAddons.fromJson(Object? raw) => DeliveryAddons(mergeAddonValues(_defaults, raw));

  final Map<String, Map<String, Object?>> values;

  Map<String, Object?> group(DeliveryAddon a) => values[a.key] ?? const {};
  double num(DeliveryAddon a, String field) => _n(group(a)[field]);
  bool on(DeliveryAddon a) => group(a)['on'] == true;

  // Parcel cover.
  double get coverPct => num(DeliveryAddon.cover, 'pct');
  double get coverMin => num(DeliveryAddon.cover, 'min');
  double get coverMax => num(DeliveryAddon.cover, 'max');
  int get claimDays => num(DeliveryAddon.cover, 'claimDays').round();
  List<String> get excluded => [
    if (group(DeliveryAddon.cover)['excluded'] case final List l)
      for (final i in l)
        if ('$i'.trim().isNotEmpty) '$i'.trim(),
  ];

  // Round trip.
  double get returnPct => num(DeliveryAddon.roundTrip, 'returnPct');
  double get freeWait => num(DeliveryAddon.roundTrip, 'freeWait');
  double get waitPerMin => num(DeliveryAddon.roundTrip, 'waitPerMin');
  double get maxWait => num(DeliveryAddon.roundTrip, 'maxWait');

  // Stairs.
  double get perFloor => num(DeliveryAddon.stairs, 'perFloor');
  int get maxFloors => num(DeliveryAddon.stairs, 'maxFloors').round();
  int get helperFrom => num(DeliveryAddon.stairs, 'helperFrom').round();

  // Cold truck.
  List<ColdLevel> get coldLevels => [
    if (group(DeliveryAddon.cold)['levels'] case final List l)
      for (final m in l)
        if (m is Map) ColdLevel.fromJson(m),
  ];
  ColdLevel? coldLevel(String? id) => id == null ? null : coldLevels.where((l) => l.id == id).firstOrNull;

  // Cash on delivery.
  double get codPct => num(DeliveryAddon.cod, 'pct');
  double get codMin => num(DeliveryAddon.cod, 'min');
  double get codMax => num(DeliveryAddon.cod, 'max');
  double get codCarry => num(DeliveryAddon.cod, 'carry');

  /// The add-ons switched on here for a Freight ([freight]) or Courier booking.
  List<DeliveryAddon> offered({required bool freight}) => [
    for (final a in DeliveryAddon.values)
      if (a.forKind(freight: freight) && on(a)) a,
  ];
}

/// One rule as stored: its place and the values it sets.
class AddonRule {
  const AddonRule({this.scope = RegionScope.all, this.values = const {}, this.id});

  final String? id;
  final RegionScope scope;

  /// Only what this rule sets, by add-on then field.
  final Map<String, Map<String, Object?>> values;

  static String _s(Object? v) => v is String ? v.trim() : '';

  factory AddonRule.fromRow(Map<String, dynamic> r) {
    final v = r['values'];
    return AddonRule(
      id: r['id'] as String?,
      scope: RegionScope(country: _s(r['country']), state: _s(r['state']), city: _s(r['city']), suburb: _s(r['suburb'])),
      values: {
        if (v is Map)
          for (final e in v.entries)
            if (e.value is Map) '${e.key}': Map<String, Object?>.from(e.value as Map),
      },
    );
  }

  Map<String, Object?> toRow() => {
    'level': scope.level,
    'country': scope.country.isEmpty ? null : scope.country,
    'state': scope.state.isEmpty ? null : scope.state,
    'city': scope.city.isEmpty ? null : scope.city,
    'suburb': scope.suburb.isEmpty ? null : scope.suburb,
    'values': values,
  };

  bool sets(DeliveryAddon a, String field) => values[a.key]?.containsKey(field) ?? false;
  bool setsAny(DeliveryAddon a) => values[a.key]?.isNotEmpty ?? false;

  /// With [field] of [a] set to [value]; null takes it out (it then follows
  /// the rule above).
  AddonRule withField(DeliveryAddon a, String field, Object? value) {
    final g = {...?values[a.key]};
    if (value == null) {
      g.remove(field);
    } else {
      g[field] = value;
    }
    final next = {...values};
    if (g.isEmpty) {
      next.remove(a.key);
    } else {
      next[a.key] = g;
    }
    return AddonRule(id: id, scope: scope, values: next);
  }

  /// With everything this rule sets for [a] taken out.
  AddonRule cleared(DeliveryAddon a) => AddonRule(id: id, scope: scope, values: {...values}..remove(a.key));
}

/// Every rule, as the rider's sheet and the admin page read them.
class AddonRules {
  const AddonRules(this.rows);
  static const none = AddonRules([]);
  final List<AddonRule> rows;

  AddonRule at(RegionScope scope) =>
      rows.where((r) => r.scope.key == scope.key).firstOrNull ?? AddonRule(scope: scope);

  /// What holds at [place]: the built-in values, then Default down to it.
  DeliveryAddons here(RegionScope place) {
    var v = DeliveryAddons.builtIn.values;
    for (final s in place.chain.reversed) {
      v = mergeAddonValues(v, at(s).values);
    }
    return DeliveryAddons(v);
  }

  /// The rule above [scope] whose value [a].[field] holds there; null for
  /// the built-in one.
  RegionScope? fromWhere(RegionScope scope, DeliveryAddon a, String field) {
    for (final s in scope.chain) {
      if (at(s).sets(a, field)) return s;
    }
    return null;
  }
}

// ---- The amounts (each to the cent, as the server) ----------------------------------------------

double coverPremium(double declared, DeliveryAddons a) =>
    cents(_max(a.coverMin, (declared < 0 ? 0 : declared) * a.coverPct / 100));

double returnLegCharge(double outward, DeliveryAddons a) => cents((outward < 0 ? 0 : outward) * a.returnPct / 100);

/// The wait at the drop-off past the free minutes, at most the longest wait.
double returnWaitFee(int minutes, DeliveryAddons a) {
  final m = minutes < 0 ? 0.0 : minutes.toDouble();
  final charged = (m > a.maxWait ? a.maxWait : m) - a.freeWait;
  return cents((charged < 0 ? 0 : charged) * a.waitPerMin);
}

double stairsCharge(int pickup, int drop, DeliveryAddons a) => cents((pickup + drop) * a.perFloor);

/// The COD fee kept from the sender's payout: pct, at least min, never more
/// than the amount.
double codFee(double amount, DeliveryAddons a) {
  final x = amount < 0 ? 0.0 : amount;
  final fee = cents(_max(a.codMin, x * a.codPct / 100));
  return fee > x ? x : fee;
}

double codPayout(double amount, DeliveryAddons a) => cents(amount - codFee(amount, a));

double _max(double a, double b) => a > b ? a : b;

// ---- A booking ------------------------------------------------------------------------------------

/// What the sender picked.
class AddonPicks {
  const AddonPicks({
    this.cover = false,
    this.roundTrip = false,
    this.stairsPickup = 0,
    this.stairsDrop = 0,
    this.coldLevel,
    this.cod,
  });

  final bool cover, roundTrip;
  final int stairsPickup, stairsDrop;
  final String? coldLevel;

  /// The cash for the item; null for none.
  final double? cod;

  bool get any => cover || roundTrip || stairsPickup + stairsDrop > 0 || coldLevel != null || cod != null;

  AddonPicks copyWith({
    bool? cover,
    bool? roundTrip,
    int? stairsPickup,
    int? stairsDrop,
    String? Function()? coldLevel,
    double? Function()? cod,
  }) => AddonPicks(
    cover: cover ?? this.cover,
    roundTrip: roundTrip ?? this.roundTrip,
    stairsPickup: stairsPickup ?? this.stairsPickup,
    stairsDrop: stairsDrop ?? this.stairsDrop,
    coldLevel: coldLevel == null ? this.coldLevel : coldLevel(),
    cod: cod == null ? this.cod : cod(),
  );

  /// Only what [a] offers for the kind: the rest dropped.
  AddonPicks offeredBy(DeliveryAddons a, {required bool freight}) {
    final off = a.offered(freight: freight).toSet();
    final level = coldLevel != null && a.coldLevel(coldLevel) != null ? coldLevel : null;
    return AddonPicks(
      cover: cover && off.contains(DeliveryAddon.cover),
      roundTrip: roundTrip && off.contains(DeliveryAddon.roundTrip),
      stairsPickup: off.contains(DeliveryAddon.stairs) ? stairsPickup : 0,
      stairsDrop: off.contains(DeliveryAddon.stairs) ? stairsDrop : 0,
      coldLevel: off.contains(DeliveryAddon.cold) ? level : null,
      cod: off.contains(DeliveryAddon.cod) ? cod : null,
    );
  }

  /// As kept on the ride (`ride_requests` columns, migration 0312).
  Map<String, Object> toColumns() => {
    if (cover) 'parcel_cover': true,
    if (roundTrip) 'round_trip': true,
    if (stairsPickup > 0) 'stairs_pickup': stairsPickup,
    if (stairsDrop > 0) 'stairs_drop': stairsDrop,
    'cold_level': ?coldLevel,
    'cod_amount': ?cod,
  };

  Map<String, Object> toJson() => toColumns();

  factory AddonPicks.fromJson(Object? raw) {
    if (raw is! Map) return const AddonPicks();
    final cod = raw['cod_amount'];
    return AddonPicks(
      cover: raw['parcel_cover'] == true,
      roundTrip: raw['round_trip'] == true,
      stairsPickup: _n(raw['stairs_pickup']).round(),
      stairsDrop: _n(raw['stairs_drop']).round(),
      coldLevel: raw['cold_level'] is String ? raw['cold_level'] as String : null,
      cod: cod is num ? cod.toDouble() : null,
    );
  }
}

/// The lines the add-ons add to [offer] (the rider's offer, before any
/// option): the cover premium on [declared], the return leg, the stairs and
/// the cold truck. Cash on delivery adds none: its fee comes off the payout.
List<OptionChargeLine> addonLines(AddonPicks p, DeliveryAddons a, {required double offer, double? declared}) {
  final floors = p.stairsPickup + p.stairsDrop;
  final level = a.coldLevel(p.coldLevel);
  return [
    if (p.cover) OptionChargeLine(kind: AddonLineKind.cover, name: 'Parcel cover', amount: coverPremium(declared ?? 0, a)),
    if (p.roundTrip)
      OptionChargeLine(kind: AddonLineKind.roundTrip, name: 'Return leg', amount: returnLegCharge(offer, a)),
    if (floors > 0)
      OptionChargeLine(
        kind: AddonLineKind.stairs,
        name: 'Stairs, $floors ${floors == 1 ? 'floor' : 'floors'}',
        amount: stairsCharge(p.stairsPickup, p.stairsDrop, a),
      ),
    if (level != null) OptionChargeLine(kind: AddonLineKind.cold, name: _cut('Cold truck, ${level.name}'), amount: cents(level.charge)),
  ];
}

String _cut(String s) => s.length <= 60 ? s : s.substring(0, 60);

/// Why the add-ons can't be booked as they are, in the server's words;
/// null when they can.
String? addonPicksProblem(
  AddonPicks p,
  DeliveryAddons a, {
  required bool freight,
  double? declared,
  bool refrigerated = false,
  bool hasHelper = false,
  String Function(double)? money,
}) {
  String m(double v) => money?.call(v) ?? trimNumber(v);
  if (!p.any) return null;
  if (p.cover) {
    if (!a.on(DeliveryAddon.cover)) return "Parcel cover isn't offered here.";
    if (declared == null || declared <= 0) return 'Enter the value of your items to cover them.';
    if (declared > a.coverMax) return 'Parcel cover goes up to ${m(a.coverMax)} here.';
  }
  if (p.roundTrip && !a.on(DeliveryAddon.roundTrip)) return "Round trip isn't offered here.";
  final floors = p.stairsPickup > p.stairsDrop ? p.stairsPickup : p.stairsDrop;
  if (p.stairsPickup + p.stairsDrop > 0) {
    if (!freight) return 'Stairs are for Freight only.';
    if (!a.on(DeliveryAddon.stairs)) return "Stairs aren't offered here.";
    if (floors > a.maxFloors) return 'At most ${a.maxFloors} floors without a lift at each end here.';
    if (a.helperFrom > 0 && floors >= a.helperFrom && !hasHelper) {
      return 'From ${a.helperFrom} floors without a lift, add a helper.';
    }
  }
  if (p.coldLevel != null) {
    if (!freight) return 'The cold truck is for Freight only.';
    if (!a.on(DeliveryAddon.cold)) return "The cold truck isn't offered here.";
    if (a.coldLevel(p.coldLevel) == null) return "That temperature isn't offered here.";
    if (!refrigerated) return 'Choose a refrigerated vehicle for the cold truck.';
  }
  if (p.cod != null) {
    if (freight) return 'Cash on delivery for the item is for Courier only.';
    if (!a.on(DeliveryAddon.cod)) return "Cash on delivery isn't offered here.";
    if (p.cod! <= 0) return 'Enter the cash the courier collects for the item.';
    if (p.cod! > a.codMax) return 'Cash on delivery goes up to ${m(a.codMax)} a parcel here.';
  }
  return null;
}

/// "1% of the declared value, min RM 2, up to RM 5,000".
String coverNote(DeliveryAddons a, String Function(double) money) =>
    '${trimNumber(a.coverPct)}% of the declared value, min ${money(a.coverMin)}, up to ${money(a.coverMax)}';

/// "The recipient pays the driver; it reaches your GET.wallet less 2% (min RM 1)".
String codNote(DeliveryAddons a, String Function(double) money) =>
    'The recipient pays the driver; it reaches your GET.wallet less ${trimNumber(a.codPct)}% (min ${money(a.codMin)})';

/// "Back to the pickup after the drop-off, 20% off the fare".
String roundTripNote(DeliveryAddons a) {
  final off = 100 - a.returnPct;
  final price = off > 0 ? '${trimNumber(off)}% off the way there' : 'at the fare of the way there';
  return 'Back to the pickup after the drop-off, $price. For example, return the empty crates or the signed papers';
}

/// "Wait at drop-off, first 15 min free".
String returnWaitLabel(DeliveryAddons a) => 'Wait at drop-off, first ${trimNumber(a.freeWait)} min free';

/// "then RM 0.50 a minute, up to 120 min".
String returnWaitRule(DeliveryAddons a, String Function(double) money) => a.waitPerMin > 0
    ? 'then ${money(a.waitPerMin)} a minute, up to ${trimNumber(a.maxWait)} min'
    : 'no charge after';

/// The Booking board's breakdown: the trip, each line, the wait at the
/// drop-off and the cash on delivery, then what the sender pays.
typedef BreakdownLine = ({String label, String value});

({List<BreakdownLine> lines, double total}) addonBreakdown({
  required String tripLabel,
  required double offer,
  required List<OptionChargeLine> lines,
  required AddonPicks picks,
  required DeliveryAddons a,
  required String Function(double) money,
}) {
  final out = <BreakdownLine>[
    (label: tripLabel, value: money(offer)),
    for (final l in lines)
      if (l.kind == AddonLineKind.roundTrip)
        (label: a.returnPct < 100 ? 'Return leg (${trimNumber(100 - a.returnPct)}% off)' : 'Return leg', value: money(l.amount))
      else
        (label: l.name, value: money(l.amount)),
    if (picks.roundTrip) (label: returnWaitLabel(a), value: money(0)),
    if (picks.cod case final c?) (label: 'COD: recipient pays ${money(c)}', value: 'to you, less ${money(codFee(c, a))}'),
  ];
  return (lines: out, total: cents(offer + optionChargesTotal(lines)));
}

// ---- A booked ride ------------------------------------------------------------------------------

/// The add-ons on a ride as the server keeps them.
class RideAddons {
  const RideAddons({
    this.picks = const AddonPicks(),
    this.terms,
    this.codFee,
    this.codStatus,
    this.returnArrivedAt,
    this.returnStartedAt,
    this.returnWaitMinutes,
    this.returnWaitFee,
    this.returnLegFare,
  });

  factory RideAddons.fromRow(Map<String, dynamic> r) {
    DateTime? t(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();
    double? d(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    return RideAddons(
      picks: AddonPicks.fromJson(r),
      terms: r['addon_terms'] is Map ? DeliveryAddons.fromJson(r['addon_terms']) : null,
      codFee: d(r['cod_fee']),
      codStatus: r['cod_status'] as String?,
      returnArrivedAt: t(r['return_arrived_at']),
      returnStartedAt: t(r['return_started_at']),
      returnWaitMinutes: d(r['return_wait_minutes'])?.round(),
      returnWaitFee: d(r['return_wait_fee']),
      returnLegFare: d(r['return_leg_fare']),
    );
  }

  final AddonPicks picks;
  final DeliveryAddons? terms;
  final double? codFee;

  /// 'pending', 'collected' or 'refused'.
  final String? codStatus;
  final DateTime? returnArrivedAt, returnStartedAt;
  final int? returnWaitMinutes;
  final double? returnWaitFee, returnLegFare;

  DeliveryAddons get rule => terms ?? DeliveryAddons.builtIn;
  bool get any => picks.any;
  bool get codPending => picks.cod != null && codStatus == 'pending';
  bool get codRefused => codStatus == 'refused';
  bool get codCollected => codStatus == 'collected';

  /// Heading back: a round trip's return leg, or a parcel the recipient
  /// wouldn't pay for.
  bool get returning => returnStartedAt != null;

  /// Where the driver is on the trip's legs.
  ReturnLegStep get step {
    if (!picks.roundTrip && !codRefused) return ReturnLegStep.none;
    if (returnStartedAt != null) return ReturnLegStep.returning;
    if (returnArrivedAt != null) return ReturnLegStep.waiting;
    return ReturnLegStep.outward;
  }
}

enum ReturnLegStep { none, outward, waiting, returning }

/// The minutes waited since [arrivedAt].
int waitedMinutes(DateTime arrivedAt, DateTime now) {
  final m = now.difference(arrivedAt).inMinutes;
  return m < 0 ? 0 : m;
}

/// The last day a claim can be filed: [claimDays] after the trip ended.
DateTime claimDeadline(DateTime ended, int claimDays) => ended.add(Duration(days: claimDays));

/// Whether a covered ride that ended at [ended] can still be claimed on.
bool claimOpen({required bool covered, required DateTime? ended, required int claimDays, required DateTime now}) =>
    covered && ended != null && !now.isAfter(claimDeadline(ended, claimDays));

/// Why a claim of [amount] for [reason] can't be filed; null when it can.
String? claimProblem(double? amount, String reason, double declared, String Function(double) money) {
  if (amount == null || amount <= 0) return 'Enter the amount to claim.';
  if (amount > declared) return 'Claim up to the declared value, ${money(declared)}.';
  if (reason.trim().length < 5) return 'Say what happened.';
  return null;
}

/// A parcel cover claim (`cover_claims`).
class CoverClaim {
  const CoverClaim({
    required this.id,
    required this.rideId,
    required this.amount,
    required this.declaredValue,
    required this.reason,
    required this.status,
    this.service,
    this.currency = 'RM',
    this.paidAmount,
    this.adminNote,
    this.createdAt,
  });

  factory CoverClaim.fromRow(Map<String, dynamic> r) => CoverClaim(
    id: '${r['id']}',
    rideId: '${r['ride_id']}',
    amount: _n(r['amount']),
    declaredValue: _n(r['declared_value']),
    reason: '${r['reason'] ?? ''}',
    status: '${r['status'] ?? 'open'}',
    service: r['service'] as String?,
    currency: (r['currency'] as String?) ?? 'RM',
    paidAmount: r['paid_amount'] == null ? null : _n(r['paid_amount']),
    adminNote: r['admin_note'] as String?,
    createdAt: DateTime.tryParse('${r['created_at'] ?? ''}')?.toLocal(),
  );

  final String id, rideId, reason, status, currency;
  final String? service, adminNote;
  final double amount, declaredValue;
  final double? paidAmount;
  final DateTime? createdAt;

  bool get open => status == 'open';

  String get statusLabel => switch (status) {
    'approved' => 'Approved',
    'rejected' => 'Not approved',
    _ => 'Waiting for a decision',
  };
}

// ---- The admin page's steppers -------------------------------------------------------------------

/// How a value reads on the admin page.
enum AddonUnit { percent, money, minutes, count, days }

/// One stepper of an add-on's card (Admin board).
class AddonField {
  const AddonField(this.key, this.label, this.unit, this.step, this.min, this.max);
  final String key, label;
  final AddonUnit unit;
  final double step, min, max;

  String format(double v, String Function(double) money) => switch (unit) {
    AddonUnit.percent => '${trimNumber(v)}%',
    AddonUnit.money => money(v),
    AddonUnit.minutes => '${trimNumber(v)} min',
    AddonUnit.days => '${trimNumber(v)} ${v == 1 ? 'day' : 'days'}',
    AddonUnit.count => trimNumber(v),
  };

  /// [v] moved one step up or down, kept within the bounds; null when it
  /// can't move.
  double? stepped(double v, {required bool up}) {
    final next = ((up ? v + step : v - step) * 100).roundToDouble() / 100;
    if (next < min - 1e-9 || next > max + 1e-9) return null;
    return next;
  }
}

/// The steppers of each add-on (the list fields, excluded items and
/// temperature levels, are edited apart).
const addonFields = <DeliveryAddon, List<AddonField>>{
  DeliveryAddon.cover: [
    AddonField('pct', 'Premium, % of value', AddonUnit.percent, 0.5, 0, 100),
    AddonField('min', 'Lowest premium', AddonUnit.money, 1, 0, 100000),
    AddonField('max', 'Highest value covered', AddonUnit.money, 500, 0, 1000000),
    AddonField('claimDays', 'Days to claim', AddonUnit.days, 1, 1, 365),
  ],
  DeliveryAddon.roundTrip: [
    AddonField('returnPct', 'Return leg, % of the fare', AddonUnit.percent, 5, 0, 100),
    AddonField('freeWait', 'Free wait at drop-off', AddonUnit.minutes, 5, 0, 1440),
    AddonField('waitPerMin', 'Then per minute', AddonUnit.money, 0.1, 0, 10000),
    AddonField('maxWait', 'Longest wait', AddonUnit.minutes, 15, 0, 1440),
  ],
  DeliveryAddon.stairs: [
    AddonField('perFloor', 'Per floor without a lift', AddonUnit.money, 1, 0, 100000),
    AddonField('maxFloors', 'Most floors each end', AddonUnit.count, 1, 0, 200),
    AddonField('helperFrom', 'Needs a helper from floor', AddonUnit.count, 1, 0, 200),
  ],
  DeliveryAddon.cold: [],
  DeliveryAddon.cod: [
    AddonField('pct', 'COD fee, %', AddonUnit.percent, 0.5, 0, 100),
    AddonField('min', 'Lowest COD fee', AddonUnit.money, 1, 0, 100000),
    AddonField('max', 'Highest COD per parcel', AddonUnit.money, 100, 0, 1000000),
    AddonField('carry', 'Most cash a driver carries', AddonUnit.money, 100, 0, 1000000),
  ],
};

/// [items] with [item] added once (no case-only repeats); blank is ignored.
List<String> withExcludedItem(List<String> items, String item) {
  final t = item.trim();
  if (t.isEmpty || t.length > 120 || items.any((i) => i.toLowerCase() == t.toLowerCase())) return items;
  return [...items, t];
}
