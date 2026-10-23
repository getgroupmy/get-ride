// God View → Movement (migration 0278): where someone went, from
// god_view_trail's points. The hours to show, the line split where the
// phone went quiet, the distance and the stops. Pure.
import 'dart:math' as math;

/// One reported position.
class TrailPoint {
  const TrailPoint(this.lat, this.lng, this.at, {this.speed});
  final double lat;
  final double lng;
  final DateTime at;

  /// Metres a second, when the phone sent it.
  final double? speed;

  /// `[lat, lng, epoch seconds, speed]`, as god_view_trail sends.
  static TrailPoint? fromJson(Object? row) {
    if (row is! List || row.length < 3) return null;
    final lat = (row[0] as num?)?.toDouble();
    final lng = (row[1] as num?)?.toDouble();
    final s = (row[2] as num?)?.toInt();
    if (lat == null || lng == null || s == null) return null;
    return TrailPoint(lat, lng, DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true),
        speed: row.length > 3 ? (row[3] as num?)?.toDouble() : null);
  }
}

/// What god_view_trail sent back.
class GodViewTrail {
  const GodViewTrail({required this.from, required this.to, required this.points, this.total = 0, this.thinned = false});

  factory GodViewTrail.fromJson(Map<String, dynamic> j) => GodViewTrail(
        from: DateTime.tryParse('${j['from'] ?? ''}')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        to: DateTime.tryParse('${j['to'] ?? ''}')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        total: (j['total'] as num?)?.toInt() ?? 0,
        thinned: j['thinned'] == true,
        points: [
          for (final r in (j['points'] as List? ?? const [])) ?TrailPoint.fromJson(r),
        ],
      );

  final DateTime from;
  final DateTime to;
  final List<TrailPoint> points;

  /// Points on the server before thinning.
  final int total;
  final bool thinned;
}

/// The time window asked for: the last 24 hours, or one calendar day in
/// Malaysia (UTC+8, as the rest of admin).
({DateTime from, DateTime to}) trailWindow({DateTime? day, required DateTime now}) {
  if (day == null) return (from: now.toUtc().subtract(const Duration(hours: 24)), to: now.toUtc());
  final start = DateTime.utc(day.year, day.month, day.day).subtract(const Duration(hours: 8));
  return (from: start, to: start.add(const Duration(days: 1)));
}

/// The hour of [at] on the Malaysia clock, 0 to 23.
int trailHour(DateTime at) => at.toUtc().add(const Duration(hours: 8)).hour;

/// Only the points in [hours]; all of them when [hours] is empty.
List<TrailPoint> trailInHours(List<TrailPoint> points, Set<int> hours) =>
    hours.isEmpty ? points : [for (final p in points) if (hours.contains(trailHour(p.at))) p];

/// The hours that have at least one point.
Set<int> trailHoursWithData(List<TrailPoint> points) => {for (final p in points) trailHour(p.at)};

/// Metres between two points (haversine).
double trailMetres(TrailPoint a, TrailPoint b) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(b.lat - a.lat);
  final dLng = rad(b.lng - a.lng);
  final h = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(a.lat)) * math.cos(rad(b.lat)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.sqrt(h.toDouble()));
}

/// The phone sent nothing for this long: the line breaks into a dashed gap.
const trailGap = Duration(minutes: 20);

/// A run of points drawn as one line, and whether it is the quiet gap
/// before the next run.
typedef TrailSegment = ({List<TrailPoint> points, bool gap});

/// The line, split where the phone was quiet for [trailGap]: solid runs,
/// each followed by a two-point dashed gap to the next.
List<TrailSegment> trailSegments(List<TrailPoint> points) {
  final out = <TrailSegment>[];
  var run = <TrailPoint>[];
  for (final p in points) {
    if (run.isNotEmpty && p.at.difference(run.last.at) > trailGap) {
      out.add((points: run, gap: false));
      out.add((points: [run.last, p], gap: true));
      run = [];
    }
    run.add(p);
  }
  if (run.isNotEmpty) out.add((points: run, gap: false));
  return out;
}

/// Km moved, gaps left out (a straight line over a quiet hour is a guess).
double trailKm(List<TrailPoint> points) {
  var m = 0.0;
  for (var i = 1; i < points.length; i++) {
    if (points[i].at.difference(points[i - 1].at) > trailGap) continue;
    m += trailMetres(points[i - 1], points[i]);
  }
  return m / 1000;
}

/// A place they stayed: within [trailStopRadius] for [trailStopMin] or more.
typedef TrailStop = ({TrailPoint at, DateTime until});

const trailStopRadius = 120.0;
const trailStopMin = Duration(minutes: 5);

/// The stops, in order. A quiet gap where both ends are in the same place
/// counts as staying there.
List<TrailStop> trailStops(List<TrailPoint> points) {
  final out = <TrailStop>[];
  var i = 0;
  while (i < points.length) {
    var j = i;
    while (j + 1 < points.length && trailMetres(points[i], points[j + 1]) <= trailStopRadius) {
      j++;
    }
    if (points[j].at.difference(points[i].at) >= trailStopMin) {
      out.add((at: points[i], until: points[j].at));
      i = j + 1;
    } else {
      i++;
    }
  }
  return out;
}

/// "12 min", "1 h 5 min".
String trailDuration(Duration d) {
  final m = d.inMinutes;
  if (m < 60) return '$m min';
  return m % 60 == 0 ? '${m ~/ 60} h' : '${m ~/ 60} h ${m % 60} min';
}

/// "14:05" on the Malaysia clock.
String trailClock(DateTime at) {
  final l = at.toUtc().add(const Duration(hours: 8));
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}
