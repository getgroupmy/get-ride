// A Google Maps link (or plain coordinates) pasted into place search: where
// it points and what it names. Pure.
//
//   https://maps.app.goo.gl/AbC123            a share link: expanded by `geo` first
//   https://www.google.com/maps/place/KLIA/@2.74,101.70,17z/data=…!3d2.7456!4d101.7072
//   https://maps.google.com/?q=3.139,101.6869    https://www.google.com/maps/search/?api=1&query=…
//   https://www.google.com/maps/@3.13,101.68,15z  3.1390, 101.6869
import 'package:latlong2/latlong.dart';

class MapLink {
  const MapLink({this.point, this.name, this.query, this.near, this.url, this.short = false, this.exact = false});

  /// Where it points; null when it only names a place ([query]).
  final LatLng? point;

  /// The place's name, from a `/maps/place/<name>/` link.
  final String? name;

  /// Text to search for, when the link names a place but gives no point.
  final String? query;

  /// Where the link's map was looking, to search [query] near.
  final LatLng? near;

  /// A short share link, to be expanded (by `geo`) before it can be read.
  final bool short;

  /// The short link itself.
  final String? url;

  /// [point] is the place's own pin, not just where the map was looking.
  final bool exact;

  @override
  String toString() => 'MapLink($point, $name, $query, short: $short, exact: $exact)';
}

final _coords = RegExp(r'^\s*(-?\d{1,2}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*$');
final _pin = RegExp(r'!3d(-?\d{1,2}\.\d+)!4d(-?\d{1,3}\.\d+)');
final _view = RegExp(r'@(-?\d{1,2}\.\d+),(-?\d{1,3}\.\d+)');

/// Google's own short and share hosts.
const _shortHosts = {'maps.app.goo.gl', 'goo.gl', 'share.google', 'g.co'};

/// www.google.com, maps.google.com, google.com.my …
bool isGoogleMapsHost(String host) => RegExp(r'^((www|maps)\.)?google\.[a-z]{2,3}(\.[a-z]{2})?$').hasMatch(host);

LatLng? _point(String lat, String lng) {
  final la = double.tryParse(lat), ln = double.tryParse(lng);
  if (la == null || ln == null || la.abs() > 90 || ln.abs() > 180 || (la == 0 && ln == 0)) return null;
  return LatLng(la, ln);
}

String _words(String s) {
  try {
    s = Uri.decodeComponent(s.replaceAll('+', ' '));
  } catch (_) {
    s = s.replaceAll('+', ' ');
  }
  return s.trim();
}

/// [input] read as a Google Maps link or coordinates; null for anything else
/// (it is then searched as text).
MapLink? parseMapLink(String input) {
  final text = input.trim();
  final c = _coords.firstMatch(text);
  if (c != null) {
    final p = _point(c[1]!, c[2]!);
    return p == null ? null : MapLink(point: p, exact: true);
  }
  final uri = Uri.tryParse(text.startsWith('http') ? text : 'https://$text');
  if (uri == null || !text.contains('.') || text.contains(' ')) return null;
  final host = uri.host.toLowerCase();
  if (_shortHosts.contains(host)) {
    if (host == 'goo.gl' && !uri.path.startsWith('/maps')) return null;
    return MapLink(short: true, url: uri.toString());
  }
  if (!isGoogleMapsHost(host)) return null;
  if (!uri.path.startsWith('/maps') && !uri.queryParameters.containsKey('q')) return null;

  final segs = uri.pathSegments;
  String? name;
  final placeAt = segs.indexOf('place');
  if (placeAt >= 0 && placeAt + 1 < segs.length && !segs[placeAt + 1].startsWith('@')) {
    name = _words(segs[placeAt + 1]);
  }
  String? query;
  final searchAt = segs.indexOf('search');
  if (searchAt >= 0 && searchAt + 1 < segs.length && !segs[searchAt + 1].startsWith('@')) {
    query = _words(segs[searchAt + 1]);
  }

  final pin = _pin.firstMatch(text);
  if (pin != null) {
    final p = _point(pin[1]!, pin[2]!);
    if (p != null) return MapLink(point: p, name: name, exact: true);
  }
  for (final k in ['q', 'query', 'destination', 'daddr', 'll']) {
    final v = uri.queryParameters[k];
    if (v == null || v.trim().isEmpty) continue;
    final m = _coords.firstMatch(v);
    if (m != null) {
      final p = _point(m[1]!, m[2]!);
      if (p != null) return MapLink(point: p, name: name, exact: true);
    } else {
      query ??= _words(v);
    }
  }
  final view = _view.firstMatch(text);
  final seen = view == null ? null : _point(view[1]!, view[2]!);
  if (name != null || query != null) return MapLink(name: name, query: name ?? query, near: seen);
  return seen == null ? null : MapLink(point: seen);
}
