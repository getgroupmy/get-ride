// myGiG part B (migration 0330): bookings for later and hire by time from
// myGiG. Pure logic: the admin's settings (by region, as part A's), what the
// driver chose (Trip / Hourly / Daily / Weekly / Monthly, Now / Later),
// the lead-time check with the server's words, how a booking is paid (the
// owner's no-losses rule, as mygig_booking_plan), and a booking as
// Scheduled myGiG and the passenger's app show it.
import 'mygig.dart' show mygigMoney;

double _d(Object? v, [double fallback = 0]) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? fallback;
int _i(Object? v, [int fallback = 0]) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? fallback;
bool _b(Object? v, [bool fallback = false]) => v is bool ? v : (v == null ? fallback : '$v' == 'true');
String? _s(Object? v) {
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

Map<String, dynamic> _m(Object? v) => v is Map ? Map<String, dynamic>.from(v) : const {};

/// What the driver sends: a trip, or hire by time.
enum MygigKind { trip, hourly, daily, weekly, monthly }

extension MygigKindText on MygigKind {
  /// "Hourly hire".
  String get label => switch (this) {
    MygigKind.trip => 'myGiG ride',
    MygigKind.hourly => 'Hourly hire',
    MygigKind.daily => 'Daily hire',
    MygigKind.weekly => 'Weekly hire',
    MygigKind.monthly => 'Monthly hire',
  };

  /// The chip: "Trip", "Hourly".
  String get chip => switch (this) {
    MygigKind.trip => 'Trip',
    MygigKind.hourly => 'Hourly',
    MygigKind.daily => 'Daily',
    MygigKind.weekly => 'Weekly',
    MygigKind.monthly => 'Monthly',
  };

  bool get hire => this != MygigKind.trip;

  /// Days, weeks and months are booked ahead (no "Now").
  bool get multiDay => this == MygigKind.daily || this == MygigKind.weekly || this == MygigKind.monthly;
}

MygigKind mygigKindFrom(Object? v) =>
    MygigKind.values.firstWhere((k) => k.name == '$v', orElse: () => MygigKind.trip);

/// get.ride's myGiG hire rates, or the driver's own.
class MygigHireRates {
  const MygigHireRates({
    this.hour = 40,
    this.kmHour = 20,
    this.overtime = 45,
    this.extraKm = 1,
    this.day = 350,
    this.kmDay = 200,
    this.week = 1900,
    this.kmWeek = 1200,
    this.month = 7200,
    this.kmMonth = 4500,
    this.overnight = 80,
  });

  factory MygigHireRates.fromJson(Object? raw) {
    final j = _m(raw);
    return MygigHireRates(
      hour: _d(j['hour'], 40),
      kmHour: _d(j['kmHour'], 20),
      overtime: _d(j['overtime'], 45),
      extraKm: _d(j['extraKm'], 1),
      day: _d(j['day'], 350),
      kmDay: _d(j['kmDay'], 200),
      week: _d(j['week'], 1900),
      kmWeek: _d(j['kmWeek'], 1200),
      month: _d(j['month'], 7200),
      kmMonth: _d(j['kmMonth'], 4500),
      overnight: _d(j['overnight'], 80),
    );
  }

  final double hour, kmHour, overtime, extraKm, day, kmDay, week, kmWeek, month, kmMonth, overnight;

  /// "RM40.00 an hour, RM350.00 a day, RM1900.00 a week, RM7200.00 a month".
  String get text =>
      '${mygigMoney(hour)} an hour, ${mygigMoney(day)} a day, ${mygigMoney(week)} a week, ${mygigMoney(month)} a month';
}

/// The admin's settings for later bookings and hire by time where the
/// driver is (mygig_settings_at's `later` and `hire`).
class MygigHireSettings {
  const MygigHireSettings(this.later, this.hire);

  factory MygigHireSettings.of(Map<String, dynamic> settings) =>
      MygigHireSettings(_m(settings['later']), _m(settings['hire']));

  final Map<String, dynamic> later;
  final Map<String, dynamic> hire;

  bool get laterEnabled => _b(later['enabled'], true);
  int get aheadDays => _i(later['aheadDays'], 60);
  int get remindMin => _i(later['remindMin'], 60);
  int get startEarlyMin => _i(later['startEarlyMin'], 60);
  int get payWaitMin => _i(later['payWaitMin'], 30);

  bool get hireEnabled => _b(hire['enabled'], true);
  bool packageOn(MygigKind k) => k == MygigKind.trip || (hireEnabled && _b(_m(hire['packages'])[k.name], true));

  /// Minutes ahead [k] must be booked.
  int leadMin(MygigKind k) => _i(_m(hire['leadMin'])[k.name], switch (k) {
    MygigKind.trip => 30,
    MygigKind.hourly => 60,
    MygigKind.daily => 720,
    MygigKind.weekly => 1440,
    MygigKind.monthly => 2880,
  });

  double get minHours => _d(hire['minHours'], 2);
  double get maxHours => _d(hire['maxHours'], 12);
  double get dayHoursMin => _d(hire['dayHoursMin'], 8);
  double get dayHoursMax => _d(hire['dayHoursMax'], 12);
  int get maxDays => _i(hire['maxDays'], 6);
  int get maxWeeks => _i(hire['maxWeeks'], 4);
  int get maxMonths => _i(hire['maxMonths'], 3);
  double get depositPct => _d(hire['depositPct'], 30);

  double freeCancelHours(MygigKind k) => _d(_m(hire['freeCancelHours'])[k.name], switch (k) {
    MygigKind.trip => 1,
    MygigKind.hourly => 2,
    MygigKind.monthly => 48,
    _ => 24,
  });

  /// 'link' (pay by link first) or 'no' (not offered) for multi-day hire.
  String get nonApp => _s(hire['nonApp']) ?? 'link';
  bool get holidaysSkipped => (_s(hire['holidays']) ?? 'skip') == 'skip';
  int get stepMin => _i(hire['stepMin'], 30);
  MygigHireRates get rates => MygigHireRates.fromJson(hire['rates']);
  bool get allowOwnRates => _b(hire['allowOwnRates'], true);
  Map<String, dynamic> get ownLimits => _m(hire['ownLimits']);

  /// The hours a day the driver can pick (8, 10, 12 by default).
  List<double> get dayHourChoices => [
    for (var h = dayHoursMin; h <= dayHoursMax + 1e-9; h += 2) h,
    if ((dayHoursMax - dayHoursMin) % 2 != 0) dayHoursMax,
  ];
}

/// The driver's own hire choices (prefs.hire).
class MygigHirePrefs {
  const MygigHirePrefs(this.raw);
  final Map<String, dynamic> raw;

  factory MygigHirePrefs.of(Map<String, dynamic> prefs) => MygigHirePrefs(_m(prefs['hire']));

  bool offers(MygigKind k) => k == MygigKind.trip || _b(_m(raw['offer'])[k.name], true);
  bool get own => _b(raw['own']);
  MygigHireRates get rates => MygigHireRates.fromJson(raw['rates']);
}

/// The packages the driver can send here, Trip first.
List<MygigKind> mygigKindsOn(MygigHireSettings s, MygigHirePrefs p) =>
    [for (final k in MygigKind.values) if (s.packageOn(k) && p.offers(k)) k];

/// "30 min", "1 hour", "12 hours", "2 days" (as the server's mygig_lead_text).
String mygigLeadText(int minutes) {
  if (minutes < 60) return '$minutes min';
  if (minutes < 1440 || minutes % 1440 != 0) {
    final h = minutes / 60;
    final n = h == h.roundToDouble() ? h.toStringAsFixed(0) : h.toStringAsFixed(1);
    return minutes == 60 ? '1 hour' : '$n hours';
  }
  final d = minutes ~/ 1440;
  return d == 1 ? '1 day' : '$d days';
}

/// Mon..Sun, ISO numbers 1..7.
const mygigWeekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Mon to Fri", "Mon, Wed, Fri".
String mygigWeekdaysText(List<int> days) {
  final d = [...days]..sort();
  if (d.length >= 3 && d.last - d.first == d.length - 1) {
    return '${mygigWeekdayNames[d.first - 1]} to ${mygigWeekdayNames[d.last - 1]}';
  }
  return d.map((x) => mygigWeekdayNames[(x - 1).clamp(0, 6)]).join(', ');
}

/// "6:30 pm".
String mygigClock(int minuteOfDay) {
  final h = minuteOfDay ~/ 60, m = minuteOfDay % 60;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:${m.toString().padLeft(2, '0')} ${h < 12 ? 'am' : 'pm'}';
}

/// "Mon 2 Nov" / "Today" / "Tomorrow" for [day] seen from [now].
String mygigDayText(DateTime day, DateTime now) {
  final d = DateTime(day.year, day.month, day.day), n = DateTime(now.year, now.month, now.day);
  final diff = d.difference(n).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  return '${mygigWeekdayNames[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
}

/// "Today, 6:30 pm".
String mygigWhenText(DateTime at, DateTime now) =>
    '${mygigDayText(at, now)}, ${mygigClock(at.hour * 60 + at.minute)}';

/// The start times the driver picks from, every 15 minutes.
List<int> get mygigTimeChoices => [for (var m = 0; m < 24 * 60; m += 15) m];

/// What the driver chose on the trip details: the kind, now or later, and
/// the package's options.
class MygigBookingChoice {
  const MygigBookingChoice({
    this.kind = MygigKind.trip,
    this.later = false,
    this.at,
    this.hours = 3,
    this.days = 2,
    this.hoursPerDay = 10,
    this.periods = 1,
    this.weekdays = const [1, 2, 3, 4, 5],
    this.overnight = false,
  });

  final MygigKind kind;
  final bool later;
  final DateTime? at;
  final double hours;
  final int days;
  final double hoursPerDay;
  final int periods;
  final List<int> weekdays;
  final bool overnight;

  /// Days, weeks and months always start later.
  bool get isLater => later || kind.multiDay;

  /// A booking (anything but a trip now).
  bool get isBooking => isLater || kind.hire;

  MygigBookingChoice copyWith({
    MygigKind? kind,
    bool? later,
    DateTime? at,
    bool clearAt = false,
    double? hours,
    int? days,
    double? hoursPerDay,
    int? periods,
    List<int>? weekdays,
    bool? overnight,
  }) => MygigBookingChoice(
    kind: kind ?? this.kind,
    later: later ?? this.later,
    at: clearAt ? null : at ?? this.at,
    hours: hours ?? this.hours,
    days: days ?? this.days,
    hoursPerDay: hoursPerDay ?? this.hoursPerDay,
    periods: periods ?? this.periods,
    weekdays: weekdays ?? this.weekdays,
    overnight: overnight ?? this.overnight,
  );

  /// As mygig_create and mygig_quote take it (`booking`).
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'when': isLater ? 'later' : 'now',
    if (isLater && at != null) 'at': at!.toUtc().toIso8601String(),
    if (kind == MygigKind.hourly) 'hours': hours,
    if (kind == MygigKind.daily) 'days': days,
    if (kind.multiDay) 'hoursPerDay': hoursPerDay,
    if (kind == MygigKind.weekly || kind == MygigKind.monthly) ...{'periods': periods, 'weekdays': weekdays},
    if (kind == MygigKind.daily) 'overnight': overnight,
  };

  /// "Daily hire · 2 days, 10 h a day".
  String get whatText => switch (kind) {
    MygigKind.trip => 'myGiG ride',
    MygigKind.hourly => 'Hourly hire · ${_h(hours)} hours',
    MygigKind.daily => 'Daily hire · $days day${days == 1 ? '' : 's'}, ${_h(hoursPerDay)} h a day',
    MygigKind.weekly =>
      'Weekly hire · $periods week${periods == 1 ? '' : 's'}, ${mygigWeekdaysText(weekdays)}, ${_h(hoursPerDay)} h a day',
    MygigKind.monthly =>
      'Monthly hire · $periods month${periods == 1 ? '' : 's'}, ${mygigWeekdaysText(weekdays)}, ${_h(hoursPerDay)} h a day',
  };
}

