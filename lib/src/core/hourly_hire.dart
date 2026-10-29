// Hourly hire (migration 0326): a driver and car by the hour, now or later,
// booked from the ride booking panel's "Hire by time" side. A hire is a
// ride_requests row with hire columns, priced by the server (hire_quote);
// this file reads the settings, the quote and the hire on a ride, and does
// the sums the server does (the extension amount, the settled breakdown) so
// the app shows what will be charged. Pure.
import 'dart:math' as math;

import 'package:intl/intl.dart';

/// The only package today; daily, weekly and monthly come later.
const hirePackageHourly = 'hourly';

/// A home tile, box or card set to this opens the booking panel on its
/// "Hire by time" side (Admin › Display › Home page targets).
const hireTileRoute = '/hire';

/// The ride option key a hire carries (0326): drivers who don't take hire
/// are not offered it.
const hireOptionKey = 'hire';

/// What an early end pays.
enum HireEarlyEndPays {
  /// The hours booked.
  booked('booked', 'The hours booked'),

  /// The least hours (or the hours used, if more).
  minimum('minimum', 'The least hours'),

  /// The hours used, in steps.
  used('used', 'The hours used');

  const HireEarlyEndPays(this.db, this.label);
  final String db;
  final String label;

  static HireEarlyEndPays parse(Object? v) =>
      HireEarlyEndPays.values.firstWhere((e) => e.db == v, orElse: () => HireEarlyEndPays.booked);
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

bool _bool(Object? v, bool d) => v is bool ? v : d;

String _text(Object? v, String d, int max) {
  final s = v is String ? v.trim() : '';
  return s.isEmpty || s.length > max ? d : s;
}

/// Admin › Settings › Hourly hire (app_settings 'hourly_hire'), as
/// hourly_hire_normalize keeps it.
class HourlyHireConfig {
  const HourlyHireConfig({
    this.enabled = false,
    this.allowNow = true,
    this.allowLater = true,
    this.minHours = 2,
    this.maxHours = 12,
    this.hourStep = 1,
    this.stepMinutes = 30,
    this.extendChoices = const [30, 60, 120],
    this.extendNeedsRider = true,
    this.riderCanEndEarly = true,
    this.earlyEndPays = HireEarlyEndPays.booked,
    this.holdInWallet = true,
    this.holdBufferPercent = 0,
    this.allowCash = false,
    this.kmPerHourDefault = 20,
    this.reminderBeforeEndMin = 15,
    this.autoEndAfterMin = 30,
    this.tileTitle = 'Hire a driver',
    this.tripLabel = 'Go somewhere',
    this.hireLabel = 'Hire by time',
  });

  static const off = HourlyHireConfig();

  factory HourlyHireConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return off;
    double clamp(Object? v, double d, double lo, double hi) => (_num(v) ?? d).clamp(lo, hi).toDouble();
    final step = _num(j['hourStep']) == 0.5 ? 0.5 : 1.0;
    var minH = clamp(j['minHours'], 2, 0.5, 24);
    minH = (minH / step).ceil() * step;
    var maxH = clamp(j['maxHours'], 12, minH, 72);
    maxH = math.max(minH, (maxH / step).floor() * step);
    final choices = <int>{
      if (j['extendChoices'] case final List l)
        for (final x in l)
          if (_num(x) case final n? when n >= 5 && n <= 720 && n == n.roundToDouble()) n.round(),
    }.toList()
      ..sort();
    final labels = j['panelLabels'] is Map ? Map<String, dynamic>.from(j['panelLabels'] as Map) : const {};
    return HourlyHireConfig(
      enabled: _bool(j['enabled'], false),
      allowNow: _bool(j['allowNow'], true),
      allowLater: _bool(j['allowLater'], true),
      minHours: minH,
      maxHours: maxH,
      hourStep: step,
      stepMinutes: clamp(j['stepMinutes'], 30, 5, 120).round(),
      extendChoices: choices.isEmpty ? const [30, 60, 120] : choices.take(6).toList(),
      extendNeedsRider: _bool(j['extendNeedsRider'], true),
      riderCanEndEarly: _bool(j['riderCanEndEarly'], true),
      earlyEndPays: HireEarlyEndPays.parse(j['earlyEndPays']),
      holdInWallet: _bool(j['holdInWallet'], true),
      holdBufferPercent: clamp(j['holdBufferPercent'], 0, 0, 100),
      allowCash: _bool(j['allowCash'], false),
      kmPerHourDefault: clamp(j['kmPerHourDefault'], 20, 0, 500),
      reminderBeforeEndMin: clamp(j['reminderBeforeEndMin'], 15, 0, 240).round(),
      autoEndAfterMin: clamp(j['autoEndAfterMin'], 30, 5, 1440).round(),
      tileTitle: _text(j['tileTitle'], 'Hire a driver', 40),
      tripLabel: _text(labels['trip'], 'Go somewhere', 30),
      hireLabel: _text(labels['hire'], 'Hire by time', 30),
    );
  }

