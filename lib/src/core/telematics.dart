// Telematics (migration 0255): kilometres and trips per driver, per vehicle
// and per driver in a vehicle, by Today / This week / This month / a custom
// range. The server adds the numbers up (telematics_summary,
// telematics_list); this file holds the periods and their buckets, the
// answers' models, the trip types' names, the CSV, and the filter the
// driver app adds its own GPS distance up with. Pure.
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'driver_earnings.dart' show csvField;
import 'partner_statement.dart' show malaysiaDate, malaysiaMidnight, statementWeekStart;

// ---- Periods ---------------------------------------------------------------------------------------
enum TelematicsPeriod {
  today('Today', 'Today'),
  week('This week', 'Week'),
  month('This month', 'Month'),
  custom('Custom', 'Custom');

  const TelematicsPeriod(this.label, this.shortLabel);
  final String label;

  /// For a picker too narrow for [label].
  final String shortLabel;
}

/// How a period is cut up for the chart.
enum TelematicsBucket {
  hour,
  day,
  week,
  month;

  /// As `telematics_summary` takes it.
  String get db => name;

  /// "per hour", "per day", … for the chart's description.
  String get per => 'per $name';
}

/// The longest custom range, in days (the server takes a year).
const telematicsMaxDays = 366;

/// A period as instants (Malaysia's days) and how to bucket it.
class TelematicsRange {
  const TelematicsRange({required this.from, required this.to, required this.bucket, required this.first, required this.last});

  /// The first instant, and the instant after the last day.
  final DateTime from, to;
  final TelematicsBucket bucket;

  /// The first and last day (UTC dates holding Malaysia's calendar day).
  final DateTime first, last;

  int get days => last.difference(first).inDays + 1;

  @override
  bool operator ==(Object other) =>
      other is TelematicsRange && other.from == from && other.to == to && other.bucket == bucket;

  @override
  int get hashCode => Object.hash(from, to, bucket);
}

/// The bucket for a span of [days]: hours for one day, days up to two
/// months, weeks up to half a year, months beyond.
TelematicsBucket telematicsBucketFor(int days) => days <= 1
    ? TelematicsBucket.hour
    : days <= 62
    ? TelematicsBucket.day
    : days <= 190
    ? TelematicsBucket.week
    : TelematicsBucket.month;

