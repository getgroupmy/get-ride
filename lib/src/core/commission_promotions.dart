// Commission promotions and reports (migration 0224).
//
// A promotion is a lower rate for a time: from / to, optionally only in a
// country, state or city, for some services ("meter" for meter / TEKSI
// hires), on some days of the week and hours of the day (the ride's own
// clock), or for new drivers in their first N days. When a driver accepts,
// the lowest of the rate after tiers and the promotions that fit wins; a
// personal rate is left as set, as with tiers.
//
// Reports total the commission charged by day, week, month, region or
// driver; the CSV holds the same rows.
import 'package:flutter/foundation.dart';

import '../admin/screens/security/session_logic.dart' show rowsToCsv;

/// The service name a meter / TEKSI hire is matched by.
const meterServiceName = 'meter';

const weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

/// "07:30" or "07:30:00" → minutes after midnight; null when not a time.
int? parseTimeOfDay(Object? v) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch('${v ?? ''}');
  if (m == null) return null;
  final h = int.parse(m[1]!), min = int.parse(m[2]!);
  return h < 24 && min < 60 ? h * 60 + min : null;
}

/// Minutes after midnight → "07:30".
String timeOfDayLabel(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

@immutable
class CommissionPromotion {
  const CommissionPromotion({
    this.id,
    required this.name,
    this.active = true,
    required this.rate,
    required this.startsAt,
    required this.endsAt,
    this.country,
    this.state,
    this.city,
    this.services = const [],
    this.weekdays = const [],
    this.timeFrom,
    this.timeTo,
    this.newDriverDays,
    this.note = '',
  });

  factory CommissionPromotion.fromRow(Map<String, dynamic> r) {
    String? place(Object? v) => '${v ?? ''}'.trim().isEmpty ? null : '$v'.trim();
    final days = r['new_driver_days'];
    return CommissionPromotion(
      id: r['id'] as String?,
      name: '${r['name'] ?? ''}',
      active: r['active'] != false,
      rate: _num(r['rate']),
      startsAt: DateTime.tryParse('${r['starts_at']}')?.toUtc() ?? DateTime.utc(1970),
      endsAt: DateTime.tryParse('${r['ends_at']}')?.toUtc() ?? DateTime.utc(1970),
      country: place(r['country']),
      state: place(r['state']),
      city: place(r['city']),
      services: [
        for (final s in (r['services'] is List ? r['services'] as List : const []))
          if ('$s'.trim().isNotEmpty) '$s'.trim().toLowerCase(),
      ],
      weekdays: [
        for (final d in (r['weekdays'] is List ? r['weekdays'] as List : const []))
          if (d is num && d >= 1 && d <= 7) d.toInt(),
      ]..sort(),
      timeFrom: parseTimeOfDay(r['time_from']),
      timeTo: parseTimeOfDay(r['time_to']),
      newDriverDays: days is num ? days.toInt() : int.tryParse('${days ?? ''}'),
      note: '${r['note'] ?? ''}',
    );
  }

  final String? id;
  final String name;
  final bool active;

  /// A fraction (0.05 is 5%); 0 allowed.
  final double rate;
  final DateTime startsAt;
  final DateTime endsAt;
  final String? country;
  final String? state;
  final String? city;

  /// Lower-case service names; empty: every service.
  final List<String> services;

  /// ISO days, 1 Monday … 7 Sunday; empty: every day.
  final List<int> weekdays;

  /// Minutes after midnight, local to the ride; both or neither.
  final int? timeFrom;
  final int? timeTo;

  /// Only the first N days since the driver joined; null: every driver.
  final int? newDriverDays;
  final String note;

  bool get hasHours => timeFrom != null && timeTo != null;

  /// Running at [now] (on, and between from and to).
  bool runningAt(DateTime now) => active && !startsAt.isAfter(now) && endsAt.isAfter(now);

  /// Off, Scheduled, Running or Ended.
  String statusAt(DateTime now) {
    if (!active) return 'Off';
    if (now.isBefore(startsAt)) return 'Scheduled';
    if (!endsAt.isAfter(now)) return 'Ended';
    return 'Running';
  }

  /// Whether [local] (the ride's clock) is inside the days and hours. A
  /// window like 22:00–06:00 runs past midnight. Pure; mirrors
  /// commission_apply_promotions.
  bool inHours(DateTime local) {
    if (weekdays.isNotEmpty && !weekdays.contains(local.weekday)) return false;
    if (!hasHours) return true;
    final t = local.hour * 60 + local.minute;
    return timeFrom! < timeTo! ? t >= timeFrom! && t < timeTo! : t >= timeFrom! || t < timeTo!;
  }

  /// Whether this promotion fits a trip. [at] is the moment (UTC), [local]
  /// the same moment on the ride's clock, [joined] when the driver joined.
  bool fits({
    required DateTime at,
    required DateTime local,
    String? service,
    String? country,
    String? state,
    String? city,
    DateTime? joined,
  }) {
    bool place(String? rule, String? ride) =>
        rule == null || (ride != null && rule.trim().toLowerCase() == ride.trim().toLowerCase());
    if (!runningAt(at)) return false;
    if (!place(this.country, country) || !place(this.state, state) || !place(this.city, city)) return false;
    if (services.isNotEmpty && !services.contains((service ?? '').trim().toLowerCase())) return false;
    if (!inHours(local)) return false;
    if (newDriverDays != null) {
      if (joined == null || at.isBefore(joined) || !at.isBefore(joined.add(Duration(days: newDriverDays!)))) {
        return false;
      }
    }
    return true;
  }

  /// "5%".
  String get rateLabel {
    final pct = rate * 100;
    return '${pct.toStringAsFixed(pct % 1 == 0 ? 0 : 2)}%';
  }

  /// "Kajang, Selangor, Malaysia" or "Everywhere".
  String get scopeLabel {
    final parts = [city, state, country].whereType<String>().toList();
    return parts.isEmpty ? 'Everywhere' : parts.join(', ');
  }

  /// "Mon–Fri 07:00–10:00", "Sat, Sun", "" for any time.
  String get hoursLabel {
    String days() {
      if (weekdays.isEmpty || weekdays.length == 7) return '';
      final d = [...weekdays]..sort();
      final run = d.length > 2 && d.last - d.first == d.length - 1;
      return run ? '${weekdayNames[d.first - 1]}–${weekdayNames[d.last - 1]}' : d.map((x) => weekdayNames[x - 1]).join(', ');
    }

    return [
      days(),
      if (hasHours) '${timeOfDayLabel(timeFrom!)}–${timeOfDayLabel(timeTo!)}',
    ].where((s) => s.isNotEmpty).join(' ');
  }

  /// "Car, Meter / TEKSI" or "" for every service.
  String get servicesLabel =>
      services.map((s) => s == meterServiceName ? 'Meter / TEKSI' : (s.isEmpty ? s : s[0].toUpperCase() + s.substring(1))).join(', ');

  /// The list line under the name: "5% · Kajang · Mon–Fri 07:00–10:00 · Car · First 30 days".
  String get summary => [
    rateLabel,
    scopeLabel,
    if (hoursLabel.isNotEmpty) hoursLabel,
    if (servicesLabel.isNotEmpty) servicesLabel,
    if (newDriverDays != null) 'New drivers, first $newDriverDays days',
  ].join(' · ');

  Map<String, dynamic> toRow() => {
    'id': ?id,
    'name': name.trim(),
    'active': active,
    'rate': rate,
    'starts_at': startsAt.toUtc().toIso8601String(),
    'ends_at': endsAt.toUtc().toIso8601String(),
    'country': country,
    'state': state,
    'city': city,
    'services': services.isEmpty ? null : services,
    'weekdays': weekdays.isEmpty ? null : weekdays,
    'time_from': hasHours ? timeOfDayLabel(timeFrom!) : null,
    'time_to': hasHours ? timeOfDayLabel(timeTo!) : null,
    'new_driver_days': newDriverDays,
    'note': note.trim().isEmpty ? null : note.trim(),
  };

  CommissionPromotion copyWith({bool? active}) => CommissionPromotion(
    id: id,
    name: name,
    active: active ?? this.active,
    rate: rate,
    startsAt: startsAt,
    endsAt: endsAt,
    country: country,
    state: state,
    city: city,
    services: services,
    weekdays: weekdays,
    timeFrom: timeFrom,
    timeTo: timeTo,
    newDriverDays: newDriverDays,
    note: note,
  );

  @override
  bool operator ==(Object other) =>
      other is CommissionPromotion &&
      other.id == id &&
      other.name == name &&
      other.active == active &&
      other.rate == rate &&
      other.startsAt == startsAt &&
      other.endsAt == endsAt &&
      other.country == country &&
      other.state == state &&
      other.city == city &&
      listEquals(other.services, services) &&
      listEquals(other.weekdays, weekdays) &&
      other.timeFrom == timeFrom &&
      other.timeTo == timeTo &&
      other.newDriverDays == newDriverDays &&
      other.note == note;

  @override
  int get hashCode => Object.hash(id, name, active, rate, startsAt, endsAt, country, state, city,
      Object.hashAll(services), Object.hashAll(weekdays), timeFrom, timeTo, newDriverDays, note);
}

/// The rate after promotions: the lowest of [rate] (after tiers) and the
/// promotions that [fit], each only when lower. A personal (level "user")
/// rate is not lowered. Pure; mirrors commission_apply_promotions.
({double rate, CommissionPromotion? promotion}) applyCommissionPromotions(
  double rate,
  String level,
  Iterable<CommissionPromotion> fit,
) {
  if (level == 'user') return (rate: rate, promotion: null);
  var best = rate;
  CommissionPromotion? promotion;
  for (final p in fit) {
    if (p.rate < best) {
      best = p.rate;
      promotion = p;
    }
  }
  return (rate: best, promotion: promotion);
}

// ---- Reports -------------------------------------------------------------------------------------

/// How a report groups the commission charged.
enum CommissionReportGroup {
  day('Day'),
  week('Week'),
  month('Month'),
  country('Country'),
  state('State'),
  city('City'),
  driver('Driver');

  const CommissionReportGroup(this.label);
  final String label;

  bool get isPeriod => index <= CommissionReportGroup.month.index;
}

/// One row of admin_commission_report.
@immutable
class CommissionReportRow {
  const CommissionReportRow({
    required this.key,
    this.label,
    this.detail,
    this.trips = 0,
    this.meterTrips = 0,
    this.base = 0,
    this.commission = 0,
  });

  factory CommissionReportRow.fromRow(Map<String, dynamic> r) => CommissionReportRow(
    key: '${r['group_key'] ?? ''}',
    label: '${r['label'] ?? ''}'.trim().isEmpty ? null : '${r['label']}'.trim(),
    detail: '${r['detail'] ?? ''}'.trim().isEmpty ? null : '${r['detail']}'.trim(),
    trips: _num(r['trips']).round(),
    meterTrips: _num(r['meter_trips']).round(),
    base: _num(r['base_amount']),
    commission: _num(r['commission']),
  );

  /// The day, week or month's first day (YYYY-MM-DD), a place key, or the driver's id.
  final String key;
  final String? label;
  final String? detail;
  final int trips;
  final int meterTrips;

  /// What commission was charged on.
  final double base;
  final double commission;
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// What a row is called: "Mon 7 Sep 2026", "Week of 7 Sep 2026", "Sep 2026",
/// a place ("Unknown" where the trip had none) or the driver's name.
String commissionReportLabel(CommissionReportRow r, CommissionReportGroup g) {
  if (g.isPeriod) {
    final d = DateTime.tryParse(r.key);
    if (d == null) return r.key;
    final date = '${d.day} ${_months[d.month - 1]} ${d.year}';
    return switch (g) {
      CommissionReportGroup.day => '${weekdayNames[d.weekday - 1]} $date',
      CommissionReportGroup.week => 'Week of $date',
      _ => '${_months[d.month - 1]} ${d.year}',
    };
  }
  return r.label ?? (g == CommissionReportGroup.driver ? 'Unknown driver' : 'Unknown');
}

/// The report as a CSV: one line per row, then the total.
String commissionReportCsv(List<CommissionReportRow> rows, CommissionReportGroup g) {
  String money(double v) => v.toStringAsFixed(2);
  final columns = [
    g.label.toLowerCase(),
    if (g == CommissionReportGroup.driver) 'driver_id',
    if (g == CommissionReportGroup.driver) 'partner_id' else if (!g.isPeriod) 'in',
    'trips',
    'meter_trips',
    'charged_on',
    'commission',
  ];
  final data = [
    for (final r in rows)
      {
        columns.first: g.isPeriod ? r.key : commissionReportLabel(r, g),
        'driver_id': r.key,
        'partner_id': r.detail,
        'in': r.detail,
        'trips': r.trips,
        'meter_trips': r.meterTrips,
        'charged_on': money(r.base),
        'commission': money(r.commission),
      },
    {
      columns.first: 'Total',
      'trips': rows.fold<int>(0, (s, r) => s + r.trips),
      'meter_trips': rows.fold<int>(0, (s, r) => s + r.meterTrips),
      'charged_on': money(rows.fold<double>(0, (s, r) => s + r.base)),
      'commission': money(rows.fold<double>(0, (s, r) => s + r.commission)),
    },
  ];
  return rowsToCsv(data, columns);
}

/// One driver under the GET.credit floor (admin_drivers_below_credit).
@immutable
class BelowCreditDriver {
  const BelowCreditDriver({
    required this.uid,
    this.name,
    this.displayId,
    this.phone,
    required this.balance,
    required this.floor,
  });

  factory BelowCreditDriver.fromRow(Map<String, dynamic> r) => BelowCreditDriver(
    uid: '${r['partner_id'] ?? ''}',
    name: '${r['name'] ?? ''}'.trim().isEmpty ? null : '${r['name']}'.trim(),
    displayId: '${r['display_id'] ?? ''}'.trim().isEmpty ? null : '${r['display_id']}'.trim(),
    phone: '${r['phone'] ?? ''}'.trim().isEmpty ? null : '${r['phone']}'.trim(),
    balance: _num(r['balance']),
    floor: _num(r['credit_floor']),
  );

  final String uid;
  final String? name;
  final String? displayId;
  final String? phone;
  final double balance;
  final double floor;

  /// How much they must top up to reach the floor.
  double get shortBy => floor - balance;
}

/// The under-the-floor list as a CSV.
String belowCreditCsv(List<BelowCreditDriver> drivers) => rowsToCsv([
  for (final d in drivers)
    {
      'driver': d.name ?? '',
      'driver_id': d.uid,
      'partner_id': d.displayId ?? '',
      'phone': d.phone ?? '',
      'balance': d.balance.toStringAsFixed(2),
      'floor': d.floor.toStringAsFixed(2),
      'short_by': d.shortBy.toStringAsFixed(2),
    },
], const ['driver', 'driver_id', 'partner_id', 'phone', 'balance', 'floor', 'short_by']);
