// The pure shaping of Apple Maps' metres/seconds into the "To pickup" chip's
// km and whole minutes (lib/src/data/route_eta.dart). The MethodChannel call
// itself is iOS-native and not exercised here.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/route_eta.dart';
import 'package:latlong2/latlong.dart';

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

  group('fare-chain estimate → chip (non-iOS)', () {
    test('km passes through; minutes round up with a one-minute floor', () {
      final r = pickupEtaFromEstimate(3.2, 7.1);
      expect(r.km, 3.2);
      expect(r.minutes, 8, reason: '7.1 min → 8');
    });

    test('a whole-minute duration is not rounded further', () {
      expect(pickupEtaFromEstimate(1.0, 5.0).minutes, 5);
    });

    test('an almost-instant hop still reads one minute', () {
      final r = pickupEtaFromEstimate(0.05, 0.2);
      expect(r.km, 0.05);
      expect(r.minutes, 1);
    });
  });

  group('latLngsFromFlat (Apple route geometry off the channel)', () {
    test('a flat [lat, lng, …] list becomes points', () {
      final pts = latLngsFromFlat([3.15, 101.71, 3.16, 101.72, 3.17, 101.73]);
      expect(pts, hasLength(3));
      expect(pts.first, const LatLng(3.15, 101.71));
      expect(pts.last, const LatLng(3.17, 101.73));
    });

    test('a trailing odd value is dropped, not misread', () {
      final pts = latLngsFromFlat([3.15, 101.71, 3.16]);
      expect(pts, hasLength(1));
      expect(pts.single, const LatLng(3.15, 101.71));
    });

    test('a pair out of range is skipped, the rest kept', () {
      final pts = latLngsFromFlat([200.0, 101.71, 3.16, 101.72, 3.17, 999.0]);
      expect(pts, [const LatLng(3.16, 101.72)]);
    });

    test('anything that is not a list, or is empty, is no points', () {
      expect(latLngsFromFlat(null), isEmpty);
      expect(latLngsFromFlat('nope'), isEmpty);
      expect(latLngsFromFlat(const <double>[]), isEmpty);
    });

    test('integer-valued entries decode too', () {
      expect(latLngsFromFlat([3, 101, 4, 102]), [
        const LatLng(3, 101),
        const LatLng(4, 102),
      ]);
    });
  });
}
