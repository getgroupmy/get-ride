import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/route_estimate.dart';

void main() {
  test('reads a proxy estimate', () {
    final e = parseRouteEstimate({
      'ok': true,
      'estimate': {
        'distance_km': 18.4,
        'duration_min': '32',
        'summary': ' Via MRR2, heavy traffic ',
        'provider': 'gemini',
        'toll_count': 2,
        'toll_total': 4.6,
        'tolls': [
          {'name': 'Batu', 'charge': 2.3},
          {'name': '', 'charge': 2.3},
          {'charge': -1},
          'junk',
        ],
      },
    })!;
    expect(e.distanceKm, 18.4);
    expect(e.durationMin, 32);
    expect(e.summary, 'Via MRR2, heavy traffic');
    expect(e.provider, 'gemini');
    expect(e.tollCount, 2);
    expect(e.tolls.length, 2);
    expect(e.tolls[1].name, isNull);
    expect(e.tollsToShow, 4.6);
  });

  test('no estimate', () {
    expect(parseRouteEstimate(null), isNull);
    expect(parseRouteEstimate({'ok': false, 'error': 'x'}), isNull);
    expect(parseRouteEstimate({'ok': true, 'estimate': null, 'reason': 'service_disabled'}), isNull);
    expect(
      parseRouteEstimate({
        'ok': true,
        'estimate': {'distance_km': 0, 'duration_min': 10},
      }),
      isNull,
    );
    expect(
      parseRouteEstimate({
        'ok': true,
        'estimate': {'distance_km': 5},
      }),
      isNull,
    );
  });

  test('tolls fall back to the listed booths, else none', () {
    expect(
      const RouteEstimate(
        distanceKm: 1,
        durationMin: 1,
        tolls: [TollBooth(charge: 1.5), TollBooth(charge: 2)],
      ).tollsToShow,
      3.5,
    );
    expect(const RouteEstimate(distanceKm: 1, durationMin: 1, tollTotal: 0).tollsToShow, isNull);
  });

  test('the fare is priced on the AI estimate when there is one', () {
    final map = fareBasis(routeKm: 10, routeMin: 15);
    expect(map.distanceKm, 10);
    expect(map.durationMin, 15);
    const ai = RouteEstimate(distanceKm: 12, durationMin: 30);
    final traffic = fareBasis(routeKm: 10, routeMin: 15, ai: ai);
    expect(traffic.distanceKm, 12);
    expect(traffic.durationMin, 30);
    expect(
      calculateFare(traffic.distanceKm, traffic.durationMin),
      greaterThan(calculateFare(map.distanceKm, map.durationMin)),
    );
  });
}
