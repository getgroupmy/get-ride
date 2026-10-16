import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../core/map_link.dart';
import '../core/map_profile.dart';
import '../core/smart_address.dart';

class Place {
  const Place({
    required this.name,
    required this.address,
    required this.point,
    this.types = const [],
    this.placeId,
    this.km,
    this.verified = false,
  });

  /// One of Google's Autocomplete suggestions: no position until it is
  /// looked up ([GeoService.resolve]) when picked.
  const Place.suggestion({
    required this.name,
    required this.address,
    required String this.placeId,
    this.types = const [],
    this.km,
  }) : point = const LatLng(0, 0),
       verified = false;

  final String name;
  final String address;
  final LatLng point;

  /// Google's place types ("airport", "street_address" …), where it said.
  final List<String> types;

  /// Google's place id, for a [pending] suggestion.
  final String? placeId;

  /// As the crow flies from the user, where the provider said (Autocomplete).
  final double? km;

  /// Google's Address Validation confirmed the address (smart address C).
  final bool verified;

  /// An Autocomplete suggestion not looked up yet: [point] means nothing.
  bool get pending => placeId != null && point == const LatLng(0, 0);
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

  /// Google bills Autocomplete's keystrokes and the pick as one session:
  /// made at the first search, ended by the pick ([resolve]).
  String? _session;
  final _random = math.Random();

  String get _searchSession =>
      _session ??= [for (var i = 0; i < 24; i++) '0123456789abcdefghijklmnopqrstuvwxyz'[_random.nextInt(36)]].join();

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

  /// How results are shown and checked (Admin → Settings → Maps).
  SmartAddress get smartAddress => SmartAddress(_profile().smartAddress);

  /// Places for [query]; a pasted Google Maps link (or coordinates) gives
  /// the place it points to.
  Future<List<Place>> search(String query, {LatLng? near}) async {
    final link = parseMapLink(query);
    if (link != null) {
      final p = await placeFromLink(link, near: near);
      return p == null ? [] : [p];
    }
    if (query.trim().length < 3) return [];
    final found = await _first<List<Place>>(_profile().search, (provider) async {
      if (provider == 'nominatim') return _nominatimSearch(query, near);
      final body = await _ask('search', provider, {
        'q': query,
        if (near != null) 'lat': '${near.latitude}',
        if (near != null) 'lng': '${near.longitude}',
        if (provider == 'google') 'session': _searchSession,
      });
      return [for (final p in (body?['places'] as List?) ?? const []) ?_placeFrom(p)];
    });
    return found ?? [];
  }

