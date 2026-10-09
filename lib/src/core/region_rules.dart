// Scheduled region rules (Admin → Country / States / Cities → Rules): when a
// service is offered, when riders and drivers may bid, which taxes and which
// surcharges apply — each for some services, at some times. Pure.
//
// A rule says what holds *during its schedule*, for its services:
//
//   availability  the service is on (or off)        e.g. Food on 10:00–22:00
//   bidding       OfferMe is on (or off)            e.g. off on public holidays
//   tax           a tax is added                    e.g. SST 8 %, Premium only
//   surcharge     a surcharge is added              e.g. RM5 midnight–06:00
//
// Outside its schedule a rule does nothing, and the region's plain switches
// (Services, Bidding, Tax) decide as before. Services are named two ways,
// as the admin chose: a category from Service Settings (Car, Bike, Delivery,
// …) covers every vehicle type in it; a vehicle type (Ride, Premium, …) is
// just that one. A rule naming neither covers every service.
//
// Which region's rules count: the most specific region around the pickup
// that has a matching rule of that kind (suburb → city → state → country),
// the way every other region setting is chosen; within one region a rule
// for the vehicle type beats one for its category, which beats one for
// every service, and the later of two equals wins. Taxes and surcharges are
// lists: all the matching ones of the deciding region apply.
//
// Times are the region's local time (its Time zone field), so a rule reads
// the same wherever the admin or the phone is.
import 'dart:convert';

enum RuleKind {
  availability('availability', 'Service hours'),
  bidding('bidding', 'Bidding (OfferMe)'),
  tax('tax', 'Tax'),
  surcharge('surcharge', 'Surcharge');

  const RuleKind(this.id, this.label);
  final String id;
  final String label;

  bool get isCharge => this == RuleKind.tax || this == RuleKind.surcharge;

  static RuleKind? fromId(Object? id) => values.where((k) => k.id == id).firstOrNull;
}

enum ScheduleMode {
  always('always', 'Always'),
  days('days', 'Days of the week'),
  dates('dates', 'Dates');

  const ScheduleMode(this.id, this.label);
  final String id;
  final String label;

  static ScheduleMode fromId(Object? id) => values.where((m) => m.id == id).firstOrNull ?? ScheduleMode.always;
}

/// When a rule holds: always; on some days of the week; or between two
/// dates — in each case all day, or between two times (which may run past
/// midnight: 22:00–06:00).
class RuleSchedule {
  const RuleSchedule({
    this.mode = ScheduleMode.always,
    this.days = const {},
    this.from,
    this.to,
    this.allDay = true,
    this.start = 0,
    this.end = 0,
  });

  static const always = RuleSchedule();

  final ScheduleMode mode;

  /// ISO weekdays, 1 Monday … 7 Sunday ([ScheduleMode.days]).
  final Set<int> days;

  /// First and last day, inclusive ([ScheduleMode.dates]); either may be open.
  final DateTime? from, to;

  /// All day, else [start]–[end] minutes after midnight.
  final bool allDay;
  final int start, end;

  /// Whether it holds at [local], the region's wall-clock time.
  bool matches(DateTime local) {
    final minute = local.hour * 60 + local.minute;
    final day = DateTime(local.year, local.month, local.day);
    // A window past midnight (22:00–06:00) belongs, before 06:00, to the
    // day it started on.
    final overnight = !allDay && end <= start;
    final inWindow = allDay || (overnight ? (minute >= start || minute < end) : (minute >= start && minute < end));
    if (!inWindow) return false;
    final windowDay = overnight && minute < end ? day.subtract(const Duration(days: 1)) : day;
    switch (mode) {
      case ScheduleMode.always:
        return true;
      case ScheduleMode.days:
        return days.contains(windowDay.weekday);
      case ScheduleMode.dates:
        final f = from, t = to;
        if (f != null && windowDay.isBefore(DateTime(f.year, f.month, f.day))) return false;
        if (t != null && windowDay.isAfter(DateTime(t.year, t.month, t.day))) return false;
        return true;
    }
  }

  static String _hm(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// "Always", "Mon–Fri · 07:00–09:00", "1 Dec–31 Dec · all day".
  String get label {
    final time = allDay ? 'all day' : '${_hm(start)}–${_hm(end)}';
    switch (mode) {
      case ScheduleMode.always:
        return allDay ? 'Always' : 'Every day · $time';
      case ScheduleMode.days:
        final sorted = days.toList()..sort();
        final contiguous = sorted.length > 2 && sorted.last - sorted.first == sorted.length - 1;
        final names = contiguous
            ? '${_dayNames[sorted.first - 1]}–${_dayNames[sorted.last - 1]}'
            : sorted.map((d) => _dayNames[d - 1]).join(', ');
        return '${names.isEmpty ? 'No days' : names} · $time';
      case ScheduleMode.dates:
        final f = from == null ? '…' : _date(from!);
        final t = to == null ? '…' : _date(to!);
        return '$f to $t · $time';
    }
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.id,
    if (mode == ScheduleMode.days) 'days': (days.toList()..sort()),
    if (mode == ScheduleMode.dates && from != null) 'from': _date(from!),
    if (mode == ScheduleMode.dates && to != null) 'to': _date(to!),
    'allDay': allDay,
    if (!allDay) 'start': _hm(start),
    if (!allDay) 'end': _hm(end),
  };

  static int? _minutes(Object? raw) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch('${raw ?? ''}'.trim());
    if (m == null) return null;
    final h = int.parse(m.group(1)!), mi = int.parse(m.group(2)!);
    return h < 24 && mi < 60 ? h * 60 + mi : null;
  }

