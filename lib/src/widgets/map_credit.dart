// The credit under every map, for whichever provider draws its tiles (see
// core/map_credit.dart). Most get flutter_map's ⓘ button with their line;
// Google's tiles get the Google logo and the copyright for the area on
// screen, always visible, as its Map Tiles API terms ask.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import '../core/map_credit.dart';
import 'map_tiles.dart';

/// Asks Google for the copyright of a viewport; null when it can't say.
/// Overridden in tests.
Future<String?> Function(Uri uri) googleViewportFetcher = (uri) async {
  try {
    final r = await http.get(uri).timeout(const Duration(seconds: 8));
    return r.statusCode == 200 ? parseGoogleCopyright(jsonDecode(r.body)) : null;
  } catch (_) {
    return null;
  }
};

/// The credit for the tiles [baseTileLayer] draws with the same arguments.
/// Put it last among a FlutterMap's children.
class MapCreditLayer extends StatelessWidget {
  const MapCreditLayer({super.key, this.satellite = false});

  final bool satellite;

  @override
  Widget build(BuildContext context) {
    final source = currentTileSource(context, satellite: satellite);
    final credit = mapCreditFor(source.url, attribution: source.attribution);
    if (credit.google) {
      return GoogleMapCredit(tileUrl: source.url, fallback: credit.text, onDark: source.darken || satellite);
    }
    return RichAttributionWidget(
      alignment: AttributionAlignment.bottomLeft,
      attributions: [TextSourceAttribution(credit.text, prependCopyright: false)],
    );
  }
}

/// Google's logo and the data owners for the area on screen, in the corner.
class GoogleMapCredit extends StatefulWidget {
  const GoogleMapCredit({super.key, required this.tileUrl, required this.fallback, this.onDark = false});

  final String tileUrl;
  final String fallback;

  /// A dark map or imagery under it: Google's logo for non-white backgrounds.
  final bool onDark;

  @override
  State<GoogleMapCredit> createState() => _GoogleMapCreditState();
}

class _GoogleMapCreditState extends State<GoogleMapCredit> {
  final _cache = <String, String>{};
  String? _copyright;
  String? _asked;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// Asks again once the map has settled on a new area (rounded, so small
  /// pans reuse the answer).
  void _ask(MapCamera camera) {
    final b = camera.visibleBounds;
    final z = camera.zoom.round();
    String r(double v) => v.toStringAsFixed(2);
    final key = '$z|${r(b.north)}|${r(b.south)}|${r(b.east)}|${r(b.west)}';
    if (key == _asked) return;
    _asked = key;
    final hit = _cache[key];
    if (hit != null) {
      _copyright = hit;
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      final uri = googleViewportUri(
        widget.tileUrl,
        zoom: z,
        north: b.north,
        south: b.south,
        east: b.east,
        west: b.west,
      );
      if (uri == null) return;
      final c = await googleViewportFetcher(uri);
      if (c == null || !mounted) return;
      _cache[key] = c;
      if (_asked == key) setState(() => _copyright = c);
    });
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.maybeOf(context);
    if (camera != null) _ask(camera);
    final text = _copyright ?? widget.fallback;
    final ink = widget.onDark ? Colors.white : const Color(0xFF3C4043);
    final shade = widget.onDark ? const Color(0x99000000) : const Color(0xB3FFFFFF);
    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: DecoratedBox(
          key: const ValueKey('google-map-credit'),
          decoration: BoxDecoration(color: shade, borderRadius: BorderRadius.circular(4)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.network(
                  widget.onDark ? googleLogoOnDark : googleLogoOnWhite,
                  key: const ValueKey('google-map-logo'),
                  height: 16,
                  semanticLabel: 'Google',
                  // Offline or blocked: the name, so the credit is never only text.
                  errorBuilder: (_, _, _) => Text(
                    'Google',
                    style: TextStyle(color: ink, fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    text,
                    key: const ValueKey('google-map-copyright'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: ink, fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
