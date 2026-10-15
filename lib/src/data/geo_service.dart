import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../core/map_profile.dart';

class Place {
  const Place({required this.name, required this.address, required this.point});
  final String name;
  final String address;
  final LatLng point;
}

/// Where a point is, as a rate card is scoped: country, state, city, suburb.
class AreaInfo {
  const AreaInfo({this.country, this.state, this.city, this.suburb, this.label, this.address});
  final String? country;
  final String? state;
  final String? city;
  final String? suburb;

  /// A short place name ("Jalan Ampang, KLCC").
  final String? label;

  /// The geocoder's full one-line address.
  final String? address;

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
      address: display.trim().isEmpty ? null : display.trim(),
    );
  }
}

class RouteInfo {
  const RouteInfo({required this.distanceKm, required this.durationMin, required this.points});
  final double distanceKm;
  final double durationMin;
  final List<LatLng> points;
}

/// One lookup through the `geo` function (Admin → Settings → Maps): its JSON
/// answer, or null.
typedef GeoLookup = Future<Map<String, dynamic>?> Function(Map<String, String> params);

/// Geocoding (Nominatim) and routing (OSRM) over OpenStreetMap, so maps work
/// identically on web, desktop and mobile without a platform API key.
/// Swap the endpoints with --dart-define for self-hosted instances.
///
/// Admin → Settings → Maps (migration 0200) can put other providers first
/// (Google, Mapbox, HERE, TomTom, LocationIQ, MapTiler) per rider or partner
/// and kind of device: those are asked through the `geo` function
/// ([lookup]), which holds their keys, in the profile's order until one
/// answers.
class GeoService {
  GeoService({http.Client? client, this.lookup, MapProfile Function()? profile})
      : _http = client ?? http.Client(),
        _profile = profile ?? (() => activeMapProfile);
  final http.Client _http;
  final GeoLookup? lookup;
  final MapProfile Function() _profile;

  static const _nominatim = String.fromEnvironment(
    'NOMINATIM_URL',
    defaultValue: 'https://nominatim.openstreetmap.org',
  );
  static const _osrm = String.fromEnvironment(
    'OSRM_URL',
    defaultValue: 'https://router.project-osrm.org',
  );
  static const _countryCodes = String.fromEnvironment('GEO_COUNTRIES', defaultValue: 'my');

  String get _nominatimBase => _profile().nominatimUrl ?? _nominatim;
  String get _osrmBase => _profile().osrmUrl ?? _osrm;

  /// [providers] in order until one gives a non-null, non-empty answer. A
  /// provider with a key needs [lookup]; one that fails is skipped. When
  /// none answers, the first error is thrown again (as with Nominatim
  /// alone), else null.
  Future<T?> _first<T>(List<String> providers, Future<T?> Function(String provider) ask) async {
    Object? error;
    StackTrace? stack;
    for (final provider in providers) {
      if (!directGeoProviders.contains(provider) && lookup == null) continue;
      try {
        final r = await ask(provider);
        if (r != null && (r is! List || r.isNotEmpty)) return r;
      } catch (e, s) {
        error ??= e;
        stack ??= s;
      }
    }
    if (error != null) Error.throwWithStackTrace(error, stack!);
    return null;
  }

  Future<Map<String, dynamic>?> _ask(String action, String provider, Map<String, String> params) =>
      lookup!({'action': action, 'provider': provider, 'countries': _countryCodes, 'lang': 'en', ...params});

  Map<String, String> get _headers => kIsWeb
      ? const {'Accept-Language': 'en'}
      : const {'User-Agent': 'GET.ride Flutter (getgroup.my)', 'Accept-Language': 'en'};

