// MapRouteLine's value equality (apple_native_layer.dart) is what lets the
// route notifier skip redundant redraws of MapKit's own polyline: the line is
// only handed to the native map again when the points, colour or width change.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/widgets/apple_native_layer.dart';
import 'package:latlong2/latlong.dart';

void main() {
  const a = LatLng(3.1, 101.6);
  const b = LatLng(3.2, 101.7);

  test('equal when the points, colour and width all match', () {
    expect(
      const MapRouteLine(points: [a, b], color: Color(0xFF111111), width: 4),
      const MapRouteLine(points: [a, b], color: Color(0xFF111111), width: 4),
    );
    expect(
      const MapRouteLine(points: [a, b], color: Color(0xFF111111), width: 4).hashCode,
      const MapRouteLine(points: [a, b], color: Color(0xFF111111), width: 4).hashCode,
    );
  });

  test('differs when a point, the colour or the width differs', () {
    const base = MapRouteLine(points: [a, b], color: Color(0xFF111111), width: 4);
    expect(base == const MapRouteLine(points: [a, b], color: Color(0xFF2DABE2), width: 4), isFalse);
    expect(base == const MapRouteLine(points: [a, b], color: Color(0xFF111111), width: 5), isFalse);
    expect(base == const MapRouteLine(points: [b, a], color: Color(0xFF111111), width: 4), isFalse);
    expect(base == const MapRouteLine(points: [a], color: Color(0xFF111111), width: 4), isFalse);
  });
}
