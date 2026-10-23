import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:get_ride/src/admin/screens/god_view_movement.dart';
import 'package:get_ride/src/core/god_view_trail.dart';
import 'package:get_ride/src/core/page_styles.dart';
import 'package:latlong2/latlong.dart';

final _t0 = DateTime.utc(2026, 10, 23, 1); // 09:00 in Malaysia

TrailPoint _p(double lat, double lng, int min) => TrailPoint(lat, lng, _t0.add(Duration(minutes: min)));

void main() {
  test('reads the server\'s points and skips bad rows', () {
    final t = GodViewTrail.fromJson({
      'from': '2026-10-22T01:00:00Z',
      'to': '2026-10-23T01:00:00Z',
      'total': 9000,
      'thinned': true,
      'points': [
        [3.1, 101.6, 1792800000, 4.5],
        [3.2, 101.7, 1792800060],
        ['x'],
        null,
      ],
    });
    expect(t.points.length, 2);
    expect(t.points.first.speed, 4.5);
    expect(t.points.last.speed, isNull);
    expect(t.thinned, isTrue);
    expect(t.total, 9000);
  });

  test('a day is the Malaysia calendar day; the default is the last 24 hours', () {
    final now = DateTime.utc(2026, 10, 23, 15);
    final w = trailWindow(day: DateTime(2026, 10, 22), now: now);
    expect(w.from, DateTime.utc(2026, 10, 21, 16));
    expect(w.to, DateTime.utc(2026, 10, 22, 16));
    final d = trailWindow(now: now);
    expect(d.to.difference(d.from), const Duration(hours: 24));
  });

  test('hours, gaps, distance and stops', () {
    final pts = [
      _p(3.0, 101.0, 0),
      _p(3.0, 101.0, 8), // still there: a stop of 8 min
      _p(3.009, 101.0, 12), // ~1 km on
      _p(3.009, 101.0, 70), // quiet for 58 min in the same place
      _p(3.05, 101.0, 75),
    ];
    expect(trailHour(pts.first.at), 9);
    expect(trailHoursWithData(pts), {9, 10});
    expect(trailInHours(pts, {10}).length, 2);
    expect(trailInHours(pts, const {}).length, 5);

    final segs = trailSegments(pts);
    expect(segs.where((s) => s.gap).length, 1, reason: 'one quiet stretch');
    expect(segs.first.points.length, 3);

    expect(trailKm(pts), closeTo(1.0 + 4.56, 0.1), reason: 'the quiet stretch is not counted');

    final stops = trailStops(pts);
    expect(stops.length, 2);
    expect(stops.first.until.difference(stops.first.at.at), const Duration(minutes: 8));
    expect(trailDuration(const Duration(minutes: 65)), '1 h 5 min');
    expect(trailClock(pts.first.at), '09:00');
  });

  test('Follow roads: runs thinned, routed in chunks, gaps left straight, calls capped', () async {
    // A run of 60 points 200 m apart, a quiet hour, then a run of 3.
    final pts = [
      for (var i = 0; i < 60; i++) _p(3.0 + i * 0.0018, 101.0, i),
      for (var i = 0; i < 3; i++) _p(3.5 + i * 0.0018, 101.0, 130 + i),
    ];
    final asked = <int>[];
    final roads = await trailRoads(pts, (p) async {
      asked.add(p.length);
      return [...p, p.last];
    });
    expect(roads.length, 2, reason: 'one road per solid run, none for the gap');
    expect(asked.first, trailRoadChunk);
    expect(asked.every((n) => n <= trailRoadChunk), isTrue);
    expect(roads.every((r) => r != null), isTrue);

    final failed = await trailRoads(pts, (p) async => null);
    expect(failed, [null, null], reason: 'a failed route is drawn straight');

    var calls = 0;
    final long = [for (var i = 0; i < 600; i++) _p(3.0 + i * 0.0018, 101.0, i)];
    final capped = await trailRoads(long, (p) async {
      calls++;
      return p;
    });
    expect(calls, 0, reason: 'more calls than allowed: straight, nothing asked');
    expect(capped, [null]);
  });

  test('the trail look reads the line style and the colours', () {
    final d = TrailLook.defaults(Brightness.light);
    expect(d.pattern, const StrokePattern.solid());
    final dashed = TrailLook(early: d.early, late: d.late, stop: d.stop, style: 1);
    expect(dashed.pattern, isNot(const StrokePattern.solid()));
    expect(trailLineStyles, ['Solid', 'Dashed', 'Dotted']);
    expect(trailPaths, ['Straight lines', 'Follow roads']);
    final layers = godViewTrailLayers([_p(3, 101, 0), _p(3.01, 101, 5)], d, Colors.white,
        roads: [[const LatLng(3, 101), const LatLng(3.005, 101.002), const LatLng(3.01, 101)]]);
    final line = (layers.first as PolylineLayer).polylines.single;
    expect(line.points.length, 3, reason: 'the road, not the straight line');
  });
}