  /// A place from `geo`'s answer: with a position, or an Autocomplete
  /// suggestion (Google's id, no position yet).
  static Place? _placeFrom(Object? p) {
    if (p is! Map) return null;
    final types = [for (final t in (p['types'] as List?) ?? const []) '$t'];
    final name = '${p['name'] ?? ''}', address = '${p['address'] ?? ''}';
    if (p['lat'] is num && p['lng'] is num) {
      return Place(
        name: name,
        address: address,
        point: LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()),
        types: types,
      );
    }
    final id = p['id'];
    if (id is! String || id.isEmpty || name.isEmpty) return null;
    return Place.suggestion(
      name: name,
      address: address,
      placeId: id,
      types: types,
      km: p['km'] is num ? (p['km'] as num).toDouble() : null,
    );
  }

  /// [p] with its position: an Autocomplete suggestion looked up through
  /// `geo` (ending the search session), anything else as it is. Null when
  /// it can't be looked up.
  Future<Place?> resolve(Place p) async {
    if (!p.pending) return p;
    if (lookup == null) return null;
    final session = _session;
    _session = null;
    try {
      final body = await lookup!({
        'action': 'details',
        'provider': 'google',
        'id': p.placeId!,
        'session': ?session,
        'lang': 'en',
      });
      final found = _placeFrom(body?['place']);
      if (found == null || found.pending) return null;
      // Keep the suggestion's short name; the address is Google's full one.
      return Place(name: p.name, address: found.address, point: found.point, types: found.types);
    } catch (_) {
      return null;
    }
  }

  /// Smart address C: Google's Address Validation of [p]'s address, through
  /// `geo`. The corrected address (and position, when Google gives one),
  /// marked [Place.verified] when Google found every part; [p] as it is when
  /// it can't say.
  Future<Place> checkAddress(Place p) async {
    if (lookup == null) return p;
    try {
      final body = await lookup!({'action': 'validate', 'address': p.address.isEmpty ? p.name : p.address});
      final c = body?['checked'];
      if (c is! Map || '${c['address'] ?? ''}'.trim().isEmpty) return p;
      final at = c['lat'] is num && c['lng'] is num
          ? LatLng((c['lat'] as num).toDouble(), (c['lng'] as num).toDouble())
          : p.point;
      return Place(
        name: p.name,
        address: '${c['address']}'.trim(),
        point: at,
        types: p.types,
        verified: c['complete'] == true,
      );
    } catch (_) {
      return p;
    }
  }

  /// The place a Google Maps link points to: a share link expanded by `geo`
  /// first; a pin named from the link or by address lookup; a named place
  /// searched for near where the link's map was looking. Null when it can't
  /// be told.
  Future<Place?> placeFromLink(MapLink link, {LatLng? near}) async {
    var l = link;
    if (l.short) {
      if (lookup == null || l.url == null) return null;
      final body = await lookup!({'action': 'expand', 'url': l.url!}).catchError((_) => null);
      final long = body?['url'];
      final read = long is String ? parseMapLink(long) : null;
      if (read == null || read.short) return null;
      l = read;
    }
    final point = l.point;
    if (point != null) {
      final at = await reverse(point);
      final name = l.name?.trim();
      return Place(name: name == null || name.isEmpty ? at.name : name, address: at.address, point: point);
    }
    final q = l.query;
    if (q == null || q.trim().length < 3) return null;
    final found = await search(q, near: l.near ?? near);
    return found.isEmpty ? null : found.first;
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

  /// Each of [to]'s road distance in km from [from], in order (null where
  /// none was found), as place search results show it. The profile's
  /// distance providers in turn (OSRM by default; `straight` is as the crow
  /// flies); all null when none answers.
  Future<List<double?>> distances(LatLng from, List<LatLng> to) async {
    final none = List<double?>.filled(to.length, null);
    if (to.isEmpty) return none;
    try {
      final found = await _first<List<double?>>(_profile().distance, (provider) async {
        final List<double?>? km;
        if (provider == 'straight') {
          km = [for (final p in to) const Distance().as(LengthUnit.Meter, from, p) / 1000];
        } else if (provider == 'osrm') {
          km = await _osrmTable(from, to);
        } else {
          final body = await _ask('distance', provider, {
            'from': '${from.latitude},${from.longitude}',
            'to': to.map((p) => '${p.latitude},${p.longitude}').join(';'),
          });
          final list = body?['distances'];
          km = list is List && list.length == to.length ? [for (final d in list) d is num ? d.toDouble() : null] : null;
        }
        return km == null || km.every((d) => d == null) ? null : km;
      });
      return found ?? none;
    } catch (_) {
      return none;
    }
  }

  Future<List<double?>?> _osrmTable(LatLng from, List<LatLng> to) async {
    final coords = [from, ...to].map((p) => '${p.longitude},${p.latitude}').join(';');
    final uri = Uri.parse('$_osrmBase/table/v1/driving/$coords?sources=0&annotations=distance');
    final res = await _http.get(uri, headers: _headers);
    if (res.statusCode != 200) return null;
    final rows = (jsonDecode(res.body) as Map<String, dynamic>)['distances'];
    final row = rows is List && rows.isNotEmpty ? rows.first : null;
    if (row is! List || row.length != to.length + 1) return null;
    // The first column is the origin itself.
    return [for (final m in row.skip(1)) m is num ? m / 1000 : null];
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