  Future<List<Place>> search(String query, {LatLng? near}) async {
    if (query.trim().length < 3) return [];
    final found = await _first<List<Place>>(_profile().search, (provider) async {
      if (provider == 'nominatim') return _nominatimSearch(query, near);
      final body = await _ask('search', provider, {
        'q': query,
        if (near != null) 'lat': '${near.latitude}',
        if (near != null) 'lng': '${near.longitude}',
      });
      return [
        for (final p in (body?['places'] as List?) ?? const [])
          if (p is Map && p['lat'] is num && p['lng'] is num)
            Place(
              name: '${p['name'] ?? ''}',
              address: '${p['address'] ?? ''}',
              point: LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()),
            ),
      ];
    });
    return found ?? [];
  }

  Future<List<Place>> _nominatimSearch(String query, LatLng? near) async {
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
    final res = await _http.get(Uri.parse('$_nominatimBase/search').replace(queryParameters: params),
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
      final found = await _first<Place>(_profile().reverse, (provider) async {
        if (provider == 'nominatim') return _nominatimReverse(p);
        final a = await _proxyArea(provider, p);
        return a == null ? null : Place(name: a.label ?? a.address ?? '', address: a.address ?? '', point: p);
      });
      if (found != null) return found;
    } catch (_) {}
    final label = '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';
    return Place(name: 'Pinned location', address: label, point: p);
  }

  /// The area from a provider with a key, through `geo`; null when it has none.
  Future<AreaInfo?> _proxyArea(String provider, LatLng p) async {
    final body = await _ask('reverse', provider, {'lat': '${p.latitude}', 'lng': '${p.longitude}'});
    final m = body?['place'];
    if (m is! Map) return null;
    String? s(Object? v) => '${v ?? ''}'.trim().isEmpty ? null : '$v'.trim();
    return AreaInfo(
      country: s(m['country']),
      state: s(m['state']),
      city: s(m['city']),
      suburb: s(m['suburb']),
      label: s(m['name']),
      address: s(m['address']),
    );
  }

  Future<Place?> _nominatimReverse(LatLng p) async {
    try {
      final uri = Uri.parse('$_nominatimBase/reverse').replace(queryParameters: {
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
    return null;
  }

  /// Structured geography for [p] (country, state, city, suburb), which the
  /// meter resolves its rate card on, plus a short label for the receipt.
  /// Null when the geocoder cannot be reached.
  Future<AreaInfo?> reverseArea(LatLng p) async {
    try {
      return await _first<AreaInfo>(_profile().reverse, (provider) async {
        if (provider == 'nominatim') return _nominatimArea(p);
        return _proxyArea(provider, p);
      });
    } catch (_) {
      return null;
    }
  }

  Future<AreaInfo?> _nominatimArea(LatLng p) async {
    try {
      final uri = Uri.parse('$_nominatimBase/reverse').replace(queryParameters: {
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
      final found = await _first<RouteInfo>(_profile().routing, (provider) async {
        if (provider == 'osrm') return _osrmRoute(points);
        final body = await _ask('route', provider, {
          'points': points.map((p) => '${p.latitude},${p.longitude}').join(';'),
        });
        final r = body?['route'];
        if (r is! Map || r['distanceKm'] is! num || r['durationMin'] is! num) return null;
        return RouteInfo(
          distanceKm: (r['distanceKm'] as num).toDouble(),
          durationMin: (r['durationMin'] as num).toDouble(),
          points: [
            for (final c in (r['points'] as List?) ?? const [])
              if (c is List && c.length >= 2 && c[0] is num && c[1] is num)
                LatLng((c[0] as num).toDouble(), (c[1] as num).toDouble()),
          ],
        );
      });
      if (found != null) return found;
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

  Future<RouteInfo?> _osrmRoute(List<LatLng> points) async {
    try {
      final uri = Uri.parse(
        '$_osrmBase/route/v1/driving/${points.map((p) => '${p.longitude},${p.latitude}').join(';')}'
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
    return null;
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

/// Where the phone is, without ever asking for permission: null when
/// location is off or not granted. The last known fix when there is one
/// (cheap, no GPS wake-up), else a quick low-accuracy fix.
Future<LatLng?> knownPosition() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    final perm = await Geolocator.checkPermission();
    if (perm != LocationPermission.always && perm != LocationPermission.whileInUse) return null;
    if (!kIsWeb) {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return LatLng(last.latitude, last.longitude);
    }
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.low),
    ).timeout(const Duration(seconds: 8));
    return LatLng(pos.latitude, pos.longitude);
  } catch (_) {
    return null;
  }
}

/// Kuala Lumpur, where nothing else says where to open.
const klCenter = LatLng(3.1390, 101.6869);

/// Admin → App Settings → Default Start Location, set from the branding row
/// as it arrives (see `BrandingSync`); null keeps [klCenter].
LatLng? adminStartCenter;

/// The map centre before a fix arrives.
LatLng get defaultCenter => adminStartCenter ?? klCenter;