  final bool enabled, allowNow, allowLater;
  final double minHours, maxHours, hourStep;
  final int stepMinutes;
  final List<int> extendChoices;
  final bool extendNeedsRider, riderCanEndEarly;
  final HireEarlyEndPays earlyEndPays;
  final bool holdInWallet;
  final double holdBufferPercent;
  final bool allowCash;
  final double kmPerHourDefault;
  final int reminderBeforeEndMin, autoEndAfterMin;
  final String tileTitle, tripLabel, hireLabel;

  /// Bookable at all (now or later).
  bool get bookable => enabled && (allowNow || allowLater);

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'allowNow': allowNow,
    'allowLater': allowLater,
    'minHours': minHours,
    'maxHours': maxHours,
    'hourStep': hourStep,
    'stepMinutes': stepMinutes,
    'extendChoices': extendChoices,
    'extendNeedsRider': extendNeedsRider,
    'riderCanEndEarly': riderCanEndEarly,
    'earlyEndPays': earlyEndPays.db,
    'holdInWallet': holdInWallet,
    'holdBufferPercent': holdBufferPercent,
    'allowCash': allowCash,
    'kmPerHourDefault': kmPerHourDefault,
    'reminderBeforeEndMin': reminderBeforeEndMin,
    'autoEndAfterMin': autoEndAfterMin,
    'tileTitle': tileTitle,
    'panelLabels': {'trip': tripLabel, 'hire': hireLabel},
  };

  /// The hours the stepper offers, least to most.
  List<double> get hourChoices => [
    for (var h = minHours; h <= maxHours + 1e-9; h += hourStep) double.parse(h.toStringAsFixed(1)),
  ];

  /// [h] kept within the range, on a step.
  double clampHours(double h) {
    final stepped = (h / hourStep).round() * hourStep;
    return stepped.clamp(minHours, maxHours).toDouble();
  }
}

/// The server's price for a hire (hire_quote).
class HireQuote {
  const HireQuote({
    required this.available,
    this.reason,
    this.hint,
    required this.hours,
    this.minHours = 2,
    this.maxHours = 12,
    this.rate,
    this.kmPerHour = 0,
    this.kmIncluded = 0,
    this.overtimePerHour = 0,
    this.stepMinutes = 30,
    this.extraKm = 0,
    this.base = 0,
    this.placeFees = const [],
    this.placeFeesTotal = 0,
    this.total = 0,
    this.hold = 0,
    this.holdInWallet = true,
    this.allowCash = false,
  });

  factory HireQuote.fromJson(Map<String, dynamic> j) => HireQuote(
    available: j['available'] != false,
    reason: j['reason'] as String?,
    hint: j['hint'] as String?,
    hours: _num(j['hours']) ?? 0,
    minHours: _num(j['minHours']) ?? 2,
    maxHours: _num(j['maxHours']) ?? 12,
    rate: _num(j['rate']),
    kmPerHour: _num(j['kmPerHour']) ?? 0,
    kmIncluded: _num(j['kmIncluded']) ?? 0,
    overtimePerHour: _num(j['overtimePerHour']) ?? 0,
    stepMinutes: (_num(j['stepMinutes']) ?? 30).round(),
    extraKm: _num(j['extraKm']) ?? 0,
    base: _num(j['base']) ?? 0,
    placeFees: [
      if (j['placeFees'] case final List l)
        for (final f in l)
          if (f is Map) (name: '${f['name'] ?? 'Place fee'}', amount: _num(f['value']) ?? 0),
    ],
    placeFeesTotal: _num(j['placeFeesTotal']) ?? 0,
    total: _num(j['total']) ?? 0,
    hold: _num(j['hold']) ?? 0,
    holdInWallet: j['holdInWallet'] != false,
    allowCash: j['allowCash'] == true,
  );