/// [period] at [now] in Malaysia's days: today, this week (from Monday),
/// this month, or [first]..[last] (calendar days, in either order, at most
/// [telematicsMaxDays] ending on the later one). Each runs to the end of its
/// last day.
TelematicsRange telematicsRange(TelematicsPeriod period, DateTime now, {DateTime? first, DateTime? last}) {
  final today = malaysiaDate(now);
  DateTime day(DateTime d) => DateTime.utc(d.year, d.month, d.day);
  var a = switch (period) {
    TelematicsPeriod.today => today,
    TelematicsPeriod.week => statementWeekStart(today),
    TelematicsPeriod.month => DateTime.utc(today.year, today.month),
    TelematicsPeriod.custom => day(first ?? today),
  };
  var b = period == TelematicsPeriod.custom ? day(last ?? first ?? today) : today;
  if (b.isBefore(a)) (a, b) = (b, a);
  if (b.difference(a).inDays + 1 > telematicsMaxDays) a = b.subtract(const Duration(days: telematicsMaxDays - 1));
  final days = b.difference(a).inDays + 1;
  return TelematicsRange(
    from: malaysiaMidnight(a),
    to: malaysiaMidnight(b.add(const Duration(days: 1))),
    bucket: period == TelematicsPeriod.today ? TelematicsBucket.hour : telematicsBucketFor(days),
    first: a,
    last: b,
  );
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _two(int n) => n.toString().padLeft(2, '0');

/// The short label under a bar: "14" (hour), "Mon" (a day of a week or
/// less), "20" (a day of a longer span), "20 Oct" (week), "Oct" (month).
/// [start] holds Malaysia's wall clock in UTC fields.
String telematicsBucketLabel(DateTime start, TelematicsBucket bucket, {required int days}) => switch (bucket) {
  TelematicsBucket.hour => _two(start.hour),
  TelematicsBucket.day => days <= 7 ? _weekdays[start.weekday - 1] : '${start.day}',
  TelematicsBucket.week => '${start.day} ${_months[start.month - 1]}',
  TelematicsBucket.month => _months[start.month - 1],
};

/// The bucket in full, for the tooltip: "14:00", "Mon 20 Oct", "Week of
/// 20 Oct", "Oct 2026".
String telematicsBucketTitle(DateTime start, TelematicsBucket bucket) => switch (bucket) {
  TelematicsBucket.hour => '${_two(start.hour)}:00',
  TelematicsBucket.day => '${_weekdays[start.weekday - 1]} ${start.day} ${_months[start.month - 1]}',
  TelematicsBucket.week => 'Week of ${start.day} ${_months[start.month - 1]}',
  TelematicsBucket.month => '${_months[start.month - 1]} ${start.year}',
};

/// Which of [count] bars get a label so that at most [fit] do: every one,
/// else every 2nd, 3rd, … counted from the first.
List<int> telematicsLabelledBars(int count, int fit) {
  if (count <= 0) return const [];
  final step = fit <= 0 ? count : math.max(1, (count / fit).ceil());
  return [for (var i = 0; i < count; i += step) i];
}

// ---- Trip types ------------------------------------------------------------------------------------
/// A trip type as `telematics_trip_kind` names it, in words: the service
/// booked ('service:Comfort' is "Comfort"), or how the trip came.
String tripKindLabel(String kind) {
  if (kind.startsWith('service:')) {
    final s = kind.substring(8).trim();
    return s.isEmpty ? 'Ride' : s;
  }
  return switch (kind) {
    'meter' => 'Taxi (meter)',
    'stand' => 'Stand order',
    'airport' => 'Airport queue',
    'scheduled' => 'Scheduled',
    'call_centre' => 'Call centre',
    'my_ride' => 'My Ride / GET.now',
    _ => kind,
  };
}

// ---- Numbers ---------------------------------------------------------------------------------------
/// How far the actual is off the estimate, in percent; null without both
/// (or with no estimate to compare to).
double? kmDiffPercent(double? estimated, double? actual) {
  if (estimated == null || actual == null || estimated <= 0) return null;
  return (actual - estimated) / estimated * 100;
}

/// "1,234.5"; "—" for nothing recorded.
String formatTelematicsKm(double? km) {
  if (km == null) return '—';
  final fixed = km.abs().toStringAsFixed(1);
  final dot = fixed.indexOf('.');
  final whole = fixed.substring(0, dot);
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) grouped.write(',');
    grouped.write(whole[i]);
  }
  return '${km < 0 ? '-' : ''}$grouped${fixed.substring(dot)}';
}

/// "+3.2%", "-1.0%"; "—" when there is nothing to compare.
String formatKmDiff(double? percent) {
  if (percent == null) return '—';
  final r = (percent * 10).round() / 10;
  return '${r > 0 ? '+' : ''}${r.toStringAsFixed(1)}%';
}

