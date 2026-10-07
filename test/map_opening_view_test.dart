import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:latlong2/latlong.dart';

const klia = LatLng(2.7456, 101.7072), klcc = LatLng(3.1579, 101.7116);

void main() {
  test('a map of a long trip opens framing it, not zoomed in on the first point', () {
    const size = Size(390, 360);
    final v = openingView(const [klia, klcc], const [], size);
    // KLIA to KLCC is ~46 km: about zoom 9-10 on a phone, nowhere near 14.
    expect(v.zoom, inInclusiveRange(8.5, 10.5));
    expect(v.center.latitude, closeTo((klia.latitude + klcc.latitude) / 2, 0.02));
    // Both ends are on screen, inside the padding.
    final camera = MapCamera(crs: const Epsg3857(), center: v.center, zoom: v.zoom, rotation: 0, nonRotatedSize: size);
    for (final p in const [klia, klcc]) {
      final px = camera.latLngToScreenOffset(p);
      expect(px.dx, inInclusiveRange(63, size.width - 63));
      expect(px.dy, inInclusiveRange(63, size.height - 63));
    }
  });

  test('one point opens on it; nothing opens on the default; no size yet waits on the first point', () {
    expect(openingView(const [klcc], const [], const Size(390, 360)), (center: klcc, zoom: 15));
    expect(openingView(const [], const [], const Size(390, 360)).center, defaultCenter);
    expect(openingView(const [klia, klcc], const [], Size.zero), (center: klia, zoom: 14));
    expect(openingView(const [klia, klcc], const [], const Size(double.infinity, 300)).zoom, 14);
  });

  test('two points close together stop at street zoom', () {
    final v = openingView(const [klcc, LatLng(3.1581, 101.7118)], const [], const Size(390, 360));
    expect(v.zoom, 16);
  });
}