  final bool available;
  final String? reason, hint;
  final double hours, minHours, maxHours;
  final double? rate;
  final double kmPerHour, kmIncluded, overtimePerHour;
  final int stepMinutes;
  final double extraKm, base;
  final List<({String name, double amount})> placeFees;
  final double placeFeesTotal, total, hold;
  final bool holdInWallet, allowCash;
}

/// "4 hr", "1.5 hr".
String hireHoursText(num h) {
  final v = h.toDouble();
  return '${v == v.roundToDouble() ? v.round() : v.toStringAsFixed(1)} hr';
}

/// "30 min", "1 hr", "1 hr 30 min".
String hireMinutesText(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h hr' : '$h hr $m min';
}

/// "Hourly hire · 4 hr".
String hireTitle(num hours) => 'Hourly hire · ${hireHoursText(hours)}';

/// The card's line under a hire price: "RM 40 / hr · 60 km included".
String hireRateLine(HireQuote q, String Function(double) money) =>
    '${money(q.rate ?? 0)} / hr · ${_km(q.kmIncluded)} km included';

/// What isn't in the price: "Overtime RM 50 / hr, extra km RM 1.20 / km, fuel included".
String hireTermsLine(HireQuote q, String Function(double) money) =>
    'Overtime ${money(q.overtimePerHour)} / hr, extra km ${money(q.extraKm)} / km, fuel included';

String _km(double km) => km == km.roundToDouble() ? '${km.round()}' : km.toStringAsFixed(1);

/// What [minutes] of overtime cost, rounded up to whole [step]-minute steps
/// (hire_overtime_amount).
double hireOvertimeAmount(int minutes, int step, double ratePerHour) {
  if (minutes <= 0 || ratePerHour <= 0) return 0;
  final s = math.max(1, step);
  final billed = (minutes / s).ceil() * s;
  return _round2(billed / 60 * ratePerHour);
}

double _round2(double v) => (v * 100).round() / 100;

/// One extension of a hire (ride_requests.hire_extensions).
class HireExtension {
  const HireExtension({
    required this.id,
    required this.minutes,
    required this.amount,
    required this.askedBy,
    required this.status,
    this.askedAt,
  });

  factory HireExtension.fromJson(Map<String, dynamic> j) => HireExtension(
    id: '${j['id']}',
    minutes: (_num(j['minutes']) ?? 0).round(),
    amount: _num(j['amount']) ?? 0,
    askedBy: '${j['asked_by'] ?? ''}',
    status: '${j['status'] ?? ''}',
    askedAt: DateTime.tryParse('${j['asked_at']}')?.toLocal(),
  );

  final String id;
  final int minutes;
  final double amount;

  /// 'rider' or 'driver'.
  final String askedBy;

  /// 'pending', 'approved', 'declined' or 'lapsed'.
  final String status;
  final DateTime? askedAt;

  bool get pending => status == 'pending';
  bool get approved => status == 'approved';
}

/// A settled hire's lines (hire_settled.lines, also on statements).
typedef HireLine = ({String label, double amount});

/// The hire on a ride row; null for a normal ride.
class RideHire {
  const RideHire({
    required this.hours,
    this.rate = 0,
    this.kmIncluded = 0,
    this.overtimeRate = 0,
    this.stepMinutes = 30,
    this.extraKmRate = 0,
    this.kmPerHour = 0,
    this.minHours = 0,
    this.hourStep = 1,
    this.placeFeesTotal = 0,
    this.startedAt,
    this.endsAt,
    this.extensions = const [],
    this.kmUsed,
    this.settledLines = const [],
    this.settledFare,
  });