double? _d(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
int _i(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);
String? _s(Object? v) {
  final s = v?.toString().trim();
  return s == null || s.isEmpty ? null : s;
}

// ---- The summary -----------------------------------------------------------------------------------
class TelematicsBucketRow {
  const TelematicsBucketRow({
    required this.start,
    this.trips = 0,
    this.pickupKm = 0,
    this.tripKm = 0,
    this.otherKm = 0,
    this.onlineKm = 0,
  });

  /// "2026-10-20T14:00" as Malaysia's wall clock (UTC fields).
  factory TelematicsBucketRow.fromJson(Map<String, dynamic> j) => TelematicsBucketRow(
    start: DateTime.tryParse('${j['start']}Z') ?? DateTime.utc(1970),
    trips: _i(j['trips']),
    pickupKm: _d(j['pickup_km']) ?? 0,
    tripKm: _d(j['trip_km']) ?? 0,
    otherKm: _d(j['other_km']) ?? 0,
    onlineKm: _d(j['online_km']) ?? 0,
  );

  final DateTime start;
  final int trips;

  /// To pickup and with the passenger: the actual km where recorded, else
  /// the estimate. Other: online km left over.
  final double pickupKm, tripKm, otherKm, onlineKm;

  double get total => pickupKm + tripKm + otherKm;
}

/// Completed trips' kilometres, estimated and actual. The differences
/// compare only the trips that have both.
class TelematicsKm {
  const TelematicsKm({
    this.estPickup,
    this.estTrip,
    this.actPickup,
    this.actTrip,
    this.pickupPairs = 0,
    this.tripPairs = 0,
    this.estPickupPaired,
    this.actPickupPaired,
    this.estTripPaired,
    this.actTripPaired,
    this.withActual = 0,
    this.obd = 0,
  });

  factory TelematicsKm.fromJson(Map<String, dynamic>? j) => j == null
      ? const TelematicsKm()
      : TelematicsKm(
          estPickup: _d(j['est_pickup']),
          estTrip: _d(j['est_trip']),
          actPickup: _d(j['act_pickup']),
          actTrip: _d(j['act_trip']),
          pickupPairs: _i(j['pickup_pairs']),
          tripPairs: _i(j['trip_pairs']),
          estPickupPaired: _d(j['est_pickup_paired']),
          actPickupPaired: _d(j['act_pickup_paired']),
          estTripPaired: _d(j['est_trip_paired']),
          actTripPaired: _d(j['act_trip_paired']),
          withActual: _i(j['with_actual']),
          obd: _i(j['obd']),
        );

  final double? estPickup, estTrip, actPickup, actTrip;
  final int pickupPairs, tripPairs;
  final double? estPickupPaired, actPickupPaired, estTripPaired, actTripPaired;

  /// Trips with any actual km; of them read off a car reader.
  final int withActual, obd;

  static double? _sum(double? a, double? b) => a == null && b == null ? null : (a ?? 0) + (b ?? 0);

  double? get estTotal => _sum(estPickup, estTrip);
  double? get actTotal => _sum(actPickup, actTrip);

  double? get pickupDiff => kmDiffPercent(estPickupPaired, actPickupPaired);
  double? get tripDiff => kmDiffPercent(estTripPaired, actTripPaired);
  double? get totalDiff =>
      kmDiffPercent(_sum(estPickupPaired, estTripPaired), _sum(actPickupPaired, actTripPaired));
}

class TripTypeCount {
  const TripTypeCount(this.kind, this.trips);
  final String kind;
  final int trips;
  String get label => tripKindLabel(kind);
}

class TelematicsSummary {
  const TelematicsSummary({
    this.mode = 'self',
    this.onlineRecorded = false,
    this.onlineKm = 0,
    this.onlineObdKm = 0,
    this.trips = 0,
    this.km = const TelematicsKm(),
    this.buckets = const [],
    this.types = const [],
  });

  factory TelematicsSummary.fromJson(Map<String, dynamic> j) => TelematicsSummary(
    mode: _s(j['mode']) ?? 'self',
    onlineRecorded: j['online_recorded'] == true,
    onlineKm: _d(j['online_km']) ?? 0,
    onlineObdKm: _d(j['online_obd_km']) ?? 0,
    trips: _i(j['trips']),
    km: TelematicsKm.fromJson(j['km'] is Map ? Map<String, dynamic>.from(j['km'] as Map) : null),
    buckets: [
      if (j['buckets'] is List)
        for (final b in j['buckets'] as List)
          if (b is Map) TelematicsBucketRow.fromJson(Map<String, dynamic>.from(b)),
    ],
    types: [
      if (j['types'] is List)
        for (final t in j['types'] as List)
          if (t is Map && t['kind'] != null) TripTypeCount('${t['kind']}', _i(t['trips'])),
    ],
  );

  /// 'self', 'admin', 'fleet' or 'stand': how the caller looks.
  final String mode;

  /// Any online km in the period (none before telematics, none for a stand).
  final bool onlineRecorded;
  final double onlineKm, onlineObdKm;
  final int trips;
  final TelematicsKm km;
  final List<TelematicsBucketRow> buckets;
  final List<TripTypeCount> types;

  /// Km on completed trips: to pickup and with the passenger, actual where
  /// recorded, else estimated.
  double get tripKm => buckets.fold(0.0, (s, b) => s + b.pickupKm + b.tripKm);

  /// The share of the online km spent on trips; null without online km.
  double? get tripShare => !onlineRecorded || onlineKm <= 0 ? null : math.min(1.0, tripKm / onlineKm);
}

// ---- The period list ---------------------------------------------------------------------------------
/// What the period list is of.
enum TelematicsGroup {
  driver('Driver', 'drivers'),
  vehicle('Vehicle', 'vehicles'),
  pair('Driver + vehicle', 'driver + vehicle pairs');

  const TelematicsGroup(this.label, this.plural);
  final String label;
  final String plural;

  /// As `telematics_list` takes it.
  String get db => name;
}

class TelematicsListRow {
  const TelematicsListRow({
    this.driverId,
    this.driverName,
    this.driverCode,
    this.vehicleId,
    this.plate,
    this.vehicle,
    this.onlineKm = 0,
    this.trips = 0,
    this.estPickupKm,
    this.estTripKm,
    this.actPickupKm,
    this.actTripKm,
  });

  factory TelematicsListRow.fromJson(Map<String, dynamic> j) => TelematicsListRow(
    driverId: _s(j['driver_id']),
    driverName: _s(j['driver_name']),
    driverCode: _s(j['driver_code']),
    vehicleId: _s(j['vehicle_id']),
    plate: _s(j['plate']),
    vehicle: _s(j['vehicle']),
    onlineKm: _d(j['online_km']) ?? 0,
    trips: _i(j['trips']),
    estPickupKm: _d(j['est_pickup_km']),
    estTripKm: _d(j['est_trip_km']),
    actPickupKm: _d(j['act_pickup_km']),
    actTripKm: _d(j['act_trip_km']),
  );

  final String? driverId, driverName, driverCode, vehicleId, plate, vehicle;
  final double onlineKm;
  final int trips;
  final double? estPickupKm, estTripKm, actPickupKm, actTripKm;

  double? get estKm => TelematicsKm._sum(estPickupKm, estTripKm);
  double? get actKm => TelematicsKm._sum(actPickupKm, actTripKm);

  /// "Ahmad (D-1042)"; "Driver not recorded" without one.
  String get driverLabel {
    final name = driverName ?? 'Driver';
    if (driverId == null) return 'Driver not recorded';
    return driverCode == null ? name : '$name ($driverCode)';
  }

  /// "WXY 1234 · Perodua Bezza"; "Vehicle not recorded" without one.
  String get vehicleLabel {
    if (vehicleId == null) return 'Vehicle not recorded';
    return [plate ?? 'No plate', ?vehicle].join(' · ');
  }

  /// This row's key for a picker: the driver, the vehicle or both.
  String key(TelematicsGroup g) => switch (g) {
    TelematicsGroup.driver => driverId ?? '',
    TelematicsGroup.vehicle => vehicleId ?? '',
    TelematicsGroup.pair => '${driverId ?? ''}|${vehicleId ?? ''}',
  };
}

/// The period list as CSV, as on screen plus the km split. Pure.
String telematicsListCsv(List<TelematicsListRow> rows, TelematicsGroup group) {
  String km(double? v) => v == null ? '' : v.toStringAsFixed(2);
  final out = StringBuffer(
    [
      if (group != TelematicsGroup.vehicle) ...['Driver', 'Driver ID'],
      if (group != TelematicsGroup.driver) ...['Plate', 'Vehicle'],
      'km driven online',
      'Trips',
      'To pickup est. km',
      'To pickup actual km',
      'Pickup to drop est. km',
      'Pickup to drop actual km',
    ].join(','),
  )..write('\r\n');
  for (final r in rows) {
    out
      ..write(
        [
          if (group != TelematicsGroup.vehicle) ...[r.driverName ?? '', r.driverCode ?? ''],
          if (group != TelematicsGroup.driver) ...[r.plate ?? '', r.vehicle ?? ''],
          km(r.onlineKm),
          '${r.trips}',
          km(r.estPickupKm),
          km(r.actPickupKm),
          km(r.estTripKm),
          km(r.actTripKm),
        ].map(csvField).join(','),
      )
      ..write('\r\n');
  }
  return out.toString();
}

/// The export's name: `telematics-drivers-2026-10-01-2026-10-20.csv`.
String telematicsCsvFileName(TelematicsGroup group, TelematicsRange range) {
  String d(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';
  final what = switch (group) {
    TelematicsGroup.driver => 'drivers',
    TelematicsGroup.vehicle => 'vehicles',
    TelematicsGroup.pair => 'drivers-vehicles',
  };
  return 'telematics-$what-${d(range.first)}-${d(range.last)}.csv';
}

// ---- Adding up the driver's own GPS distance -------------------------------------------------------
/// One fix from the phone.
typedef TelematicsFix = ({double lat, double lng, double? accuracy, DateTime at});

/// Adds up the distance driven from a stream of fixes, leaving out what is
/// not driving: a fix looser than [maxAccuracy] metres is ignored; a leg
/// faster than [maxSpeed] m/s is a jump (after [jumpsToReset] in a row the
/// phone really is elsewhere: counting starts again from there, adding
/// nothing); and a step shorter than the fix's own error (at least
/// [minStep], at most [maxStep] metres) waits for the car to really move,
/// so a parked phone's wandering fixes add nothing, while slow driving
/// still adds up once it has gone that far.
class DistanceAccumulator {
  DistanceAccumulator({
    this.maxAccuracy = 50,
    this.maxSpeed = 70,
    this.minStep = 10,
    this.maxStep = 25,
    this.jumpsToReset = 3,
  });

  final double maxAccuracy, maxSpeed, minStep, maxStep;
  final int jumpsToReset;

  static const _distance = Distance();

  TelematicsFix? _anchor;
  int _jumps = 0;

  /// Metres counted since the last [take] (or reset).
  double metres = 0;

  /// Adds [fix]; answers the metres it added.
  double add(TelematicsFix fix) {
    final acc = fix.accuracy;
    if (acc != null && (!acc.isFinite || acc > maxAccuracy)) return 0;
    if (!fix.lat.isFinite || !fix.lng.isFinite || fix.lat.abs() > 90 || fix.lng.abs() > 180) return 0;
    final from = _anchor;
    if (from == null) {
      _anchor = fix;
      return 0;
    }
    final secs = fix.at.difference(from.at).inMilliseconds / 1000;
    if (secs <= 0) return 0;
    final m = _distance(LatLng(from.lat, from.lng), LatLng(fix.lat, fix.lng));
    if (m / secs > maxSpeed) {
      if (++_jumps >= jumpsToReset) {
        _anchor = fix;
        _jumps = 0;
      }
      return 0;
    }
    _jumps = 0;
    final step = (acc ?? minStep).clamp(minStep, maxStep);
    if (m < step) return 0;
    _anchor = fix;
    metres += m;
    return m;
  }

  /// The metres counted so far, starting the count again (the anchor stays).
  double take() {
    final m = metres;
    metres = 0;
    return m;
  }

  /// Forgets everything: the next fix starts afresh.
  void reset() {
    _anchor = null;
    _jumps = 0;
    metres = 0;
  }
}
