import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/data/geo_memo.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('address lookups are remembered per ~11 m cell', () {
    late DateTime clock;
    late GeoMemo memo;
    late int calls;
    Future<String?> ask() async {
      calls++;
      return 'answer $calls';
    }

    setUp(() {
      clock = DateTime(2026, 10, 18, 9);
      memo = GeoMemo(now: () => clock);
      calls = 0;
    });

    test('the same cell asks once', () async {
      const p = LatLng(3.15123, 101.71234);
      expect(await memo.get('place', p, 'en', ask), 'answer 1');
      expect(await memo.get('place', p, 'en', ask), 'answer 1');
      expect(calls, 1);
    });

    test('a nearby fix in the cell is a hit, the next cell a miss', () async {
      expect(await memo.get('place', const LatLng(3.15121, 101.71234), 'en', ask), 'answer 1');
      expect(await memo.get('place', const LatLng(3.15124, 101.71231), 'en', ask), 'answer 1');
      expect(calls, 1);
      expect(await memo.get('place', const LatLng(3.15131, 101.71234), 'en', ask), 'answer 2');
      expect(await memo.get('place', const LatLng(3.15121, 101.71264), 'en', ask), 'answer 3');
      expect(calls, 3);
    });

    test('language and kind of lookup are kept apart', () async {
      const p = LatLng(3.15, 101.71);
      await memo.get('place', p, 'en', ask);
      await memo.get('place', p, 'ms', ask);
      await memo.get('area', p, 'en', ask);
      expect(calls, 3);
    });

    test('calls for a cell being looked up share the one lookup', () async {
      final answer = Completer<String?>();
      var asked = 0;
      Future<String?> slow() {
        asked++;
        return answer.future;
      }

      const p = LatLng(3.15, 101.71);
      final a = memo.get('place', p, 'en', slow);
      final b = memo.get('place', const LatLng(3.15001, 101.71001), 'en', slow);
      answer.complete('KLCC');
      expect(await a, 'KLCC');
      expect(await b, 'KLCC');
      expect(asked, 1);
    });

    test('a failure or no answer is not kept', () async {
      const p = LatLng(3.15, 101.71);
      await expectLater(memo.get<String>('place', p, 'en', () async => throw Exception('down')), throwsException);
      expect(memo.length, 0);
      expect(await memo.get<String>('place', p, 'en', () async => null), isNull);
      expect(memo.length, 0);
      expect(await memo.get('place', p, 'en', ask), 'answer 1');
      expect(calls, 1);
    });

    test('waiters on a failing lookup all see the failure', () async {
      final answer = Completer<String?>();
      const p = LatLng(3.15, 101.71);
      final a = memo.get('place', p, 'en', () => answer.future);
      final b = memo.get('place', p, 'en', () => answer.future);
      answer.completeError(Exception('down'));
      await expectLater(a, throwsException);
      await expectLater(b, throwsException);
      expect(await memo.get('place', p, 'en', ask), 'answer 1');
    });

    test('answers are forgotten after the time limit', () async {
      const p = LatLng(3.15, 101.71);
      await memo.get('place', p, 'en', ask);
      clock = clock.add(const Duration(minutes: 29));
      await memo.get('place', p, 'en', ask);
      expect(calls, 1);
      clock = clock.add(const Duration(minutes: 2));
      expect(await memo.get('place', p, 'en', ask), 'answer 2');
    });

    test('only the most recently used cells are kept', () async {
      final small = GeoMemo(size: 2, now: () => clock);
      const a = LatLng(3.1, 101.1), b = LatLng(3.2, 101.2), c = LatLng(3.3, 101.3);
      await small.get('place', a, 'en', ask); // 1
      await small.get('place', b, 'en', ask); // 2
      await small.get('place', a, 'en', ask); // a used again
      await small.get('place', c, 'en', ask); // 3, b goes
      expect(small.length, 2);
      expect(calls, 3);
      expect(await small.get('place', a, 'en', ask), 'answer 1');
      expect(await small.get('place', b, 'en', ask), 'answer 4');
    });
  });

  group('the geo service names a cell once', () {
    test('reverse and reverseArea through geo, once per cell', () async {
      final asked = <String>[];
      final geo = GeoService(
        client: MockClient((_) async => http.Response('', 500)),
        profile: () => const MapProfile(reverse: ['google', 'nominatim']),
        lookup: (p) async {
          asked.add('${p['action']} ${p['provider']} ${p['lat']}');
          return {
            'place': {'name': 'Jalan Ampang', 'address': 'Jalan Ampang, KL', 'city': 'Kuala Lumpur'},
          };
        },
      );
      final p1 = await geo.reverse(const LatLng(3.15001, 101.71001));
      final p2 = await geo.reverse(const LatLng(3.15002, 101.71002));
      expect(p1.name, 'Jalan Ampang');
      expect(p2.name, 'Jalan Ampang');
      expect(p2.point, const LatLng(3.15002, 101.71002), reason: 'the caller\'s own point');
      expect((await geo.reverseArea(const LatLng(3.15001, 101.71001)))?.city, 'Kuala Lumpur');
      expect((await geo.reverseArea(const LatLng(3.15003, 101.71)))?.city, 'Kuala Lumpur');
      expect(asked, ['reverse google 3.15001', 'reverse google 3.15001']);
    });

    test('a pinned point (nothing answered) is asked again next time', () async {
      var up = false;
      var asked = 0;
      final geo = GeoService(
        client: MockClient((_) async => http.Response('', 500)),
        profile: () => const MapProfile(reverse: ['google']),
        lookup: (_) async {
          asked++;
          if (!up) throw Exception('down');
          return {
            'place': {'name': 'KLCC', 'address': 'KLCC, KL'},
          };
        },
      );
      const p = LatLng(3.1579, 101.7116);
      expect((await geo.reverse(p)).name, 'Pinned location');
      up = true;
      expect((await geo.reverse(p)).name, 'KLCC');
      expect((await geo.reverse(p)).name, 'KLCC');
      expect(asked, 2);
    });
  });
}
