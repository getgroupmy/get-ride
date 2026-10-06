import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class Place {
  const Place({required this.name, required this.address, required this.point});
  final String name;
  final String address;
  final LatLng point;
}

/// Where a point is, as a rate card is scoped: country, state, city, suburb.
class AreaInfo {
  const AreaInfo({this.country, this.state, this.city, this.suburb, this.label});
  final String? country;
  final String? state;
  final String? city;
  final String? suburb;

  /// A short place name ("Jalan Ampang, KLCC").
  final String? label;

  static AreaInfo fromNominatim(Map<String, dynamic> m) {
    final a = (m['address'] as Map?)?.cast<String, dynamic>() ?? const {};
    String? pick(List<String> keys) {
      for (final k in keys) {
        final v = '${a[k] ?? ''}'.trim();
        if (v.isNotEmpty) return v;
      }
      return null;
    }

    final display = '${m['display_name'] ?? ''}';
    final parts = display.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).take(2).toList();
    return AreaInfo(
      country: pick(['country']),
      state: pick(['state', 'region']),
      city: pick(['city', 'town', 'municipality', 'village']),
      suburb: pick(['suburb', 'neighbourhood', 'quarter', 'city_district']),
      label: parts.isEmpty ? null : parts.join(', '),
    );
  }
}

class RouteInfo {
  const RouteInfo({required this.distanceKm, required this.durationMin, required this.points});
  final double distanceKm;
  final double durationMin;
  final List<LatLng> points;
}

/// Geocoding (Nominatim) and routing (OSRM) over OpenStreetMap, so maps work
/// identically on web, desktop and mobile without a platform API key.
/// Swap the endpoints with --dart-define for self-hosted instances.
class GeoService {
  GeoService({http.Client? client}) : _http = client ?? http.Client();
  final http.Client _http;

  static const _nominatim = String.fromEnvironment(
    'NOMINATIM_URL',
    defaultValue: 'https://nominatim.openstreetmap.org',
  );
  static const _osrm = String.fromEnvironment(
    'OSRM_URL',
    defaultValue: 'https://router.project-osrm.org',
  );
  static const _countryCodes = String.fromEnvironment('GEO_COUNTRIES', defaultValue: 'my');

  Map<String, String> get _headers => kIsWeb
      ? const {'Accept-Language': 'en'}
      : const {'User-Agent': 'GET.ride Flutter (getgroup.my)', 'Accept-Language': 'en'};

  Future<List<Place>> search(String query, {LatLng? near}) async {
    if (query.trim().length < 3) return [];
    final params = {
      'q': query,
      'format': 'jsonv2',
      'addressdetails': '1',
      'limit': '8',
      if (_countryCodes.isNotEmpty) 'countrycodes': _countryCodes,
      if (near != null)
        'viewbox':
            '${near.longitude - 0.5},${near.latitude + 0.5},${near.longitude + 0.5},${near.latitude - 0.5}',
    };
    final res = await _http.get(Uri.parse('$_nominatim/search').replace(queryParameters: params),
        headers: _headers);
    if (res.statusCode != 200) return [];
    final list = jsonDecode(res.body) as List;
    return list.map((e) {
      final m = e as Map<String, dynamic>;
      final display = (m['display_name'] as String?) ?? '';
      final name = (m['name'] as String?)?.trim();
      return Place(
        name: (name == null || name.isEmpty) ? display.split(',').first : name,
        address: display,
        point: LatLng(double.parse(m['lat'] as String), double.parse(m['lon'] as String)),
      );
    }).toList();
  }

  Future<Place> reverse(LatLng p) async {
    try {
      final uri = Uri.parse('$_nominatim/reverse').replace(queryParameters: {
        'lat': '${p.latitude}',
        'lon': '${p.longitude}',
        'format': 'jsonv2',
        'zoom': '18',
      });
      final res = await _http.get(uri, headers: _headers);
      if (res.statusCode == 200) {
        final m = jsonDecode(res.body) as Map<String, dynamic>;
        final display = (m['display_name'] as String?) ?? '';
        final name = (m['name'] as String?)?.trim();
        return Place(
          name: (name == null || name.isEmpty) ? display.split(',').first : name,
          address: display,
          point: p,
        );
      }
    } catch (_) {}
    final label = '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';
    return Place(name: 'Pinned location', address: label, point: p);
  }

  /// Structured geography for [p] (country, state, city, suburb), which the
  /// meter resolves its rate card on, plus a short label for the receipt.
  /// Null when the geocoder cannot be reached.
  Future<AreaInfo?> reverseArea(LatLng p) async {
    try {
      final uri = Uri.parse('$_nominatim/reverse').replace(queryParameters: {
        'lat': '${p.latitude}',
        'lon': '${p.longitude}',
        'format': 'jsonv2',
        'addressdetails': '1',
        'zoom': '18',
      });
      final res = await _http.get(uri, headers: _headers);
      if (res.statusCode != 200) return null;
      final m = jsonDecode(res.body) as Map<String, dynamic>;
      return AreaInfo.fromNominatim(m);
    } catch (_) {
      return null;
    }
  }

  /// Driving route; falls back to a straight-line estimate when the router is
  /// unreachable so booking never dead-ends.
  ///
  /// [via] are stops visited in order on the way.
  Future<RouteInfo> route(LatLng from, LatLng to, {List<LatLng> via = const []}) async {
    final points = [from, ...via, to];
    try {
      final uri = Uri.parse(
        '$_osrm/route/v1/driving/${points.map((p) => '${p.longitude},${p.latitude}').join(';')}'
        '?overview=full&geometries=geojson',
      );
      final res = await _http.get(uri, headers: _headers);
      if (res.statusCode == 200) {
        final m = jsonDecode(res.body) as Map<String, dynamic>;
        final routes = m['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final r = routes.first as Map<String, dynamic>;
          final coords = ((r['geometry'] as Map)['coordinates'] as List)
              .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
              .toList();
          return RouteInfo(
            distanceKm: (r['distance'] as num) / 1000,
            durationMin: (r['duration'] as num) / 60,
            points: coords,
          );
        }
      }
    } catch (_) {}
    if (via.isEmpty) return straightLine(from, to);
    // Leg by leg, so the estimate still goes through every stop.
    var km = 0.0, min = 0.0;
    for (var i = 0; i + 1 < points.length; i++) {
      final leg = straightLine(points[i], points[i + 1]);
      km += leg.distanceKm;
      min += leg.durationMin;
    }
    return RouteInfo(distanceKm: km, durationMin: min, points: points);
  }

  static RouteInfo straightLine(LatLng from, LatLng to) {
    final km = const Distance().as(LengthUnit.Meter, from, to) / 1000 * 1.3;
    return RouteInfo(distanceKm: km, durationMin: math.max(1, km / 30 * 60), points: [from, to]);
  }
}

/// Current device position, or null when unavailable / denied.
Future<LatLng?> currentPosition() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).timeout(const Duration(seconds: 12));
    return LatLng(pos.latitude, pos.longitude);
  } catch (_) {
    return null;
  }
}

/// Kuala Lumpur — map centre before a fix arrives.
const defaultCenter = LatLng(3.1390, 101.6869);
