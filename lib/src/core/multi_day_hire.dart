// Hire for several days (migration 0327: daily; 0328: weekly and monthly).
// One booking (hire_bookings) and one scheduled ride a day, each released
// before its start as a ride_requests row with the 0326 hire columns. This
// file reads a package's settings, the server's quote and a booking, and
// does the sums the server does (each day's amount due, the deposit) so the
// review shows what will be charged. Pure.
import 'package:intl/intl.dart';

import 'hourly_hire.dart' show hireClock, hireHoursText;
import 'region_pricing.dart';

const hirePackageDaily = 'daily';
const hirePackageWeekly = 'weekly';
const hirePackageMonthly = 'monthly';

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

double _round2(double v) => (v * 100).round() / 100;

/// What a late cancel costs.
enum HireLateCancel {
  deposit('deposit', 'The deposit is kept'),
  percent('percent', 'A percent of the price'),
  firstDay('first_day', 'The first day');

  const HireLateCancel(this.db, this.label);
  final String db;
  final String label;

  static HireLateCancel parse(Object? v) =>
      HireLateCancel.values.firstWhere((e) => e.db == v, orElse: () => HireLateCancel.deposit);
}

/// A package's defaults, as hire_multi_normalize has them (0327, 0328).
typedef _Defaults = ({int maxPeriods, double minH, double maxH, double h, double km, int lead, int ahead,
    bool deposit, int free, int cut, String chip, String title});

_Defaults _defaultsFor(String package) => switch (package) {
  hirePackageWeekly => (maxPeriods: 8, minH: 4, maxH: 12, h: 8, km: 1000, lead: 24, ahead: 60, deposit: false,
      free: 48, cut: 24, chip: 'Weekly', title: 'Weekly hire'),
  hirePackageMonthly => (maxPeriods: 3, minH: 4, maxH: 12, h: 8, km: 4000, lead: 72, ahead: 90, deposit: false,
      free: 72, cut: 48, chip: 'Monthly', title: 'Monthly hire'),
  _ => (maxPeriods: 6, minH: 8, maxH: 12, h: 10, km: 200, lead: 12, ahead: 30, deposit: true, free: 24, cut: 6,
      chip: 'Daily', title: 'Daily hire'),
};