  static RuleSchedule fromJson(Object? raw) {
    if (raw is! Map) return always;
    final start = _minutes(raw['start']), end = _minutes(raw['end']);
    final timed = raw['allDay'] == false && start != null && end != null && start != end;
    return RuleSchedule(
      mode: ScheduleMode.fromId(raw['mode']),
      days: {
        if (raw['days'] is List)
          for (final d in raw['days'] as List)
            if (d is num && d >= 1 && d <= 7) d.toInt(),
      },
      from: DateTime.tryParse('${raw['from'] ?? ''}'),
      to: DateTime.tryParse('${raw['to'] ?? ''}'),
      allDay: !timed,
      start: timed ? start : 0,
      end: timed ? end : 0,
    );
  }
}

/// The services a rule covers: none named means every service.
class RuleTarget {
  const RuleTarget({this.categories = const {}, this.vehicleTypes = const {}});

  static const everything = RuleTarget();

  /// Service Settings entry ids (Car, Bike, Delivery, …).
  final Set<String> categories;

  /// Vehicle Services entry ids (Ride, Comfort, Premium, …).
  final Set<String> vehicleTypes;

  bool get isEverything => categories.isEmpty && vehicleTypes.isEmpty;

  /// How closely it names a service — a vehicle type ([vehicleType]) in
  /// some Service Settings types ([categories], ids): 2 the vehicle type,
  /// 1 one of its types, 0 every service; null when it does not cover it.
  int? specificityFor({Set<String> categories = const {}, String? vehicleType}) {
    if (vehicleType != null && vehicleTypes.contains(vehicleType)) return 2;
    if (categories.any(this.categories.contains)) return 1;
    return isEverything ? 0 : null;
  }

  Map<String, dynamic> toJson() => {
    if (categories.isNotEmpty) 'categories': (categories.toList()..sort()),
    if (vehicleTypes.isNotEmpty) 'vehicleTypes': (vehicleTypes.toList()..sort()),
  };

  static Set<String> _ids(Object? raw) => {
    if (raw is List)
      for (final x in raw)
        if ('$x'.trim().isNotEmpty) '$x'.trim(),
  };

  static RuleTarget fromJson(Object? raw) => raw is Map
      ? RuleTarget(categories: _ids(raw['categories']), vehicleTypes: _ids(raw['vehicleTypes']))
      : everything;
}

enum ChargeKind {
  percent('percent'),
  fixed('fixed');

  const ChargeKind(this.id);
  final String id;

  static ChargeKind fromId(Object? id) => id == 'fixed' ? ChargeKind.fixed : ChargeKind.percent;
}

class RegionRule {
  const RegionRule({
    required this.id,
    required this.kind,
    this.on = true,
    this.target = RuleTarget.everything,
    this.schedule = RuleSchedule.always,
    this.name = '',
    this.charge = ChargeKind.percent,
    this.amount = 0,
    this.enabled = true,
  });

  final String id;
  final RuleKind kind;

  /// Availability / bidding: on or off while the rule holds.
  final bool on;
  final RuleTarget target;
  final RuleSchedule schedule;

  /// Tax / surcharge: what the line is called ("SST", "Midnight surcharge").
  final String name;
  final ChargeKind charge;
  final double amount;

  /// The admin can park a rule without deleting it.
  final bool enabled;

  /// The amount of this charge on [fare].
  double chargeOn(double fare) => charge == ChargeKind.percent ? fare * amount / 100 : amount;

  /// "SST 8%", "Night surcharge RM5.00" (with [currency] for fixed ones).
  String chargeLabel([String currency = '']) {
    final n = name.trim().isEmpty ? kind.label : name.trim();
    if (charge == ChargeKind.percent) {
      final a = amount == amount.roundToDouble() ? amount.toStringAsFixed(0) : '$amount';
      return '$n $a%';
    }
    return '$n $currency${amount.toStringAsFixed(2)}';
  }

  RegionRule copyWith({
    bool? on,
    RuleTarget? target,
    RuleSchedule? schedule,
    String? name,
    ChargeKind? charge,
    double? amount,
    bool? enabled,
  }) => RegionRule(
    id: id,
    kind: kind,
    on: on ?? this.on,
    target: target ?? this.target,
    schedule: schedule ?? this.schedule,
    name: name ?? this.name,
    charge: charge ?? this.charge,
    amount: amount ?? this.amount,
    enabled: enabled ?? this.enabled,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.id,
    if (!kind.isCharge) 'on': on,
    'target': target.toJson(),
    'schedule': schedule.toJson(),
    if (kind.isCharge) 'name': name.trim(),
    if (kind.isCharge) 'charge': charge.id,
    if (kind.isCharge) 'amount': amount,
    if (!enabled) 'enabled': false,
  };