  static RideHire? fromRow(Map<String, dynamic> r) {
    if (r['hire_package'] == null) return null;
    final q = r['hire_quote'] is Map ? Map<String, dynamic>.from(r['hire_quote'] as Map) : const <String, dynamic>{};
    final settled = r['hire_settled'] is Map ? Map<String, dynamic>.from(r['hire_settled'] as Map) : null;
    return RideHire(
      hours: _num(r['hire_hours']) ?? _num(q['hours']) ?? 0,
      rate: _num(r['hire_rate']) ?? _num(q['rate']) ?? 0,
      kmIncluded: _num(r['hire_km_included']) ?? 0,
      overtimeRate: _num(r['hire_overtime_rate']) ?? 0,
      stepMinutes: (_num(r['hire_step_min']) ?? 30).round(),
      extraKmRate: _num(r['hire_extra_km_rate']) ?? 0,
      kmPerHour: _num(q['kmPerHour']) ?? 0,
      minHours: _num(q['minHours']) ?? 0,
      hourStep: _num(q['hourStep']) ?? 1,
      placeFeesTotal: _num(q['placeFeesTotal']) ?? 0,
      startedAt: DateTime.tryParse('${r['hire_started_at']}')?.toLocal(),
      endsAt: DateTime.tryParse('${r['hire_ends_at']}')?.toLocal(),
      extensions: [
        if (r['hire_extensions'] case final List l)
          for (final e in l)
            if (e is Map) HireExtension.fromJson(Map<String, dynamic>.from(e)),
      ],
      kmUsed: _num(r['hire_km_used']),
      settledFare: settled == null ? null : _num(settled['fare']),
      settledLines: [
        if (settled?['lines'] case final List l)
          for (final x in l)
            if (x is Map) (label: '${x['label'] ?? ''}', amount: _num(x['amount']) ?? 0),
      ],
    );
  }

  final double hours, rate, kmIncluded, overtimeRate;
  final int stepMinutes;
  final double extraKmRate, kmPerHour, minHours, hourStep, placeFeesTotal;
  final DateTime? startedAt, endsAt;
  final List<HireExtension> extensions;
  final double? kmUsed;
  final List<HireLine> settledLines;
  final double? settledFare;

  bool get started => startedAt != null;
  bool get settled => settledFare != null;
  HireExtension? get pending => extensions.where((e) => e.pending).firstOrNull;
  int get approvedMinutes => extensions.where((e) => e.approved).fold(0, (s, e) => s + e.minutes);

  /// The booked time plus approved extensions, in minutes.
  int get totalMinutes => (hours * 60).round() + approvedMinutes;

  /// Minutes used at [now] (0 before the start).
  int usedMinutes(DateTime now) => startedAt == null ? 0 : math.max(0, now.difference(startedAt!).inMinutes);

  /// "1 hr 20 min of 4 hr".
  String usedText(DateTime now) => '${hireMinutesText(usedMinutes(now))} of ${hireMinutesText(totalMinutes)}';

  /// What an extension of [minutes] costs (rounded up to the step).
  double extensionAmount(int minutes) => hireOvertimeAmount(minutes, stepMinutes, overtimeRate);

  /// The settled breakdown, as hire_settle works it out, ending at [at]
  /// having driven [km] (an estimate before the server's).
  ({double base, double hours, int overtimeMinutes, double overtime, double extraKm, double extraKmAmount,
    double fare, bool early})
  settle({required DateTime at, double km = 0, HireEarlyEndPays pays = HireEarlyEndPays.booked}) {
    final used = startedAt == null ? 0.0 : math.max(0, at.difference(startedAt!).inSeconds) / 60;
    final step = hourStep <= 0 ? 1.0 : hourStep;
    final early = used < hours * 60;
    double billed(double minFloor) => math.min(hours, math.max(minFloor, ((used / 60) / step).ceil() * step));
    final h = !early || pays == HireEarlyEndPays.booked
        ? hours
        : pays == HireEarlyEndPays.minimum
        ? billed(minHours)
        : billed(step);
    final base = _round2(h * rate);
    final ext = approvedMinutes;
    var over = math.min(ext.toDouble(), math.max(0.0, used - hours * 60));
    final s = math.max(1, stepMinutes);
    over = math.min(ext.toDouble(), ((over / s).ceil() * s).toDouble());
    final overtime = hireOvertimeAmount(over.round(), stepMinutes, overtimeRate);
    final included = ((kmIncluded + ext / 60 * kmPerHour) * 10).round() / 10;
    final extra = math.max(0.0, ((km - included) * 10).round() / 10);
    final extraAmount = _round2(extra * extraKmRate);
    return (
      base: base,
      hours: h,
      overtimeMinutes: over.round(),
      overtime: overtime,
      extraKm: extra,
      extraKmAmount: extraAmount,
      fare: _round2(base + overtime + extraAmount),
      early: early,
    );
  }

