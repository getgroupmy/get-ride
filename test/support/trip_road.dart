// A road, a car on it and a ride for it: what the trip maps are driven down in
// tests (trip_map_follow_test.dart, trip_map_live_test.dart).
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/car_playback.dart';
import 'package:get_ride/src/core/follow_motion.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:latlong2/latlong.dart';

const origin = LatLng(3.1500, 101.7000);
final t0 = DateTime.utc(2026, 11, 22, 4);
const frame = Duration(microseconds: 16667);
const frameSeconds = 1 / 60;

/// A road: north from [origin], round a bend to the right, and on east.
class Road {
  Road({double north = 400, double east = 500, double radius = 40}) {
    final points = <LatLng>[origin];
    // Up to where the bend begins, round it two degrees at a time, and on.
    final centre = movedAlong(movedAlong(origin, north, 0), radius, 90);
    for (var turned = 0; turned <= 90; turned += 2) {
      points.add(movedAlong(centre, radius, 270.0 + turned));
    }
    points.add(movedAlong(points.last, east, 90));
    this.points = points;
  }

  late final List<LatLng> points;

  double get length => lineMetres(points);

  /// Where a car [metres] down the road is, and the way the road runs there.
  ({LatLng at, double bearing}) spot(double metres) {
    var left = metres.clamp(0.0, length).toDouble();
    for (var i = 0; i < points.length - 1; i++) {
      final l = metresApart(points[i], points[i + 1]);
      if (left <= l || i == points.length - 2) {
        return (
          at: pointBetween(points[i], points[i + 1], l == 0 ? 0 : (left / l).clamp(0.0, 1.0)),
          bearing: bearingBetween(points[i], points[i + 1]),
        );
      }
      left -= l;
    }
    throw StateError('unreachable');
  }

  LatLng at(double metres) => spot(metres).at;
  double offBy(LatLng p) => nearestOnRoad(points, p)!.offBy;
  double along(LatLng p) => nearestOnRoad(points, p)!.along;
}

/// A router that sends the car down [road] from wherever it is.
class RoadGeo extends GeoService {
  RoadGeo(this.road);
  final Road road;
  int asked = 0;

  @override
  Future<RouteInfo> route(LatLng from, LatLng to, {List<LatLng> via = const []}) async {
    asked++;
    final points = [from, ...road.points.sublist(nearestOnRoad(road.points, from)!.index + 1)];
    return RouteInfo(distanceKm: lineMetres(points) / 1000, durationMin: lineMetres(points) / 600, points: points);
  }
}

RideRequest ride(Road road, {LatLng? car, DateTime? sent, double? heading, String status = 'accepted'}) => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'partner_id': 'me',
  'status': status,
  'fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'pickup_lat': road.points.last.latitude,
  'pickup_lng': road.points.last.longitude,
  'drop_lat': road.points.last.latitude,
  'drop_lng': road.points.last.longitude,
  'partner_live_lat': car?.latitude,
  'partner_live_lng': car?.longitude,
  'partner_live_heading': heading,
  'partner_live_at': sent?.toIso8601String(),
});

/// What a frame of a run showed: the car as drawn, the camera, where the road
/// line starts and where the real car was.
typedef Seen = ({double t, CarOnMap car, MapCamera camera, LatLng? lineStart, double real});

RideMap rideMap(WidgetTester tester) => tester.widget<RideMap>(find.byType(RideMap));
MapCamera cameraOf(WidgetTester tester) => tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!.camera;