  static RegionRule? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = RuleKind.fromId(raw['kind']);
    final id = '${raw['id'] ?? ''}';
    if (kind == null || id.isEmpty) return null;
    final amount = raw['amount'] is num ? (raw['amount'] as num).toDouble() : double.tryParse('${raw['amount']}');
    if (kind.isCharge && (amount == null || amount < 0)) return null;
    return RegionRule(
      id: id,
      kind: kind,
      on: raw['on'] != false,
      target: RuleTarget.fromJson(raw['target']),
      schedule: RuleSchedule.fromJson(raw['schedule']),
      name: '${raw['name'] ?? ''}',
      charge: ChargeKind.fromId(raw['charge']),
      amount: amount ?? 0,
      enabled: raw['enabled'] != false,
    );
  }
}

/// A region's rules as stored in its `values['rules']` (a list, or the JSON
/// of one); unreadable entries are skipped.
List<RegionRule> parseRegionRules(Object? raw) {
  Object? list = raw;
  if (raw is String) {
    if (raw.trim().isEmpty) return const [];
    try {
      list = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
  }
  if (list is! List) return const [];
  return [for (final r in list) ?RegionRule.fromJson(r)];
}

List<Map<String, dynamic>> encodeRegionRules(List<RegionRule> rules) => [for (final r in rules) r.toJson()];

/// Why [r] cannot be saved, or null.
String? regionRuleProblem(RegionRule r) {
  final s = r.schedule;
  if (s.mode == ScheduleMode.days && s.days.isEmpty) return 'Pick at least one day.';
  if (s.mode == ScheduleMode.dates && s.from == null && s.to == null) return 'Pick a start or an end date.';
  if (s.mode == ScheduleMode.dates && s.from != null && s.to != null && s.to!.isBefore(s.from!)) {
    return 'The end date is before the start date.';
  }
  if (!s.allDay && s.start == s.end) return 'The start and end times are the same.';
  if (r.kind.isCharge) {
    if (r.name.trim().isEmpty) return 'Give the ${r.kind == RuleKind.tax ? 'tax' : 'surcharge'} a name.';
    if (!(r.amount > 0)) return 'Enter an amount above zero.';
    if (r.charge == ChargeKind.percent && r.amount > 100) return 'A percentage cannot be over 100.';
  }
  return null;
}

/// The rules of one region around the pickup, with its specificity
/// (3 suburb … 0 country): what [resolveRules] chooses among.
typedef RegionRules = ({int specificity, List<RegionRule> rules});

/// What the rules say for one service at one moment.
class RuleOutcome {
  const RuleOutcome({this.available, this.bidding, this.taxes = const [], this.surcharges = const []});

  /// Null when no rule decides (the region's switches do).
  final bool? available;
  final bool? bidding;

  /// Null when no rule decides (the region's plain Tax setting does); else
  /// the taxes that apply, possibly none.
  final List<RegionRule>? taxes;
  final List<RegionRule> surcharges;
}

/// The rules in force for a service ([categories], [vehicleType]) at [local]
/// time, from the regions around the pickup ([chain]).
RuleOutcome resolveRules(
  List<RegionRules> chain, {
  Set<String> categories = const {},
  String? vehicleType,
  required DateTime local,
}) {
  final ordered = [...chain]..sort((a, b) => b.specificity.compareTo(a.specificity));

  List<RegionRule> live(List<RegionRule> rules, RuleKind kind) => [
    for (final r in rules)
      if (r.enabled &&
          r.kind == kind &&
          r.target.specificityFor(categories: categories, vehicleType: vehicleType) != null &&
          r.schedule.matches(local))
        r,
  ];

  /// The deciding switch: the most specific region with a live rule, its
  /// most specific (then latest) one.
  bool? decide(RuleKind kind) {
    for (final region in ordered) {
      final rules = live(region.rules, kind);
      if (rules.isEmpty) continue;
      RegionRule? best;
      var bestSpec = -1;
      for (final r in rules) {
        final spec = r.target.specificityFor(categories: categories, vehicleType: vehicleType)!;
        if (spec >= bestSpec) {
          best = r;
          bestSpec = spec;
        }
      }
      return best!.on;
    }
    return null;
  }

  /// The charges: those of the most specific region that has any for this
  /// service (live or not, so a region's taxes fully replace its parent's).
  List<RegionRule>? charges(RuleKind kind) {
    for (final region in ordered) {
      final defined = [
        for (final r in region.rules)
          if (r.enabled &&
              r.kind == kind &&
              r.target.specificityFor(categories: categories, vehicleType: vehicleType) != null)
            r,
      ];
      if (defined.isEmpty) continue;
      return [
        for (final r in defined)
          if (r.schedule.matches(local)) r,
      ];
    }
    return null;
  }

  return RuleOutcome(
    available: decide(RuleKind.availability),
    bidding: decide(RuleKind.bidding),
    taxes: charges(RuleKind.tax),
    surcharges: charges(RuleKind.surcharge) ?? const [],
  );
}