  /// The hire's lines for a receipt: the settled ones, else the booked hours.
  List<HireLine> lines(double fare) =>
      settledLines.isNotEmpty ? settledLines : [(label: 'Hourly hire ${hireHoursText(hours)}', amount: fare)];
}

/// "9:00 am".
String hireClock(DateTime t) => DateFormat('h:mm a').format(t.toLocal()).toLowerCase();

/// "Hourly hire · 4 hr, 9:00 am to 1:00 pm" for a booking at [pickup].
String hireSpanText(num hours, DateTime pickup, [String Function(DateTime) time = hireClock]) {
  final end = pickup.add(Duration(minutes: (hours * 60).round()));
  return '${hireTitle(hours)}, ${time(pickup)} to ${time(end)}';
}

/// What the rider reads when the server refuses a hire (its HIRE_* code).
String? hireRefusalText(String? message) {
  final m = message ?? '';
  const codes = {
    'HIRE_OFF': 'Hiring a driver by the hour is not available.',
    'HIRE_SERVICE_OFF': "This vehicle can't be hired by the hour here. Choose another.",
    'HIRE_NO_RATE': 'This vehicle has no hourly price here yet. Choose another.',
    'HIRE_HOURS': 'Choose a number of hours within the range shown.',
    'HIRE_CASH': 'Hourly hire is paid in the app. Choose GET.wallet.',
    'HIRE_NOW_OFF': 'Hourly hire can only be booked for later.',
    'HIRE_LATER_OFF': "Hourly hire can't be booked for later.",
    'HIRE_BUSINESS': "Hourly hire can't be charged to a business account yet.",
    'HIRE_BALANCE': 'Top up your GET.wallet: the hire price is held until the hire ends.',
    'HIRE_EXTEND_PENDING': 'An extension is already waiting for an answer.',
    'HIRE_EXTEND_GONE': 'This extension was already answered.',
    'HIRE_EXTEND_CHOICE': 'Choose one of the times offered.',
    'HIRE_NOT_ON': 'This hire is not on the go.',
    'HIRE_KM': 'Enter the km driven (0 to 5000).',
    'HIRE_DRIVER_OFF': 'Turn on "Take hourly hire" in your preferences to take hourly hires.',
    'HIRE_FIXED_FARE': 'Hourly hire is at a fixed price.',
    'HIRE_END_USE': 'Use End hire to finish an hourly hire.',
  };
  for (final e in codes.entries) {
    if (m.contains(e.key)) return e.value;
  }
  return null;
}

/// What the rider pays if they end now, in plain words.
String hireEarlyEndText(HireEarlyEndPays pays, double minHours) => switch (pays) {
  HireEarlyEndPays.booked => 'Ending early still pays the hours booked.',
  HireEarlyEndPays.minimum => 'Ending early pays the hours used, at least ${hireHoursText(minHours)}.',
  HireEarlyEndPays.used => 'Ending early pays the hours used.',
};

/// The hire on an admin's ride details: the package and hours, the rates,
/// the clock, each extension and the settled breakdown.
Map<String, String?> hireAdminDetails(RideHire h, String Function(double) money) => {
  'Hourly hire': '${hireHoursText(h.hours)} at ${money(h.rate)} / hr, ${h.kmIncluded.round()} km included',
  'Hire overtime / extra km': '${money(h.overtimeRate)} / hr per ${h.stepMinutes} min · ${money(h.extraKmRate)} / km',
  'Hire started': h.startedAt == null ? null : hireClock(h.startedAt!),
  'Hire ends': h.endsAt == null ? null : hireClock(h.endsAt!),
  'Hire extensions': h.extensions.isEmpty
      ? null
      : [
          for (final e in h.extensions)
            '${hireMinutesText(e.minutes)} ${money(e.amount)} (${e.askedBy}, ${e.status})',
        ].join(' · '),
  'Hire km used': h.kmUsed == null ? null : '${h.kmUsed!.toStringAsFixed(1)} km',
  'Hire settled': h.settledLines.isEmpty
      ? null
      : [for (final l in h.settledLines) '${l.label} ${money(l.amount)}'].join(' · '),
};
