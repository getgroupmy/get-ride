// Admin > Dashboard, the "Command Centre" (migration 0261): the periods
// and what each is compared with, in Malaysia's days; the answers of
// admin_dashboard_summary and admin_dashboard_live as models; the KPIs, the
// change against the previous period and whether it is good news; and the
// small formatting the page needs. Pure.
import 'dart:math' as math;

import 'package:intl/intl.dart';

import 'date_order.dart' show formatDateForUser;
import 'format.dart' show formatMoney;
import 'partner_statement.dart' show malaysiaDate, malaysiaMidnight, statementWeekStart;

// ---- Periods ----------------------------------------------------------------------------------------
enum DashboardPeriod {
  today('Today'),
  yesterday('Yesterday'),
  week('This week'),
  month('This month'),
  custom('Custom');

  const DashboardPeriod(this.label);
  final String label;

  static DashboardPeriod? byName(String? name) {
    for (final p in values) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// How the chart and the sparklines cut a period up.
enum DashboardBucket {
  hour,
  day;

  /// As `admin_dashboard_summary` takes it.
  String get db => name;
}

/// The longest custom period, in days (the server takes 400).
const dashboardMaxDays = 366;

/// Malaysia's offset from UTC (no daylight saving).
const _myt = Duration(hours: 8);

/// A period and the one it is compared with, as instants, and its days
/// (UTC dates holding Malaysia's calendar day).
class DashboardRange {
  const DashboardRange({
    required this.period,
    required this.from,
    required this.to,
    required this.prevFrom,
    required this.prevTo,
    required this.bucket,
    required this.first,
    required this.last,
  });

  final DashboardPeriod period;

  /// The period [from, to) and the previous one [prevFrom, prevTo).
  final DateTime from, to, prevFrom, prevTo;
  final DashboardBucket bucket;

  /// The period's first and last day.
  final DateTime first, last;

  int get days => last.difference(first).inDays + 1;

  /// One day, cut into hours.
  bool get oneDay => bucket == DashboardBucket.hour;

  /// How many slots the chart's axis has: a day's 24 hours, a week's 7
  /// days, else as many as there are buckets.
  int axisSlots(int buckets) => oneDay
      ? 24
      : period == DashboardPeriod.week
      ? 7
      : math.max(buckets, period == DashboardPeriod.custom ? days : 1);

  @override
  bool operator ==(Object other) =>
      other is DashboardRange &&
      other.period == period &&
      other.from == from &&
      other.to == to &&
      other.prevFrom == prevFrom &&
      other.prevTo == prevTo &&
      other.bucket == bucket;

  @override
  int get hashCode => Object.hash(period, from, to, prevFrom, prevTo, bucket);

  @override
  String toString() => 'DashboardRange(${period.name}, $from..$to vs $prevFrom..$prevTo, ${bucket.name})';
}

DateTime _day(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// [period] at [now], in Malaysia's days, and what it is compared with:
///  * Today, from midnight to now, against yesterday up to the same time;
///  * Yesterday against the day before;
///  * This week (from Monday) up to now, against the same days and time of
///    last week;
///  * This month up to now against the same days of last month (no further
///    than its end);
///  * Custom, [first] to [last] (whole days, either order, at most
///    [dashboardMaxDays]), against as many days immediately before.
DashboardRange dashboardRange(DashboardPeriod period, DateTime now, {DateTime? first, DateTime? last}) {
  final today = malaysiaDate(now);
  final at = now.toUtc();
  const day = Duration(days: 1);
  // A period that has just begun still spans a moment.
  DateTime upTo(DateTime from) => at.isAfter(from.add(const Duration(minutes: 1))) ? at : from.add(const Duration(minutes: 1));
  switch (period) {
    case DashboardPeriod.today:
      final from = malaysiaMidnight(today);
      final to = upTo(from);
      return DashboardRange(
        period: period,
        from: from,
        to: to,
        prevFrom: from.subtract(day),
        prevTo: to.subtract(day),
        bucket: DashboardBucket.hour,
        first: today,
        last: today,
      );
    case DashboardPeriod.yesterday:
      final y = today.subtract(day);
      return DashboardRange(
        period: period,
        from: malaysiaMidnight(y),
        to: malaysiaMidnight(today),
        prevFrom: malaysiaMidnight(y.subtract(day)),
        prevTo: malaysiaMidnight(y),
        bucket: DashboardBucket.hour,
        first: y,
        last: y,
      );
    case DashboardPeriod.week:
      final monday = statementWeekStart(today);
      final from = malaysiaMidnight(monday);
      final to = upTo(from);
      const week = Duration(days: 7);
      return DashboardRange(
        period: period,
        from: from,
        to: to,
        prevFrom: from.subtract(week),
        prevTo: to.subtract(week),
        bucket: DashboardBucket.day,
        first: monday,
        last: today,
      );
    case DashboardPeriod.month:
      final firstDay = DateTime.utc(today.year, today.month);
      final from = malaysiaMidnight(firstDay);
      final to = upTo(from);
      final prevFrom = malaysiaMidnight(DateTime.utc(today.year, today.month - 1));
      final same = prevFrom.add(to.difference(from));
      return DashboardRange(
        period: period,
        from: from,
        to: to,
        prevFrom: prevFrom,
        prevTo: same.isAfter(from) ? from : same,
        bucket: DashboardBucket.day,
        first: firstDay,
        last: today,
      );
    case DashboardPeriod.custom:
      var a = _day(first ?? today);
      var b = _day(last ?? first ?? today);
      if (b.isBefore(a)) (a, b) = (b, a);
      if (b.difference(a).inDays + 1 > dashboardMaxDays) a = b.subtract(const Duration(days: dashboardMaxDays - 1));
      final days = b.difference(a).inDays + 1;
      final from = malaysiaMidnight(a);
      return DashboardRange(
        period: period,
        from: from,
        to: malaysiaMidnight(b.add(day)),
        prevFrom: malaysiaMidnight(a.subtract(Duration(days: days))),
        prevTo: from,
        bucket: days == 1 ? DashboardBucket.hour : DashboardBucket.day,
        first: a,
        last: b,
      );
  }
}

/// [at] on Malaysia's clock, in UTC fields.
DateTime malaysiaClock(DateTime at) => at.toUtc().add(_myt);

String _two(int n) => n.toString().padLeft(2, '0');

/// The line under the period bar: what is shown, and what it is compared
/// with. A custom period's days read in the admin's own date order.
String dashboardRangeText(DashboardRange r, DateTime now) {
  final d = DateFormat('EEE d MMM yyyy');
  final dm = DateFormat('EEE d MMM');
  final clock = malaysiaClock(now);
  final hm = '${_two(clock.hour)}:${_two(clock.minute)}';
  switch (r.period) {
    case DashboardPeriod.today:
      return '${d.format(r.first)}, 00:00 to $hm · compared with yesterday to $hm';
    case DashboardPeriod.yesterday:
      return '${d.format(r.first)} · compared with ${dm.format(r.first.subtract(const Duration(days: 1)))}';
    case DashboardPeriod.week:
      final span = r.first == r.last
          ? d.format(r.first)
          : r.first.month == r.last.month
          ? '${DateFormat('EEE d').format(r.first)} to ${d.format(r.last)}'
          : '${dm.format(r.first)} to ${d.format(r.last)}';
      return '$span · compared with the same days last week';
    case DashboardPeriod.month:
      final prevFirst = malaysiaClock(r.prevFrom);
      final prevLast = malaysiaClock(r.prevTo.subtract(const Duration(seconds: 1)));
      final m = DateFormat('MMM');
      return '${r.first.day} to ${r.last.day} ${DateFormat('MMM yyyy').format(r.last)} · compared with '
          '${prevFirst.day} to ${prevLast.day} ${m.format(prevFirst)}';
    case DashboardPeriod.custom:
      String typed(DateTime x) => formatDateForUser(DateTime(x.year, x.month, x.day));
      final n = r.days;
      final span = n == 1 ? typed(r.first) : '${typed(r.first)} to ${typed(r.last)}';
      return '$span · compared with ${n == 1 ? 'the day before' : 'the $n days before'}';
  }
}

/// The label of the chart's axis slot [i]: "09:00" for an hour, the
/// weekday for a week, "21 Oct" for a longer span.
String dashboardSlotLabel(DashboardRange r, int i) {
  if (r.oneDay) return '${_two(i)}:00';
  final day = r.first.add(Duration(days: i));
  if (r.period == DashboardPeriod.week || r.days <= 7) return DateFormat('EEE').format(day);
  return DateFormat('d MMM').format(day);
}

// ---- The period the admin last chose -----------------------------------------------------------------
class DashboardChoice {
  const DashboardChoice(this.period, {this.first, this.last});

  static const initial = DashboardChoice(DashboardPeriod.today);

  final DashboardPeriod period;

  /// A custom period's days (local dates).
  final DateTime? first, last;

  Map<String, dynamic> toJson() => {
    'period': period.name,
    if (first != null) 'first': _ymd(first!),
    if (last != null) 'last': _ymd(last!),
  };

  static DashboardChoice fromJson(Object? json) {
    if (json is! Map) return initial;
    final p = DashboardPeriod.byName(json['period'] as String?);
    if (p == null) return initial;
    final a = DateTime.tryParse('${json['first'] ?? ''}');
    final b = DateTime.tryParse('${json['last'] ?? ''}');
    if (p == DashboardPeriod.custom && (a == null || b == null)) return initial;
    return DashboardChoice(p, first: a, last: b);
  }

  @override
  bool operator ==(Object other) =>
      other is DashboardChoice && other.period == period && other.first == first && other.last == last;

  @override
  int get hashCode => Object.hash(period, first, last);
}

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

// ---- The answers --------------------------------------------------------------------------------------
int _i(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
double _d(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
double? _dn(Object? v) => v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));
String? _s(Object? v) {
  final s = v?.toString().trim() ?? '';
  return s.isEmpty ? null : s;
}

Map<String, dynamic> _m(Object? v) => v is Map ? Map<String, dynamic>.from(v) : const {};
List<Map<String, dynamic>> _l(Object? v) => [
  if (v is List)
    for (final e in v)
      if (e is Map) Map<String, dynamic>.from(e),
];

class DashboardKpis {
  const DashboardKpis({
    this.trips = 0,
    this.bookings = 0,
    this.commission = 0,
    this.ridersActive = 0,
    this.requests = 0,
    this.accepted = 0,
    this.cancelled = 0,
    this.expired = 0,
    this.newRiders = 0,
    this.newPartners = 0,
  });

  factory DashboardKpis.fromJson(Map<String, dynamic> j) => DashboardKpis(
    trips: _i(j['trips']),
    bookings: _d(j['bookings']),
    commission: _d(j['commission']),
    ridersActive: _i(j['riders_active']),
    requests: _i(j['requests']),
    accepted: _i(j['accepted']),
    cancelled: _i(j['cancelled']),
    expired: _i(j['expired']),
    newRiders: _i(j['new_riders']),
    newPartners: _i(j['new_partners']),
  );

  final int trips, ridersActive, requests, accepted, cancelled, expired, newRiders, newPartners;
  final double bookings, commission;

  double? get averageFare => trips == 0 ? null : bookings / trips;
  double? get acceptanceRate => requests == 0 ? null : accepted / requests;
  double? get cancellationRate => requests == 0 ? null : cancelled / requests;
}

/// One bucket; [start] holds Malaysia's wall clock in UTC fields.
class DashboardBucketRow {
  const DashboardBucketRow({
    required this.start,
    this.trips = 0,
    this.bookings = 0,
    this.commission = 0,
    this.riders = 0,
    this.requests = 0,
    this.accepted = 0,
    this.cancelled = 0,
    this.newRiders = 0,
    this.newPartners = 0,
  });

  factory DashboardBucketRow.fromJson(Map<String, dynamic> j) {
    final s = '${j['start'] ?? ''}';
    return DashboardBucketRow(
      start: DateTime.tryParse(s.endsWith('Z') ? s : '${s}Z') ?? DateTime.utc(1970),
      trips: _i(j['trips']),
      bookings: _d(j['bookings']),
      commission: _d(j['commission']),
      riders: _i(j['riders']),
      requests: _i(j['requests']),
      accepted: _i(j['accepted']),
      cancelled: _i(j['cancelled']),
      newRiders: _i(j['new_riders']),
      newPartners: _i(j['new_partners']),
    );
  }

  final DateTime start;
  final int trips, riders, requests, accepted, cancelled, newRiders, newPartners;
  final double bookings, commission;

  double metric(DashboardMetric m) => switch (m) {
    DashboardMetric.trips => trips.toDouble(),
    DashboardMetric.bookings => bookings,
    DashboardMetric.riders => riders.toDouble(),
  };
}

/// What the chart shows.
enum DashboardMetric {
  trips('Trips'),
  bookings('Bookings'),
  riders('Active riders');

  const DashboardMetric(this.label);
  final String label;
}

class DashboardFunnel {
  const DashboardFunnel({this.requests = 0, this.offered = 0, this.accepted = 0, this.pickedUp = 0, this.completed = 0});

  factory DashboardFunnel.fromJson(Map<String, dynamic> j) => DashboardFunnel(
    requests: _i(j['requests']),
    offered: _i(j['offered']),
    accepted: _i(j['accepted']),
    pickedUp: _i(j['picked_up']),
    completed: _i(j['completed']),
  );

  final int requests, offered, accepted, pickedUp, completed;

  /// The steps in order, each with its share of the requests (null for the first).
  List<({String label, int count, double? share})> get steps {
    double? of(int n) => requests == 0 ? 0 : n / requests;
    return [
      (label: 'Requests', count: requests, share: null),
      (label: 'Got an offer', count: offered, share: of(offered)),
      (label: 'Accepted', count: accepted, share: of(accepted)),
      (label: 'Picked up', count: pickedUp, share: of(pickedUp)),
      (label: 'Completed', count: completed, share: of(completed)),
    ];
  }
}

/// A service's or a payment method's trips and bookings.
class DashboardMix {
  const DashboardMix({required this.name, required this.trips, required this.bookings});

  factory DashboardMix.fromJson(Map<String, dynamic> j) =>
      DashboardMix(name: _s(j['name']) ?? 'Other', trips: _i(j['trips']), bookings: _d(j['bookings']));

  final String name;
  final int trips;
  final double bookings;
}

class DashboardHeatCell {
  const DashboardHeatCell(this.dow, this.hour, this.n);

  factory DashboardHeatCell.fromJson(Map<String, dynamic> j) => DashboardHeatCell(_i(j['dow']), _i(j['hour']), _i(j['n']));

  /// ISO day of the week (1 Monday) and hour, Malaysia's.
  final int dow, hour, n;
}

/// The demand grid: one row of 24 hours for a one-day period, else a row
/// per day of the week, Monday first.
List<List<int>> dashboardHeatRows(List<DashboardHeatCell> cells, {required bool oneRow}) {
  final rows = List.generate(oneRow ? 1 : 7, (_) => List.filled(24, 0));
  for (final c in cells) {
    if (c.hour < 0 || c.hour > 23 || c.dow < 1 || c.dow > 7) continue;
    rows[oneRow ? 0 : c.dow - 1][c.hour] += c.n;
  }
  return rows;
}

class DashboardQuality {
  const DashboardQuality({
    this.ratingAvg,
    this.ratings = 0,
    this.driverCancels = 0,
    this.riderCancels = 0,
    this.pickupMin,
    this.complaints = 0,
  });

  factory DashboardQuality.fromJson(Map<String, dynamic> j) => DashboardQuality(
    ratingAvg: _dn(j['rating_avg']),
    ratings: _i(j['ratings']),
    driverCancels: _i(j['driver_cancels']),
    riderCancels: _i(j['rider_cancels']),
    pickupMin: _dn(j['pickup_min']),
    complaints: _i(j['complaints']),
  );

  final double? ratingAvg, pickupMin;
  final int ratings, driverCancels, riderCancels, complaints;
}

/// One period's figures.
class DashboardPeriodFigures {
  const DashboardPeriodFigures({
    this.currency = 'MYR',
    this.kpis = const DashboardKpis(),
    this.buckets = const [],
    this.funnel = const DashboardFunnel(),
    this.services = const [],
    this.payments = const [],
    this.heat = const [],
    this.quality = const DashboardQuality(),
  });

  factory DashboardPeriodFigures.fromJson(Map<String, dynamic> j) => DashboardPeriodFigures(
    currency: _s(j['currency']) ?? 'MYR',
    kpis: DashboardKpis.fromJson(_m(j['kpis'])),
    buckets: [for (final b in _l(j['buckets'])) DashboardBucketRow.fromJson(b)],
    funnel: DashboardFunnel.fromJson(_m(j['funnel'])),
    services: [for (final s in _l(j['services'])) DashboardMix.fromJson(s)],
    payments: [for (final s in _l(j['payments'])) DashboardMix.fromJson(s)],
    heat: [for (final s in _l(j['heat'])) DashboardHeatCell.fromJson(s)],
    quality: DashboardQuality.fromJson(_m(j['quality'])),
  );

  final String currency;
  final DashboardKpis kpis;
  final List<DashboardBucketRow> buckets;
  final DashboardFunnel funnel;
  final List<DashboardMix> services, payments;
  final List<DashboardHeatCell> heat;
  final DashboardQuality quality;

  /// Drivers' cancellations of the requests they took.
  double? get driverCancelRate => kpis.accepted == 0 ? null : quality.driverCancels / kpis.accepted;

  /// Riders' cancellations of the requests they made.
  double? get riderCancelRate => kpis.requests == 0 ? null : quality.riderCancels / kpis.requests;
}

class DashboardArea {
  const DashboardArea({this.name, this.city, required this.trips, required this.bookings, required this.prevTrips});

  factory DashboardArea.fromJson(Map<String, dynamic> j) => DashboardArea(
    name: _s(j['name']),
    city: _s(j['city']),
    trips: _i(j['trips']),
    bookings: _d(j['bookings']),
    prevTrips: _i(j['prev_trips']),
  );

  /// The pickup's suburb, else city, else state; null when none was recorded.
  final String? name;
  final String? city;
  final int trips, prevTrips;
  final double bookings;

  double? get averageFare => trips == 0 ? null : bookings / trips;
}

class DashboardDriver {
  const DashboardDriver({
    required this.profileId,
    this.partnerId,
    this.displayId,
    required this.name,
    required this.trips,
    required this.earned,
    this.rating,
    this.onlineSeconds = 0,
  });

  factory DashboardDriver.fromJson(Map<String, dynamic> j) => DashboardDriver(
    profileId: '${j['profile_id'] ?? ''}',
    partnerId: _s(j['partner_id']),
    displayId: _s(j['display_id']),
    name: _s(j['name']) ?? 'Driver',
    trips: _i(j['trips']),
    earned: _d(j['earned']),
    rating: _dn(j['rating']),
    onlineSeconds: _i(j['online_seconds']),
  );

  final String profileId;
  final String? partnerId, displayId;
  final String name;
  final int trips, onlineSeconds;
  final double earned;
  final double? rating;
}

class DashboardAirport {
  const DashboardAirport({
    required this.id,
    required this.kind,
    required this.name,
    required this.waiting,
    required this.pickups,
    required this.prevPickups,
  });

  factory DashboardAirport.fromJson(Map<String, dynamic> j) => DashboardAirport(
    id: '${j['id'] ?? ''}',
    kind: _s(j['kind']) ?? 'airport',
    name: _s(j['name']) ?? 'Airport',
    waiting: _i(j['waiting']),
    pickups: _i(j['pickups']),
    prevPickups: _i(j['prev_pickups']),
  );

  final String id, kind, name;
  final int waiting, pickups, prevPickups;
}

class DashboardAttention {
  const DashboardAttention({
    this.partnersPending = 0,
    this.partnerDocsPending = 0,
    this.vehicleDocsPending = 0,
    this.vehiclesNoPermit = 0,
    this.permitsExpiring = 0,
    this.ticketsOpen = 0,
  });

  factory DashboardAttention.fromJson(Map<String, dynamic> j) => DashboardAttention(
    partnersPending: _i(j['partners_pending']),
    partnerDocsPending: _i(j['partner_docs_pending']),
    vehicleDocsPending: _i(j['vehicle_docs_pending']),
    vehiclesNoPermit: _i(j['vehicles_no_permit']),
    permitsExpiring: _i(j['permits_expiring']),
    ticketsOpen: _i(j['tickets_open']),
  );

  final int partnersPending, partnerDocsPending, vehicleDocsPending, vehiclesNoPermit, permitsExpiring, ticketsOpen;
}

class DashboardSummary {
  const DashboardSummary({
    this.current = const DashboardPeriodFigures(),
    this.previous = const DashboardPeriodFigures(),
    this.areas = const [],
    this.onlineRecorded = false,
    this.drivers = const [],
    this.airports = const [],
    this.attention = const DashboardAttention(),
  });

  factory DashboardSummary.fromJson(Map<String, dynamic> j) => DashboardSummary(
    current: DashboardPeriodFigures.fromJson(_m(j['current'])),
    previous: DashboardPeriodFigures.fromJson(_m(j['previous'])),
    areas: [for (final a in _l(j['areas'])) DashboardArea.fromJson(a)],
    onlineRecorded: j['online_recorded'] == true,
    drivers: [for (final d in _l(j['drivers'])) DashboardDriver.fromJson(d)],
    airports: [for (final a in _l(j['airports'])) DashboardAirport.fromJson(a)],
    attention: DashboardAttention.fromJson(_m(j['attention'])),
  );

  final DashboardPeriodFigures current, previous;
  final List<DashboardArea> areas;

  /// Whether any driver was online in the period (else no online column).
  final bool onlineRecorded;
  final List<DashboardDriver> drivers;
  final List<DashboardAirport> airports;
  final DashboardAttention attention;
}

class DashboardLive {
  const DashboardLive({
    this.driversOnline = 0,
    this.ridesInProgress = 0,
    this.openRequests = 0,
    this.firstOfferSeconds,
    this.firstOfferSamples = 0,
    this.queueWaiting = 0,
    this.queues = const [],
    this.sosOpen = 0,
  });

  factory DashboardLive.fromJson(Map<String, dynamic> j) => DashboardLive(
    driversOnline: _i(j['drivers_online']),
    ridesInProgress: _i(j['rides_in_progress']),
    openRequests: _i(j['open_requests']),
    firstOfferSeconds: j['first_offer_seconds'] == null ? null : _i(j['first_offer_seconds']),
    firstOfferSamples: _i(j['first_offer_samples']),
    queueWaiting: _i(j['queue_waiting']),
    queues: [
      for (final q in _l(j['queues'])) (name: _s(q['name']) ?? 'Airport', waiting: _i(q['waiting'])),
    ],
    sosOpen: _i(j['sos_open']),
  );

  final int driversOnline, ridesInProgress, openRequests, firstOfferSamples, queueWaiting, sosOpen;

  /// How long today's requests waited for a first offer, on average.
  final int? firstOfferSeconds;
  final List<({String name, int waiting})> queues;
}

// ---- Change against the previous period ----------------------------------------------------------------
/// Whether a change is good news, bad news or none.
enum DeltaTone { good, bad, flat }

/// How a change is told: relative (counts and money, "8.4%"), in
/// percentage points (rates, "1.8 pts"), or as the plain difference
/// (a rating, minutes, "+0.03").
enum DeltaKind { relative, points, absolute }

class DashboardDelta {
  const DashboardDelta(this.text, this.tone, {this.up});

  /// "▲ 8.4%", "▼ 1.8 pts", "+0.03", "new", "same".
  final String text;
  final DeltaTone tone;

  /// Whether the figure went up (null: unchanged).
  final bool? up;

  /// [current] against [previous]: null when either is unknown. A fall is
  /// good news where [lowerIsBetter] (cancellations, complaints, waits).
  static DashboardDelta? of(
    num? current,
    num? previous, {
    DeltaKind kind = DeltaKind.relative,
    bool lowerIsBetter = false,
    int decimals = 1,
  }) {
    if (current == null || previous == null) return null;
    DeltaTone tone(bool up) => up != lowerIsBetter ? DeltaTone.good : DeltaTone.bad;
    final diff = current - previous;
    switch (kind) {
      case DeltaKind.relative:
        if (previous == 0) {
          return current == 0 ? const DashboardDelta('same', DeltaTone.flat) : DashboardDelta('new', tone(true), up: true);
        }
        final pct = diff / previous.abs() * 100;
        if (pct.abs() < 0.05) return const DashboardDelta('0.0%', DeltaTone.flat);
        return DashboardDelta('${pct > 0 ? '▲' : '▼'} ${pct.abs().toStringAsFixed(1)}%', tone(pct > 0), up: pct > 0);
      case DeltaKind.points:
        final pts = diff * 100;
        if (pts.abs() < 0.05) return const DashboardDelta('0.0 pts', DeltaTone.flat);
        return DashboardDelta('${pts > 0 ? '▲' : '▼'} ${pts.abs().toStringAsFixed(1)} pts', tone(pts > 0), up: pts > 0);
      case DeltaKind.absolute:
        final unit = math.pow(10, -decimals) / 2;
        if (diff.abs() < unit) return DashboardDelta((0).toStringAsFixed(decimals), DeltaTone.flat);
        return DashboardDelta('${diff > 0 ? '+' : '−'}${diff.abs().toStringAsFixed(decimals)}', tone(diff > 0), up: diff > 0);
    }
  }
}

// ---- The KPI tiles -------------------------------------------------------------------------------------
enum DashboardKpi {
  trips('Completed trips', '/admin/rides?status=completed'),
  bookings('Gross bookings', '/admin/rides?status=completed'),
  commission('Platform commission', '/admin/commission'),
  averageFare('Average fare', '/admin/rides?status=completed'),
  acceptance('Acceptance rate', '/admin/rides'),
  cancellation('Cancellation rate', '/admin/rides?status=cancelled', lowerIsBetter: true),
  newRiders('New riders', '/admin/users'),
  newPartners('New partners', '/admin/partners?status=unapproved');

  const DashboardKpi(this.label, this.route, {this.lowerIsBetter = false});
  final String label;

  /// The admin list the tile opens, filtered where the list takes it.
  final String route;
  final bool lowerIsBetter;

  bool get isRate => this == acceptance || this == cancellation;
  bool get isMoney => this == bookings || this == commission || this == averageFare;

  /// The tile's figure for [k] (null: nothing to divide by).
  num? valueOf(DashboardKpis k) => switch (this) {
    trips => k.trips,
    bookings => k.bookings,
    commission => k.commission,
    averageFare => k.averageFare,
    acceptance => k.acceptanceRate,
    cancellation => k.cancellationRate,
    newRiders => k.newRiders,
    newPartners => k.newPartners,
  };

  /// The sparkline: the figure bucket by bucket (rates of empty buckets as 0).
  List<double> spark(List<DashboardBucketRow> buckets) => [
    for (final b in buckets)
      switch (this) {
        trips => b.trips.toDouble(),
        bookings => b.bookings,
        commission => b.commission,
        averageFare => b.trips == 0 ? 0 : b.bookings / b.trips,
        acceptance => b.requests == 0 ? 0 : b.accepted / b.requests,
        cancellation => b.requests == 0 ? 0 : b.cancelled / b.requests,
        newRiders => b.newRiders.toDouble(),
        newPartners => b.newPartners.toDouble(),
      },
  ];

  /// The tile's figure as shown.
  String format(num? v, String currency) {
    if (v == null) return '—';
    if (isRate) return formatDashboardPercent(v.toDouble());
    if (this == averageFare) return formatMoney(v, currency);
    if (isMoney) return formatMoney(v, currency, 0);
    return formatDashboardCount(v);
  }

  DashboardDelta? delta(DashboardKpis current, DashboardKpis previous) => DashboardDelta.of(
    valueOf(current),
    valueOf(previous),
    kind: isRate ? DeltaKind.points : DeltaKind.relative,
    lowerIsBetter: lowerIsBetter,
  );
}

// ---- Formatting ---------------------------------------------------------------------------------------
final _count = NumberFormat('#,##0');

/// 1,234.
String formatDashboardCount(num n) => _count.format(n);

/// 0.109 as "10.9%".
String formatDashboardPercent(double share, {int decimals = 1}) => '${(share * 100).toStringAsFixed(decimals)}%';

/// A share of a whole as a whole percent: "46%".
String formatDashboardShare(num part, num whole) => whole == 0 ? '0%' : '${(part / whole * 100).round()}%';

/// An axis value: 950, 1.2k, 3.4M.
String formatDashboardAxis(double v) {
  final a = v.abs();
  if (a >= 1e6) return '${(v / 1e6).toStringAsFixed(a >= 1e7 ? 0 : 1)}M';
  if (a >= 1e3) return '${(v / 1e3).toStringAsFixed(a >= 1e4 ? 0 : 1)}k';
  return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

/// A wait: "2:14" (minutes and seconds), "1:02:05" past an hour.
String formatDashboardWait(int seconds) {
  final s = math.max(0, seconds);
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(r)}' : '$m:${_two(r)}';
}

/// Online time: "9h 10m", "45m".
String formatDashboardOnline(int seconds) {
  final m = math.max(0, seconds) ~/ 60;
  return m >= 60 ? '${m ~/ 60}h ${_two(m % 60)}m' : '${m}m';
}

/// A round number at or above [v] for the chart's top: 1, 2, 2.5, 5 × 10ⁿ.
double dashboardNiceCeil(double v) {
  if (v <= 0) return 1;
  final p = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
  for (final m in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (m * p >= v) return m * p;
  }
  return 10 * p;
}
