// The pure shaping of Apple Maps' metres/seconds into the "To pickup" chip's
// km and whole minutes (lib/src/data/route_eta.dart). The MethodChannel call
// itself is iOS-native and not exercised here.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/route_eta.dart';

void main() {
  test('metres → km, seconds → whole minutes (rounded up)', () {
    final r = routeEtaResult(1500, 300);
    expect(r.km, 1.5);
    expect(r.minutes, 5);
  });

  test('minutes round up, with a one-minute floor', () {
    expect(routeEtaResult(10000, 330).minutes, 6, reason: '5.5 min → 6');
    expect(routeEtaResult(10000, 301).minutes, 6, reason: 'just over 5 → 6');
    expect(routeEtaResult(10000, 300).minutes, 5);
    expect(routeEtaResult(25, 4).minutes, 1, reason: 'almost no time → 1 min floor');
  });

  test('km keeps the exact ratio (formatted elsewhere)', () {
    expect(routeEtaResult(47600, 2820).km, 47.6);
    expect(routeEtaResult(25, 4).km, 0.025);
  });
}
