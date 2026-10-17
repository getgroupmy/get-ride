/// The credit a map has to show for the tiles it draws. Each provider's terms
/// ask for its own line; Google's Map Tiles API also asks for the Google logo
/// and the data owners for the area on screen (from its viewport request).
/// Admin → Settings → Maps (migration 0200) sends the credit with the tiles;
/// for the app's built-in or build-time tiles it is worked out from the URL.
/// Pure.
library;

/// What to show under a map.
class MapCredit {
  const MapCredit(this.text, {this.google = false});

  /// The line itself, its © already in it.
  final String text;

  /// Google's tiles: the logo and the viewport's copyright, always on screen.
  final bool google;

  @override
  bool operator ==(Object other) => other is MapCredit && other.text == text && other.google == google;

  @override
  int get hashCode => Object.hash(text, google);
}

const osmCredit = '© OpenStreetMap contributors';
const googleDefaultCredit = 'Map data © Google';

/// Known tile hosts and their credit, checked in order against the URL's host.
const _creditByHost = <(String, String)>[
  ('tile.openstreetmap.org', osmCredit),
  ('arcgisonline.com', 'Imagery © Esri'),
  ('api.mapbox.com', '© Mapbox © OpenStreetMap'),
  ('hereapi.com', '© HERE'),
  ('api.tomtom.com', '© TomTom'),
  ('api.maptiler.com', '© MapTiler © OpenStreetMap contributors'),
  ('basemaps.cartocdn.com', '© CARTO © OpenStreetMap contributors'),
  ('stadiamaps.com', '© Stadia Maps © OpenMapTiles © OpenStreetMap contributors'),
  ('thunderforest.com', '© Thunderforest © OpenStreetMap contributors'),
];

/// Known tile hosts and the provider's name, shown beside the ⓘ button so
/// the corner names the map on screen.
const _brandByHost = <(String, String)>[
  ('tile.openstreetmap.org', 'OpenStreetMap'),
  ('arcgisonline.com', 'Esri'),
  ('api.mapbox.com', 'Mapbox'),
  ('hereapi.com', 'HERE'),
  ('api.tomtom.com', 'TomTom'),
  ('api.maptiler.com', 'MapTiler'),
  ('basemaps.cartocdn.com', 'CARTO'),
  ('stadiamaps.com', 'Stadia Maps'),
  ('thunderforest.com', 'Thunderforest'),
  ('google.com', 'Google'),
  ('googleapis.com', 'Google'),
  ('amazonaws.com', 'Amazon Location'),
];

/// The name of who draws the tiles at [url]; empty for a host not known.
String mapBrandFor(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  for (final (h, brand) in _brandByHost) {
    if (host == h || host.endsWith('.$h')) return brand;
  }
  return '';
}

bool isGoogleTiles(String url) => Uri.tryParse(url)?.host == 'tile.googleapis.com';

/// The credit for tiles at [url]; [attribution] (sent with the tiles by
/// Admin → Settings → Maps) wins when it is set. Unknown hosts are credited
/// to OpenStreetMap, whose data almost every other XYZ map is drawn from.
MapCredit mapCreditFor(String url, {String attribution = ''}) {
  if (isGoogleTiles(url)) {
    return MapCredit(attribution.trim().isEmpty ? googleDefaultCredit : attribution.trim(), google: true);
  }
  if (attribution.trim().isNotEmpty) return MapCredit(attribution.trim());
  final host = Uri.tryParse(url)?.host ?? '';
  for (final (h, credit) in _creditByHost) {
    if (host == h || host.endsWith('.$h')) return MapCredit(credit);
  }
  return const MapCredit(osmCredit);
}

/// Google's viewport request for the area on screen, built from the tile URL
/// (its session and key); null when [tileUrl] is not Google's.
Uri? googleViewportUri(
  String tileUrl, {
  required int zoom,
  required double north,
  required double south,
  required double east,
  required double west,
}) {
  final u = Uri.tryParse(tileUrl);
  if (u == null || u.host != 'tile.googleapis.com') return null;
  final session = u.queryParameters['session'];
  final key = u.queryParameters['key'];
  if (session == null || session.isEmpty || key == null || key.isEmpty) return null;
  String f(double v) => v.toStringAsFixed(5);
  return Uri.https('tile.googleapis.com', '/tile/v1/viewport', {
    'session': session,
    'key': key,
    'zoom': '${zoom.clamp(0, 22)}',
    'north': f(north.clamp(-90, 90)),
    'south': f(south.clamp(-90, 90)),
    'east': f(east.clamp(-180, 180)),
    'west': f(west.clamp(-180, 180)),
  });
}

/// The copyright line from Google's viewport answer, else null.
String? parseGoogleCopyright(Object? json) {
  if (json is! Map) return null;
  final c = '${json['copyright'] ?? ''}'.trim();
  return c.isEmpty ? null : c;
}

/// Google's own logo images, as its attribution guidelines link them: the one
/// for light map backgrounds, and the one for dark maps and imagery.
const googleLogoOnWhite = 'https://developers.google.com/static/maps/documentation/images/google_on_white.png';
const googleLogoOnDark = 'https://developers.google.com/static/maps/documentation/images/google_on_non_white.png';
