// Traffic signals, speed limits and road classes from OpenStreetMap.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/road_info.dart';
import 'package:get_ride/src/data/road_info_service.dart';
import 'package:get_ride/src/widgets/road_info_layers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

const _car = LatLng(3.1500, 101.7000);

Map<String, dynamic> _way(String highway, List<LatLng> line, {String? maxspeed, String? name}) => {
  'type': 'way',
  'tags': {'highway': highway, 'maxspeed': ?maxspeed, 'name': ?name},
  'geometry': [
    for (final p in line) {'lat': p.latitude, 'lon': p.longitude},
  ],
};

void main() {
  group('rules', () {
    test('maxspeed reads km/h, mph and the lower of two; zone codes are not a limit', () {
      expect(parseMaxspeed('50'), 50);
      expect(parseMaxspeed('60 km/h'), 60);
      expect(parseMaxspeed('30 mph'), 48);
      expect(parseMaxspeed('60;40'), 40);
      expect(parseMaxspeed('MY:urban'), isNull);
      expect(parseMaxspeed('none'), isNull);
      expect(parseMaxspeed(null), isNull);
    });

    test('road classes from the highway tag, links included; paths are not roads', () {
      expect(RoadClass.parse('residential'), RoadClass.residential);
      expect(RoadClass.parse('trunk_link'), RoadClass.trunk);
      expect(RoadClass.parse('motorway'), RoadClass.motorway);
      expect(RoadClass.parse('footway'), isNull);
      expect(RoadClass.parse(null), isNull);
    });

    test('the road under the car is the nearest car road, with its limit or its class as an estimate', () {
      final json = {
        'elements': [
          _way('footway', [const LatLng(3.15, 101.6999), const LatLng(3.151, 101.6999)]),
          _way('trunk', [const LatLng(3.1495, 101.7003), const LatLng(3.1505, 101.7003)], maxspeed: '90'),
          _way('residential', [const LatLng(3.1495, 101.70005), const LatLng(3.1505, 101.70005)], name: 'Jalan 1'),
        ],
      };
      final road = parseRoadAt(json, _car)!;
      expect(road.roadClass, RoadClass.residential, reason: 'about 5 m away, the trunk about 33 m');
      expect(road.name, 'Jalan 1');
      expect(road.estimated, isTrue);
      expect(road.speedKmh, RoadClass.residential.baselineKmh);

      final tagged = parseRoadAt({
        'elements': [
          _way('trunk', [const LatLng(3.1495, 101.7001), const LatLng(3.1505, 101.7001)], maxspeed: '90'),
        ],
      }, _car)!;
      expect((tagged.speedKmh, tagged.estimated), (90, false));
      expect(parseRoadAt({'elements': []}, _car), isNull);
    });

    test('traffic signals are the nodes of the answer; the grid covers the view', () {
      expect(
        parseTrafficSignals({
          'elements': [
            {'type': 'node', 'lat': 3.1, 'lon': 101.7},
            {'type': 'way'},
          ],
        }),
        [const LatLng(3.1, 101.7)],
      );
      expect(tilesFor(south: 3.141, west: 101.701, north: 3.149, east: 101.709), hasLength(1));
      expect(tilesFor(south: 3.145, west: 101.705, north: 3.155, east: 101.715), hasLength(4));
      expect(
        trafficSignalsQuery((south: 3.14, west: 101.7, north: 3.15, east: 101.71)),
        contains('"highway"="traffic_signals"'),
      );
    });
  });

  group('service', () {
    test('asks Overpass once per grid square, and an error is just nothing', () async {
      var asked = 0;
      final svc = RoadInfoService(
        endpoint: 'https://overpass.test/api',
        client: MockClient((req) async {
          asked++;
          expect(req.url.queryParameters['data'], contains('traffic_signals'));
          return http.Response(
            jsonEncode({
              'elements': [
                {'type': 'node', 'lat': 3.1405, 'lon': 101.7005},
              ],
            }),
            200,
          );
        }),
      );
      final a = await svc.trafficSignals(south: 3.141, west: 101.701, north: 3.149, east: 101.709);
      final b = await svc.trafficSignals(south: 3.142, west: 101.702, north: 3.148, east: 101.708);
      expect(a, [const LatLng(3.1405, 101.7005)]);
      expect(b, a);
      expect(asked, 1);

      final down = RoadInfoService(client: MockClient((_) async => http.Response('busy', 429)));
      expect(await down.trafficSignals(south: 3.141, west: 101.701, north: 3.149, east: 101.709), isEmpty);
      expect(await down.roadAt(_car), isNull);
    });
  });

  group('on the map', () {
    RoadInfoService service(Map<String, dynamic> Function(String query) answer) => RoadInfoService(
      client: MockClient((req) async => http.Response(jsonEncode(answer(req.url.queryParameters['data']!)), 200)),
    );

    testWidgets('traffic lights show once zoomed in', (tester) async {
      final svc = service(
        (_) => {
          'elements': [
            {'type': 'node', 'lat': _car.latitude, 'lon': _car.longitude},
          ],
        },
      );
      Future<void> at(double zoom) async {
        await tester.pumpWidget(
          MaterialApp(
            home: FlutterMap(
              key: ValueKey(zoom),
              options: MapOptions(initialCenter: _car, initialZoom: zoom),
              children: [TrafficSignalsLayer(service: svc)],
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
      }

      await at(13);
      expect(find.byKey(const ValueKey('traffic-signal')), findsNothing);
      await at(16);
      expect(find.byKey(const ValueKey('traffic-signal')), findsOneWidget);
    });

    testWidgets('the speed limit sign: tagged in a red ring, else the road class as an estimate', (tester) async {
      var maxspeed = '60';
      final svc = service(
        (_) => {
          'elements': [
            _way('primary', [const LatLng(3.1495, 101.7), const LatLng(3.1505, 101.7)], maxspeed: maxspeed),
          ],
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SpeedLimitBadge(at: _car, service: svc),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('60'), findsOneWidget);
      expect(find.text('Primary road'), findsOneWidget);

      // Untagged, a fresh service and a new spot: the class stands in.
      maxspeed = '';
      final svc2 = service(
        (_) => {
          'elements': [
            _way('residential', [const LatLng(3.1595, 101.7), const LatLng(3.1605, 101.7)]),
          ],
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SpeedLimitBadge(key: const ValueKey('b2'), at: const LatLng(3.16, 101.7), service: svc2),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('${RoadClass.residential.baselineKmh}'), findsOneWidget);
      expect(find.text('Residential road · est.'), findsOneWidget);
    });

    testWidgets('no sign without a position', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SpeedLimitBadge(at: null))));
      expect(find.byKey(const ValueKey('speed-limit')), findsNothing);
    });
  });
}