/// Monday to Sunday, ISO numbers 1 to 7.
const hireWeekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Admin › Settings › Daily hire, Weekly hire, Monthly hire (app_settings
/// 'daily_hire', 'weekly_hire', 'monthly_hire'), as hire_multi_normalize keeps them.
class MultiHireConfig {
  const MultiHireConfig({
    this.package = hirePackageDaily,
    this.enabled = false,
    this.maxDays = 6,
    this.minHoursPerDay = 8,
    this.maxHoursPerDay = 12,
    this.hoursPerDayDefault = 10,
    this.kmPerDayDefault = 200,
    this.leadHours = 12,
    this.bookAheadDays = 30,
    this.depositPercent = 30,
    this.allowPrepay = true,
    this.allowDeposit = true,
    this.allowBusiness = true,
    this.freeCancelHours = 24,
    this.lateCancel = HireLateCancel.deposit,
    this.lateCancelPercent = 50,
    this.sameDriverDefault = true,
    this.splitAfterHours = 6,
    this.splitDays = true,
    this.overnightAllowance = 50,
    this.mealAllowance = 0,
    this.maxOpenBookings = 3,
    this.chipLabel = 'Daily',
    this.title = 'Daily hire',
    this.rateWeekdays = 5,
    this.weekdaysDefault = const [1, 2, 3, 4, 5],
    this.skipHolidays = true,
    this.kmByPeriod = true,
    this.noticeDays = 0,
  });

  static const off = MultiHireConfig();

  factory MultiHireConfig.fromJson(String package, Map<String, dynamic>? j) {
    final d = _defaultsFor(package);
    j ??= const {};
    double n(Object? v, double dv, double lo, double hi) => (_num(v) ?? dv).clamp(lo, hi).toDouble();
    double half(double v) => (v * 2).round() / 2;
    final minH = half(n(j['minHoursPerDay'], d.minH, 1, 24));
    final maxH = half(n(j['maxHoursPerDay'], d.maxH, 1, 24)).clamp(minH, 24).toDouble();
    final labels = j['labels'] is Map ? Map<String, dynamic>.from(j['labels'] as Map) : const {};
    final periodKey = switch (package) {
      hirePackageWeekly => 'Week',
      hirePackageMonthly => 'Month',
      _ => null,
    };
    var prepay = _bool(j['allowPrepay'], true);
    final deposit = _bool(j['allowDeposit'], d.deposit);
    if (!prepay && !deposit) prepay = true;
    final days = <int>{
      if (j['weekdaysDefault'] case final List l)
        for (final x in l)
          if (_num(x) case final v? when v >= 1 && v <= 7 && v == v.roundToDouble()) v.round(),
    }.toList()
      ..sort();
    return MultiHireConfig(
      package: package,
      enabled: _bool(j['enabled'], false),
      maxDays: periodKey == null
          ? n(j['maxDays'], 6, 1, 60).round()
          : n(j['max${periodKey}s'], d.maxPeriods.toDouble(), 1, package == hirePackageWeekly ? 26 : 12).round(),
      minHoursPerDay: minH,
      maxHoursPerDay: maxH,
      hoursPerDayDefault: half(n(j['hoursPerDayDefault'], d.h, 1, 24)).clamp(minH, maxH).toDouble(),
      kmPerDayDefault: periodKey == null
          ? n(j['kmPerDayDefault'], 200, 0, 5000)
          : n(j['kmPer${periodKey}Default'], d.km, 0, 500000),
      leadHours: n(j['leadHours'], d.lead.toDouble(), 0, 720).round(),
      bookAheadDays: n(j['bookAheadDays'], d.ahead.toDouble(), 1, 365).round(),
      depositPercent: n(j['depositPercent'], 30, 0, 100),
      allowPrepay: prepay,
      allowDeposit: deposit,
      allowBusiness: _bool(j['allowBusiness'], true),
      freeCancelHours: n(j['freeCancelHours'], d.free.toDouble(), 0, 720).round(),
      lateCancel: HireLateCancel.parse(j['lateCancelMode']),
      lateCancelPercent: n(j['lateCancelPercent'], 50, 0, 100),
      sameDriverDefault: _bool(j['sameDriverDefault'], true),
      splitAfterHours: n(j['splitAfterHours'], d.cut.toDouble(), 0, 720).round(),
      splitDays: _bool(j['splitDays'], true),
      overnightAllowance: n(j['overnightAllowance'], 50, 0, 100000),
      mealAllowance: n(j['mealAllowance'], 0, 0, 100000),
      maxOpenBookings: n(j['maxOpenBookings'], 3, 1, 20).round(),
      chipLabel: _text(labels['chip'], d.chip, 20),
      title: _text(labels['title'], d.title, 40),
      rateWeekdays: n(j['rateWeekdays'], 5, 1, 7).round(),
      weekdaysDefault: days.isEmpty ? const [1, 2, 3, 4, 5] : days,
      skipHolidays: j['holidays'] != 'work',
      kmByPeriod: j['kmMode'] != 'day',
      noticeDays: package == hirePackageMonthly ? n(j['noticeDays'], 7, 0, 60).round() : 0,
    );
  }

  final String package;
  final bool enabled;

  /// The most days (daily), weeks (weekly) or months (monthly).
  final int maxDays;
  final double minHoursPerDay, maxHoursPerDay, hoursPerDayDefault;

  /// The km included a day (daily), a week or a month, where a Vehicle
  /// Service sets none.
  final double kmPerDayDefault;
  final int leadHours, bookAheadDays;
  final double depositPercent;
  final bool allowPrepay, allowDeposit, allowBusiness;
  final int freeCancelHours;
  final HireLateCancel lateCancel;
  final double lateCancelPercent;
  final bool sameDriverDefault;
  final int splitAfterHours;
  final bool splitDays;
  final double overnightAllowance, mealAllowance;
  final int maxOpenBookings;
  final String chipLabel, title;

  /// Weekly and monthly (0328): the weekdays a rate is for, those offered
  /// first, public holidays skipped (or worked), extra km by the period (or
  /// the day), and a monthly hire's notice once it has started.
  final int rateWeekdays;
  final List<int> weekdaysDefault;
  final bool skipHolidays, kmByPeriod;
  final int noticeDays;

  /// Weeks or months rather than days.
  bool get byPeriod => package == hirePackageWeekly || package == hirePackageMonthly;

  /// "week", "month", "day".
  String get periodWord => switch (package) {
    hirePackageWeekly => 'week',
    hirePackageMonthly => 'month',
    _ => 'day',
  };

  /// "2 weeks", "1 month", "3 days".
  String periodsText(int n) => n == 1 ? '1 $periodWord' : '$n ${periodWord}s';

  Map<String, dynamic> toJson() {
    final periodKey = switch (package) {
      hirePackageWeekly => 'Week',
      hirePackageMonthly => 'Month',
      _ => null,
    };
    return {
      'enabled': enabled,
      if (periodKey == null) 'maxDays': maxDays else 'max${periodKey}s': maxDays,
      'minHoursPerDay': minHoursPerDay,
      'maxHoursPerDay': maxHoursPerDay,
      'hoursPerDayDefault': hoursPerDayDefault,
      if (periodKey == null) 'kmPerDayDefault': kmPerDayDefault else 'kmPer${periodKey}Default': kmPerDayDefault,
      'leadHours': leadHours,
      'bookAheadDays': bookAheadDays,
      'depositPercent': depositPercent,
      'allowPrepay': allowPrepay,
      'allowDeposit': allowDeposit,
      'allowBusiness': allowBusiness,
      'freeCancelHours': freeCancelHours,
      'lateCancelMode': lateCancel.db,
      'lateCancelPercent': lateCancelPercent,
      'sameDriverDefault': sameDriverDefault,
      'splitAfterHours': splitAfterHours,
      'splitDays': splitDays,
      'overnightAllowance': overnightAllowance,
      'mealAllowance': mealAllowance,
      'maxOpenBookings': maxOpenBookings,
      'labels': {'chip': chipLabel, 'title': title},
      if (byPeriod) ...{
        'rateWeekdays': rateWeekdays,
        'weekdaysDefault': weekdaysDefault,
        'holidays': skipHolidays ? 'skip' : 'work',
        'kmMode': kmByPeriod ? 'period' : 'day',
        if (package == hirePackageMonthly) 'noticeDays': noticeDays,
      },
    };
  }

  /// The hours a day the stepper offers, in half hours.
  List<double> get hourChoices => [for (var h = minHoursPerDay; h <= maxHoursPerDay + 1e-9; h += 0.5) h];

  double clampHours(double h) => ((h * 2).round() / 2).clamp(minHoursPerDay, maxHoursPerDay).toDouble();
  int clampDays(int d) => d.clamp(1, maxDays);

  /// The plan a booking starts on: a deposit where one is taken, else in full.
  HirePayPlan get defaultPlan => allowDeposit ? HirePayPlan.deposit : HirePayPlan.prepay;

  /// The soonest the first day may start, from [now].
  DateTime earliest(DateTime now) => now.add(Duration(hours: leadHours));

  /// The latest the first day may start.
  DateTime latest(DateTime now) => now.add(Duration(days: bookAheadDays));

  /// Why the first day at [at] can't be booked at [now], or null.
  String? firstDayProblem(DateTime at, DateTime now) {
    if (at.isBefore(earliest(now))) return 'Book at least $leadHours hours ahead.';
    if (at.isAfter(latest(now))) return 'Book up to $bookAheadDays days ahead.';
    return null;
  }
}

/// The server's price for a multi-day hire (hire_multi_quote).
class MultiHireQuote {
  const MultiHireQuote({
    required this.available,
    this.reason,
    this.hint,
    this.package = hirePackageDaily,
    this.title = 'Daily hire',
    this.days = 1,
    this.hours = 10,
    this.dayRate,
    this.dayHours = 10,
    this.perDay = 0,
    this.kmPerDay = 0,
    this.overtimePerHour = 0,
    this.extraKm = 0,
    this.stepMinutes = 30,
    this.overnight = false,
    this.nights = 0,
    this.overnightAllowance = 0,
    this.mealAllowance = 0,
    this.placeFees = const [],
    this.placeFeesPerDay = 0,
    this.base = 0,
    this.total = 0,
    this.depositPercent = 30,
    this.allowPrepay = true,
    this.freeCancelUntil,
    this.dates = const [],
    this.dateList = const [],
    this.periods = 1,
    this.weekdays = const [],
    this.periodPrice = 0,
    this.kmPerPeriod = 0,
    this.kmByPeriod = false,
    this.holidaysSkipped = const [],
    this.noticeDays = 0,
  });

  factory MultiHireQuote.fromJson(Map<String, dynamic> j) => MultiHireQuote(
    available: j['available'] != false,
    reason: j['reason'] as String?,
    hint: j['hint'] as String?,
    package: '${j['package'] ?? hirePackageDaily}',
    title: '${j['title'] ?? 'Daily hire'}',
    days: (_num(j['days']) ?? 1).round(),
    hours: _num(j['hours']) ?? 10,
    dayRate: _num(j['dayRate']),
    dayHours: _num(j['dayHours']) ?? 10,
    perDay: _num(j['perDay']) ?? 0,
    kmPerDay: _num(j['kmPerDay']) ?? 0,
    overtimePerHour: _num(j['overtimePerHour']) ?? 0,
    extraKm: _num(j['extraKm']) ?? 0,
    stepMinutes: (_num(j['stepMinutes']) ?? 30).round(),
    overnight: j['overnight'] == true,
    nights: (_num(j['nights']) ?? 0).round(),
    overnightAllowance: _num(j['overnightAllowance']) ?? 0,
    mealAllowance: _num(j['mealAllowance']) ?? 0,
    placeFees: [
      if (j['placeFees'] case final List l)
        for (final f in l)
          if (f is Map) (name: '${f['name'] ?? 'Place fee'}', amount: _num(f['value']) ?? 0),
    ],
    placeFeesPerDay: _num(j['placeFeesPerDay']) ?? 0,
    base: _num(j['base']) ?? 0,
    total: _num(j['total']) ?? 0,
    depositPercent: _num(j['depositPercent']) ?? 30,
    allowPrepay: j['allowPrepay'] != false,
    freeCancelUntil: DateTime.tryParse('${j['freeCancelUntil']}')?.toLocal(),
    dates: [
      if (j['dates'] case final List l)
        for (final d in l) ?DateTime.tryParse('$d')?.toLocal(),
    ],
    dateList: [
      if (j['dateList'] case final List l)
        for (final d in l)
          if (d is Map)
            (
              at: DateTime.tryParse('${d['at']}')?.toLocal() ?? DateTime.now(),
              period: (_num(d['period']) ?? 1).round(),
              perDay: _num(d['perDay']) ?? 0,
              km: _num(d['km']) ?? 0,
            ),
    ],
    periods: (_num(j['periods']) ?? 1).round(),
    weekdays: [
      if (j['weekdays'] case final List l)
        for (final d in l) ?_num(d)?.round(),
    ],
    periodPrice: _num(j['periodPrice']) ?? 0,
    kmPerPeriod: _num(j['kmPerPeriod']) ?? 0,
    kmByPeriod: j['kmMode'] == 'period',
    holidaysSkipped: [
      if (j['holidaysSkipped'] case final List l)
        for (final d in l) ?DateTime.tryParse('$d'),
    ],
    noticeDays: (_num(j['noticeDays']) ?? 0).round(),
  );

  final bool available;
  final String? reason, hint;
  final String package, title;
  final int days;
  final double hours;
  final double? dayRate;
  final double dayHours, perDay, kmPerDay, overtimePerHour, extraKm;
  final int stepMinutes;
  final bool overnight;
  final int nights;
  final double overnightAllowance, mealAllowance;
  final List<({String name, double amount})> placeFees;
  final double placeFeesPerDay, base, total, depositPercent;
  final bool allowPrepay;
  final DateTime? freeCancelUntil;
  final List<DateTime> dates;

  /// Every day: when, its period (week or month; a day's own for daily),
  /// its price and its km (0328).
  final List<({DateTime at, int period, double perDay, double km})> dateList;

  /// Weekly and monthly (0328): the weeks or months, the weekdays chosen,
  /// a period's price and km, km by the period, the holidays skipped and a
  /// monthly hire's notice.
  final int periods;
  final List<int> weekdays;
  final double periodPrice, kmPerPeriod;
  final bool kmByPeriod;
  final List<DateTime> holidaysSkipped;
  final int noticeDays;

  /// Day [day]'s price (1-based): its own (a period's share), else the day price.
  double dayPrice(int day) => day >= 1 && day <= dateList.length ? dateList[day - 1].perDay : perDay;

  /// The allowance for the night after day [day] (1-based): none after the last.
  double overnightOn(int day) => overnight && day < days ? overnightAllowance : 0;
}

/// One day of a booking as its ride will be charged: the day price (rounded
/// up where fares are whole), its place fees, allowances, and the region's
/// surcharges and taxes on them (as ride_amount_due works it out).
({double base, double fees, double allowances, List<ChargeLine> lines, double total}) multiHireDay(
  MultiHireQuote q,
  RegionPricing pricing,
  int day,
) {
  final base = pricing.wholeFare ? (q.dayPrice(day) - 1e-9).ceilToDouble() : q.dayPrice(day);
  final fixed = [
    for (final f in q.placeFees) (name: f.name, amount: f.amount),
    if (q.mealAllowance > 0) (name: 'Meal allowance', amount: q.mealAllowance),
    if (q.overnightOn(day) > 0) (name: 'Overnight allowance', amount: q.overnightOn(day)),
  ];
  final regionSurcharges = pricing.charges.where((c) => !c.isTax).length;
  final all = RegionPricing(
    wholeFare: pricing.wholeFare,
    tax: pricing.tax,
    charges: [
      ...pricing.charges,
      for (final f in fixed) FareCharge(isTax: false, name: f.name, percent: false, value: f.amount),
    ],
  ).linesFor(base);
  final lines = [
    for (final (i, l) in all.indexed)
      if (l.isTax || i < regionSurcharges) l,
  ];
  final fees = q.placeFees.fold(0.0, (a, f) => a + f.amount);
  final allowances = q.mealAllowance + q.overnightOn(day);
  return (
    base: base,
    fees: _round2(fees),
    allowances: _round2(allowances),
    lines: lines,
    total: _round2(base + fees + allowances + lines.fold(0.0, (a, l) => a + l.amount)),
  );
}

/// How a booking is paid upfront.
enum HirePayPlan {
  deposit('deposit'),
  prepay('prepay'),
  business('business');

  const HirePayPlan(this.db);
  final String db;

  static HirePayPlan parse(Object? v) =>
      HirePayPlan.values.firstWhere((e) => e.db == v, orElse: () => HirePayPlan.deposit);
}

/// The whole booking as the review shows it: every day's total, the
/// region's lines summed, what is paid now and on day 1.
({double base, double fees, double allowances, Map<String, double> lines, double total, double payNow, double balance})
multiHireTotals(MultiHireQuote q, RegionPricing pricing, HirePayPlan plan) {
  var base = 0.0, fees = 0.0, allowances = 0.0, total = 0.0;
  final lines = <String, double>{};
  for (var d = 1; d <= q.days; d++) {
    final x = multiHireDay(q, pricing, d);
    base += x.base;
    fees += x.fees;
    allowances += x.allowances;
    total += x.total;
    for (final l in x.lines) {
      lines[l.label] = _round2((lines[l.label] ?? 0) + l.amount);
    }
  }
  total = _round2(total);
  final now = switch (plan) {
    HirePayPlan.prepay => total,
    HirePayPlan.deposit => _round2(total * q.depositPercent / 100),
    HirePayPlan.business => 0.0,
  };
  return (
    base: _round2(base),
    fees: _round2(fees),
    allowances: _round2(allowances),
    lines: lines,
    total: total,
    payNow: now,
    balance: plan == HirePayPlan.deposit ? _round2(total - now) : 0,
  );
}

/// A booking (hire_bookings).
class HireDaysBooking {
  const HireDaysBooking({
    required this.id,
    required this.package,
    required this.title,
    required this.service,
    required this.status,
    required this.firstAt,
    required this.days,
    required this.hoursPerDay,
    this.kmPerDay,
    this.overnight = false,
    this.sameDriver = true,
    this.splitAt,
    this.partnerId,
    this.paymentPlan = HirePayPlan.deposit,
    this.paymentState = 'none',
    this.price = 0,
    this.depositAmount = 0,
    this.balanceAmount = 0,
    this.paidAmount = 0,
    this.refundedAmount = 0,
    this.cancelFee = 0,
    this.currency,
    this.pickupAddress,
    this.dropAddress,
    this.riderId,
    this.weekdays = const [],
    this.periods,
    this.kmByPeriod = false,
    this.kmPerPeriod,
    this.noticeUntil,
  });

  factory HireDaysBooking.fromRow(Map<String, dynamic> r) {
    final q = r['quote'] is Map ? Map<String, dynamic>.from(r['quote'] as Map) : const <String, dynamic>{};
    return HireDaysBooking(
      id: '${r['id']}',
      package: '${r['package'] ?? hirePackageDaily}',
      title: '${q['title'] ?? 'Hire'}',
      service: '${r['service'] ?? ''}',
      status: '${r['status'] ?? 'booked'}',
      firstAt: DateTime.tryParse('${r['first_at']}')?.toLocal() ?? DateTime.now(),
      days: (_num(r['days']) ?? 1).round(),
      hoursPerDay: _num(r['hours_per_day']) ?? 0,
      kmPerDay: _num(r['km_per_day']),
      overnight: r['overnight'] == true,
      sameDriver: r['same_driver'] != false,
      splitAt: DateTime.tryParse('${r['split_at']}')?.toLocal(),
      partnerId: r['partner_id'] as String?,
      paymentPlan: HirePayPlan.parse(r['payment_plan']),
      paymentState: '${r['payment_state'] ?? 'none'}',
      price: _num(r['price']) ?? 0,
      depositAmount: _num(r['deposit_amount']) ?? 0,
      balanceAmount: _num(r['balance_amount']) ?? 0,
      paidAmount: _num(r['paid_amount']) ?? 0,
      refundedAmount: _num(r['refunded_amount']) ?? 0,
      cancelFee: _num(r['cancel_fee']) ?? 0,
      currency: r['currency'] as String?,
      pickupAddress: r['pickup_address'] as String?,
      dropAddress: r['drop_address'] as String?,
      riderId: r['rider_id'] as String?,
      weekdays: [
        if (r['weekdays'] case final List l)
          for (final d in l) ?_num(d)?.round(),
      ],
      periods: _num(r['periods'])?.round(),
      kmByPeriod: r['km_mode'] == 'period',
      kmPerPeriod: _num(r['km_per_period']),
      noticeUntil: DateTime.tryParse('${r['notice_until']}')?.toLocal(),
    );
  }

  final String id, package, title, service, status;
  final DateTime firstAt;
  final int days;
  final double hoursPerDay;
  final double? kmPerDay;
  final bool overnight, sameDriver;
  final DateTime? splitAt;
  final String? partnerId;
  final HirePayPlan paymentPlan;
  final String paymentState;
  final double price, depositAmount, balanceAmount, paidAmount, refundedAmount, cancelFee;
  final String? currency, pickupAddress, dropAddress, riderId;

  /// Weekly and monthly (0328).
  final List<int> weekdays;
  final int? periods;
  final bool kmByPeriod;
  final double? kmPerPeriod;

  /// A monthly hire cancelled with notice: it ends before this.
  final DateTime? noticeUntil;

  /// "2 weeks from Mon 2 Nov, 9:00 am · Mon to Fri · 8 hr a day", or the
  /// days of a daily hire.
  String get span => periods == null
      ? hireBookingSpan(firstAt, days, hoursPerDay)
      : hirePeriodSpan(package, periods!, weekdays, firstAt, hoursPerDay);

  /// Still to happen or on the go: the rider can cancel it.
  bool get open => const {'booked', 'assigned', 'in_progress'}.contains(status);

  String get statusLabel => switch (status) {
    'booked' when splitAt != null || !sameDriver => 'Finding a driver for each day',
    'in_progress' when noticeUntil != null => 'Ending early, with notice',
    'booked' => 'Finding a driver for every day',
    'assigned' => 'Driver confirmed',
    'in_progress' => 'On the go',
    'completed' => 'Completed',
    'cancelled' => 'Cancelled',
    'expired' => 'No driver found',
    _ => status,
  };

  /// "Paid 340.50 deposit, 794.50 on day 1".
  String paymentText(String Function(double) money) => switch (paymentPlan) {
    HirePayPlan.business => 'Charged to the business account, day by day',
    HirePayPlan.prepay => 'Paid ${money(paidAmount)}',
    HirePayPlan.deposit when paymentState == 'deposit_paid' =>
      'Deposit ${money(depositAmount)} paid, ${money(balanceAmount)} on day 1',
    HirePayPlan.deposit when paymentState == 'balance_short' =>
      'Deposit ${money(depositAmount)} paid; the rest is paid as each day ends',
    HirePayPlan.deposit => 'Paid ${money(paidAmount)}',
  };
}

/// A row of Admin › Hire bookings (hire_bookings_admin, 0328).
class AdminHireBooking {
  const AdminHireBooking({
    required this.id,
    required this.package,
    required this.title,
    required this.status,
    required this.service,
    required this.firstAt,
    this.lastAt,
    required this.days,
    this.price = 0,
    this.paidAmount = 0,
    this.depositAmount = 0,
    this.balanceAmount = 0,
    this.paymentPlan = HirePayPlan.deposit,
    this.paymentState = 'none',
    this.currency,
    this.riderName,
    this.riderPhone,
    this.partnerName,
    this.partnerId,
    this.total = 0,
  });

  factory AdminHireBooking.fromRow(Map<String, dynamic> r) => AdminHireBooking(
    id: '${r['id']}',
    package: '${r['package'] ?? hirePackageDaily}',
    title: '${r['title'] ?? 'Hire'}',
    status: '${r['status'] ?? 'booked'}',
    service: '${r['service'] ?? ''}',
    firstAt: DateTime.tryParse('${r['first_at']}')?.toLocal() ?? DateTime.now(),
    lastAt: DateTime.tryParse('${r['last_at']}')?.toLocal(),
    days: (_num(r['days']) ?? 0).round(),
    price: _num(r['price']) ?? 0,
    paidAmount: _num(r['paid_amount']) ?? 0,
    depositAmount: _num(r['deposit_amount']) ?? 0,
    balanceAmount: _num(r['balance_amount']) ?? 0,
    paymentPlan: HirePayPlan.parse(r['payment_plan']),
    paymentState: '${r['payment_state'] ?? 'none'}',
    currency: r['currency'] as String?,
    riderName: r['rider_name'] as String?,
    riderPhone: r['rider_phone'] as String?,
    partnerName: r['partner_name'] as String?,
    partnerId: r['partner_id'] as String?,
    total: (_num(r['total']) ?? 0).round(),
  );

  final String id, package, title, status, service;
  final DateTime firstAt;
  final DateTime? lastAt;
  final int days;
  final double price, paidAmount, depositAmount, balanceAmount;
  final HirePayPlan paymentPlan;
  final String paymentState;
  final String? currency, riderName, riderPhone, partnerName, partnerId;

  /// How many bookings match the filters (every row carries it).
  final int total;

  /// "Paid", "Deposit paid", "Business account".
  String get paymentLabel => switch (paymentState) {
    'paid' => 'Paid',
    'deposit_paid' => 'Deposit paid',
    'balance_short' => 'Balance not taken',
    'business' => 'Business account',
    _ => 'Not paid',
  };
}

/// A booking a driver can take for all its days (hire_bookings_open).
class OpenHireBooking {
  const OpenHireBooking({
    required this.id,
    required this.title,
    required this.service,
    required this.firstAt,
    required this.days,
    required this.hoursPerDay,
    this.kmPerDay,
    this.overnight = false,
    this.fare = 0,
    this.currency,
    this.pickupAddress,
    this.dropAddress,
    this.dayList = const [],
    this.package = hirePackageDaily,
    this.periods,
    this.weekdays = const [],
    this.kmPerPeriod,
  });

  factory OpenHireBooking.fromRow(Map<String, dynamic> r) => OpenHireBooking(
    id: '${r['id']}',
    title: '${r['title'] ?? 'Hire'}',
    service: '${r['service'] ?? ''}',
    firstAt: DateTime.tryParse('${r['first_at']}')?.toLocal() ?? DateTime.now(),
    days: (_num(r['days']) ?? 1).round(),
    hoursPerDay: _num(r['hours_per_day']) ?? 0,
    kmPerDay: _num(r['km_per_day']),
    overnight: r['overnight'] == true,
    fare: _num(r['fare']) ?? 0,
    currency: r['currency'] as String?,
    pickupAddress: r['pickup_address'] as String?,
    dropAddress: r['drop_address'] as String?,
    dayList: [
      if (r['day_list'] case final List l)
        for (final d in l)
          if (d is Map)
            (
              day: (_num(d['day']) ?? 0).round(),
              at: DateTime.tryParse('${d['pickup_at']}')?.toLocal() ?? DateTime.now(),
              fare: _num(d['fare']) ?? 0,
            ),
    ],
    package: '${r['package'] ?? hirePackageDaily}',
    periods: _num(r['periods'])?.round(),
    weekdays: [
      if (r['weekdays'] case final List l)
        for (final d in l) ?_num(d)?.round(),
    ],
    kmPerPeriod: _num(r['km_per_period']),
  );

  final String id, title, service;
  final DateTime firstAt;
  final int days;
  final double hoursPerDay;
  final double? kmPerDay;
  final bool overnight;
  final double fare;
  final String? currency, pickupAddress, dropAddress;
  final List<({int day, DateTime at, double fare})> dayList;
  final String package;
  final int? periods;
  final List<int> weekdays;
  final double? kmPerPeriod;
}

/// "Day 2 of 3".
String hireDayText(int day, int days) => 'Day $day of $days';

/// "Daily hire · day 2 of 3".
String hireDayTitle(String title, int day, int days) => '$title · day $day of $days';

/// "Mon 2 Nov".
String hireDate(DateTime d) => DateFormat('EEE d MMM').format(d.toLocal());

/// "3 days from Mon 2 Nov, 9:00 am · 10 hr a day".
String hireBookingSpan(DateTime first, int days, double hoursPerDay) =>
    '${days == 1 ? '1 day' : '$days days'} from ${hireDate(first)}, ${hireClock(first)} · '
    '${hireHoursText(hoursPerDay)} a day';

/// "Mon to Fri", "Mon, Wed, Fri", "Every day".
String hireWeekdaysText(List<int> days) {
  final d = [...{...days}]..sort();
  if (d.isEmpty) return 'No day';
  if (d.length == 7) return 'Every day';
  final run = d.length >= 3 && d.last - d.first == d.length - 1;
  if (run) return '${hireWeekdayNames[d.first - 1]} to ${hireWeekdayNames[d.last - 1]}';
  return [for (final x in d) hireWeekdayNames[x - 1]].join(', ');
}

/// "2 weeks from Mon 2 Nov, 9:00 am · Mon to Fri · 8 hr a day".
String hirePeriodSpan(String package, int periods, List<int> weekdays, DateTime first, double hoursPerDay) {
  final word = package == hirePackageMonthly ? 'month' : 'week';
  return '${periods == 1 ? '1 $word' : '$periods ${word}s'} from ${hireDate(first)}, ${hireClock(first)} · '
      '${hireWeekdaysText(weekdays)} · ${hireHoursText(hoursPerDay)} a day';
}

/// The days of a booking from [first] (each at the same local time).
List<DateTime> hireDailyDates(DateTime first, int days) => [
  for (var i = 0; i < days; i++)
    DateTime(first.year, first.month, first.day + i, first.hour, first.minute),
];

/// When a free cancel ends: [hours] before [first].
DateTime hireFreeCancelUntil(DateTime first, int hours) => first.subtract(Duration(hours: hours));

/// What a late cancel costs, in plain words.
String hireLateCancelText(MultiHireConfig c) => switch (c.lateCancel) {
  HireLateCancel.deposit => 'After that the deposit is kept.',
  HireLateCancel.percent => 'After that ${_plain(c.lateCancelPercent)}% of the price is kept.',
  HireLateCancel.firstDay => 'After that the first day is charged.',
};

String _plain(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

/// What the rider reads when the server refuses a multi-day hire.
String? multiHireRefusalText(String? message) {
  final m = message ?? '';
  const codes = {
    'HIRE_DAYS': 'Choose a number of days within the range shown.',
    'HIRE_PERIODS': 'Choose a number of weeks or months within the range shown.',
    'HIRE_WEEKDAYS': 'Choose the days of the week with at least one working day.',
    'HIRE_DEPOSIT_OFF': 'This hire is paid in full when you book it.',
    'HIRE_BUSINESS_OFF': "This hire can't be charged to a business account.",
    'HIRE_LEAD': 'Choose a later first day.',
    'HIRE_AHEAD': 'Choose a sooner first day.',
    'HIRE_PAY': 'This hire is paid from GET.wallet, or charged to a business account.',
    'HIRE_PREPAY_OFF': 'Paying the whole hire now is not offered. Pay the deposit.',
    'HIRE_BOOKING_LIMIT': 'You already have as many hires booked as allowed.',
    'HIRE_WHOLE_BOOKING': 'This hire is taken for all its days: accept it from the hire\'s card.',
    'HIRE_BOOKING_CANCEL': 'Cancel the hire from its booking: its days are cancelled together.',
  };
  for (final e in codes.entries) {
    if (m.contains(e.key)) return e.value;
  }
  return null;
}