String _h(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// Why the booking's time can't be (the server's words), or null.
String? mygigWhenProblem(MygigBookingChoice c, MygigHireSettings s, DateTime now) {
  if (!c.isLater) return null;
  if (!s.laterEnabled) return 'Bookings for later aren’t offered here.';
  final at = c.at;
  if (at == null) return 'Choose the start date and time.';
  if (!at.isAfter(now)) return 'That time has passed. Choose a later time.';
  final lead = s.leadMin(c.kind);
  if (at.isBefore(now.add(Duration(minutes: lead)))) {
    return '${c.kind == MygigKind.trip ? 'A later ride' : c.kind.label} must start at least ${mygigLeadText(lead)} from now.';
  }
  if (at.isAfter(now.add(Duration(days: s.aheadDays)))) return 'Bookings go up to ${s.aheadDays} days ahead.';
  return null;
}

/// "Later rides must be booked at least 30 min ahead (set by get.ride)."
String mygigLeadNote(MygigKind k, MygigHireSettings s) =>
    '${k == MygigKind.trip ? 'Later rides' : k.label} must be booked at least ${mygigLeadText(s.leadMin(k))} ahead '
    '(set by get.ride). Saved in your Scheduled myGiG. You both get a reminder before.';

/// How a booking is paid (mygig_booking_plan).
enum MygigPlanKind { now, start, linkFirst, deposit, full, business }

class MygigPlan {
  const MygigPlan({
    required this.kind,
    this.payNow = 0,
    this.payNowByLink = false,
    this.balance = 0,
    this.balanceByApp = false,
    this.problem,
  });

  final MygigPlanKind kind;
  final double payNow;
  final bool payNowByLink;
  final double balance;
  final bool balanceByApp;

  /// Not offered (nonApp 'no'): why.
  final String? problem;
}

double _cents(double v) => (v * 100).roundToDouble() / 100;

/// As the server's mygig_booking_plan: [pay] is 'cash', 'wallet', 'link',
/// 'family' or 'business'.
MygigPlan mygigPlanFor(MygigBookingChoice c, String pay, {required bool registered, required MygigHireSettings s,
    required double total}) {
  final inApp = registered && (pay == 'wallet' || pay == 'family');
  if (!c.isLater) return const MygigPlan(kind: MygigPlanKind.now);
  if (pay == 'business') return const MygigPlan(kind: MygigPlanKind.business);
  if (c.kind == MygigKind.trip || c.kind == MygigKind.hourly) {
    return inApp
        ? MygigPlan(kind: MygigPlanKind.start, balance: total, balanceByApp: true)
        : MygigPlan(kind: MygigPlanKind.linkFirst, payNow: total, payNowByLink: true);
  }
  final problem = !inApp && s.nonApp == 'no'
      ? '${c.kind.label} needs a registered passenger paying in the app (set by get.ride).'
      : null;
  if (c.kind == MygigKind.daily) {
    final dep = _cents(total * s.depositPct / 100);
    return MygigPlan(kind: MygigPlanKind.deposit, payNow: dep, payNowByLink: !inApp, balance: _cents(total - dep),
        balanceByApp: inApp, problem: problem);
  }
  return MygigPlan(kind: MygigPlanKind.full, payNow: total, payNowByLink: !inApp, problem: problem);
}

/// The payment box on the trip details: {title, body}.
({String title, String body}) mygigPlanText(MygigBookingChoice c, MygigPlan p, MygigHireSettings s,
    {required String payName, String? business, String balanceHow = 'cash or by link'}) {
  final kept = c.kind == MygigKind.daily ? 'deposit' : 'payment';
  final cancel = 'Free to cancel until ${_h(s.freeCancelHours(c.kind))} h before the start; after that the $kept is kept.';
  switch (p.kind) {
    case MygigPlanKind.now:
      return (
        title: 'Paid as a myGiG ride',
        body: 'Overtime and extra km are added at the end, with tolls and parking. Nothing can be charged after the fact '
            'to a passenger without in-app payment, so they pay before the trip ends.',
      );
    case MygigPlanKind.business:
      return (title: 'On ${business ?? 'the business account'}’s monthly invoice', body: 'Nothing to pay now. $cancel');
    case MygigPlanKind.start:
      return (title: 'Charged when you start', body: 'From $payName, when you start the ${c.kind == MygigKind.trip ? 'ride' : 'hire'}. $cancel');
    case MygigPlanKind.linkFirst:
      return (
        title: '${mygigMoney(p.payNow)} by link to confirm',
        body: 'Nothing can be charged later without in-app payment, so the booking is confirmed once this is paid '
            '(card, FPX or DuitNow). $cancel',
      );
    case MygigPlanKind.deposit:
      return p.payNowByLink
          ? (
              title: 'Deposit ${mygigMoney(p.payNow)} by link to confirm',
              body: 'Nothing can be charged later, so the booking is confirmed once the deposit is paid (card, FPX or '
                  'DuitNow). The balance ${mygigMoney(p.balance)} is paid before day 1 starts, $balanceHow. $cancel',
            )
          : (
              title: 'Deposit ${mygigMoney(p.payNow)} (${_h(s.depositPct)}%) when they accept',
              body: 'From $payName. The balance ${mygigMoney(p.balance)} is charged before day 1 starts. $cancel',
            );
    case MygigPlanKind.full:
      return p.payNowByLink
          ? (
              title: '${mygigMoney(p.payNow)} in full by link to confirm',
              body: 'Nothing can be charged later, so the booking is confirmed once this is paid (card, FPX or DuitNow). '
                  '$cancel',
            )
          : (title: '${mygigMoney(p.payNow)} in full when they accept', body: 'From $payName. $cancel');
  }
}

/// A booking as Scheduled myGiG, the passenger's app and the trip link
/// show it (mygig_booking_json).
class MygigBooking {
  const MygigBooking(this.raw);
  final Map<String, dynamic> raw;

  String get id => '${raw['id'] ?? ''}';
  MygigKind get kind => mygigKindFrom(raw['kind']);
  String get title => _s(raw['title']) ?? kind.label;
  String get status => _s(raw['status']) ?? 'booked';
  DateTime? get firstAt => DateTime.tryParse('${raw['firstAt'] ?? ''}')?.toLocal();
  DateTime? get lastAt => DateTime.tryParse('${raw['lastAt'] ?? ''}')?.toLocal();
  int get days => _i(raw['days'], 1);
  int get daysDone => _i(raw['daysDone']);
  double get price => _d(raw['price']);
  String get pay => _s(raw['pay']) ?? 'cash';
  String get plan => _s(raw['plan']) ?? 'start';
  double get payNow => _d(raw['payNow']);
  String get payNowBy => _s(raw['payNowBy']) ?? 'none';
  double get paid => _d(raw['paid']);
  double get due => _d(raw['due']);
  double get linkOwed => _d(raw['linkOwed']);
  String? get payUrl => _s(raw['payUrl']);
  DateTime? get freeCancelUntil => DateTime.tryParse('${raw['freeCancelUntil'] ?? ''}')?.toLocal();
  bool get canCancel => _b(raw['canCancel']);
  bool get cancelFree => _b(raw['cancelFree']);
  double get keepIfCancelled => _d(raw['keepIfCancelled']);
  Map<String, dynamic> get trip => _m(raw['trip']);
  bool get directed => _b(trip['directed']);
  String get pickupName => '${_m(trip['pickup'])['name'] ?? 'the pickup'}';
  String get dropName => '${_m(trip['drop'])['name'] ?? 'the drop-off'}';
  double get hoursPerDay => _d(raw['hoursPerDay'], 10);
  double get hours => _d(raw['hours'], 0);
  List<int> get weekdays => [for (final w in (raw['weekdays'] is List ? raw['weekdays'] as List : const [])) _i(w)];
  Map<String, dynamic> get nextDay => _m(raw['nextDay']);
  bool get canStart => _b(nextDay['canStart']);
  DateTime? get startFrom => DateTime.tryParse('${nextDay['startFrom'] ?? ''}')?.toLocal();
  DateTime? get nextAt => DateTime.tryParse('${nextDay['at'] ?? ''}')?.toLocal();
  String? get dayText => _s(raw['dayText']);
  String? get rideId => _s(raw['rideId']);
  String? get rideStatus => _s(raw['rideStatus']);
  String get name => _s(raw['name']) ?? 'myGiG passenger';
  String? get phone => _s(raw['phone']);
  bool get registered => _b(raw['registered']);
  Map<String, dynamic> get driver => _m(raw['driver']);
  double get refundDue => _d(raw['refundDue']);
  bool get awaitingPayment => status == 'awaiting_payment';
  bool get open => status == 'awaiting_payment' || status == 'booked' || status == 'in_progress';

  /// "To Sentral" / "Weekly hire · Mon to Fri, 10 h a day".
  String get whatText => switch (kind) {
    MygigKind.trip => 'To $dropName',
    MygigKind.hourly => 'Hourly hire · ${_h(hours)} hours${directed ? ', as directed' : ''}',
    MygigKind.daily => 'Daily hire · $days day${days == 1 ? '' : 's'}, ${_h(hoursPerDay)} h a day',
    _ => '$title · ${mygigWeekdaysText(weekdays)}, ${_h(hoursPerDay)} h a day',
  };

  /// What is paid, for the driver's card: "RM120.00 paid by link".
  String get payText {
    if (plan == 'business') return 'Monthly invoice';
    if (awaitingPayment) return 'Waiting for ${mygigMoney(linkOwed)} by link';
    if (paid >= price - 0.005 && price > 0) return '${mygigMoney(paid)} paid';
    if (paid > 0) return '${mygigMoney(paid)} paid, ${mygigMoney(due)} before day 1';
    if (plan == 'start') return 'Charged when the ride starts';
    return 'Pays ${mygigMoney(due)} before it starts';
  }

  /// "Free to cancel until Sun 1 Nov, 8:00 am" / "A late cancel keeps RM105.00".
  String cancelText(DateTime now) {
    final until = freeCancelUntil;
    if (until != null && now.isBefore(until)) return 'Free to cancel until ${mygigWhenText(until, now)}';
    if (keepIfCancelled > 0) return 'Cancelling now keeps ${mygigMoney(keepIfCancelled)} for the driver';
    return 'Cancelling now is free';
  }

  /// "Ends · Mon 2 Nov, 6:00 pm" etc. for the start line.
  String whenText(DateTime now) => firstAt == null ? '' : mygigWhenText(firstAt!, now);

  /// The status, in words.
  String get statusText => switch (status) {
    'awaiting_payment' => 'Waiting for payment',
    'booked' => 'Booked',
    'in_progress' => 'Going',
    'completed' => 'Done',
    'cancelled' => 'Cancelled',
    'expired' => 'Ended',
    _ => status,
  };
}

/// The bookings Scheduled myGiG lists, soonest first.
List<MygigBooking> mygigBookingsFrom(Object? v) => [
  for (final b in (v is List ? v : const [])) if (b is Map) MygigBooking(Map<String, dynamic>.from(b)),
]..sort((a, b) => (a.firstAt ?? DateTime(9999)).compareTo(b.firstAt ?? DateTime(9999)));

/// A hire ride's day as the driver's trip card shows it: the time used
/// today, overtime past the day's hours (in the hire's steps) and the km.
({int usedMin, int overtimeMin, double overtime, String used}) mygigHireNow({
  required DateTime? startedAt,
  required double hours,
  required int stepMin,
  required double overtimeRate,
  required DateTime now,
}) {
  if (startedAt == null) return (usedMin: 0, overtimeMin: 0, overtime: 0, used: '0 h');
  final used = now.difference(startedAt).inMinutes.clamp(0, 100000);
  final over = used - (hours * 60).round();
  final step = stepMin < 1 ? 30 : stepMin;
  final overMin = over <= 0 ? 0 : ((over + step - 1) ~/ step) * step;
  final text = '${used ~/ 60} h${used % 60 == 0 ? '' : ' ${used % 60} min'}';
  return (usedMin: used, overtimeMin: overMin, overtime: _cents(overMin / 60 * overtimeRate), used: text);
}

/// The rates a hire is priced with (the server's mygig_hire_card): the
/// driver's own when they chose them and the admin allows it (with
/// get.ride's km and extra km), else get.ride's.
MygigHireRates mygigHireCard(MygigHireSettings s, MygigHirePrefs p) {
  if (!(p.own && s.allowOwnRates)) return s.rates;
  final own = _m(p.raw['rates']);
  return MygigHireRates.fromJson({..._m(s.hire['rates']), for (final e in own.entries) if (e.value != null) e.key: e.value});
}

/// The driver's popup once the passenger accepted a booking ([booking] is
/// the offer's): "Ravi · Weekly hire from Mon 2 Nov, 8:00 am, RM1900.00.
/// RM1900.00 paid now. It is in your Scheduled myGiG, and you both get a
/// reminder before."
String mygigBookedText({required String name, required Map<String, dynamic> booking, required double total,
    required DateTime now, String? status}) {
  final kind = mygigKindFrom(booking['kind']);
  final at = DateTime.tryParse('${booking['at'] ?? ''}')?.toLocal();
  final payNow = _d(booking['payNow']);
  final paid = switch ('${booking['plan'] ?? ''}') {
    _ when status == 'awaiting_payment' || booking['payNowBy'] == 'link' =>
      'It is confirmed once they pay ${mygigMoney(payNow)} by link (sent to their phone).',
    'deposit' => '${mygigMoney(payNow)} paid now as the deposit.',
    'full' => '${mygigMoney(payNow)} paid now.',
    'business' => 'On the business account’s monthly invoice.',
    'start' => 'Charged in the app when you start.',
    _ => 'Paid as a myGiG ride.',
  };
  return '$name · ${kind == MygigKind.trip ? 'myGiG ride' : kind.label}${at == null ? '' : ' from ${mygigWhenText(at, now)}'}, '
      '${mygigMoney(total)}. $paid It is in your Scheduled myGiG, and you both get a reminder before.';
}
