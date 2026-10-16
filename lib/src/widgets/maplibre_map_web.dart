// A MapLibre map on the web (see maplibre_map.dart): MapLibre GL JS, served
// with the app (web/maplibre), loaded once; the map is created in a <div>
// that ignores the pointer (the app's map handles every gesture) and moved
// to wherever the app's map is.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';
import 'package:web/web.dart' as web;

const maplibreSupported = true;

/// `maplibregl`, loaded once per page; null when it can't load.
Future<JSObject?>? _lib;

Future<JSObject?> _load() => _lib ??= () async {
  final css = web.HTMLLinkElement()
    ..rel = 'stylesheet'
    ..href = 'maplibre/maplibre-gl.css';
  web.document.head!.append(css);
  // The debug build's module loader would take the library as a module
  // instead of a global: hidden while it loads.
  final define = globalContext['define'];
  globalContext['define'] = null;
  final ready = Completer<bool>();
  final script = web.HTMLScriptElement()
    ..src = 'maplibre/maplibre-gl.js'
    ..async = true;
  script.onload = ((web.Event _) => ready.complete(true)).toJS;
  script.onerror = ((web.Event _) => ready.complete(false)).toJS;
  web.document.head!.append(script);
  final ok = await ready.future.timeout(const Duration(seconds: 20), onTimeout: () => false);
  globalContext['define'] = define;
  if (!ok) return null;
  final lib = globalContext['maplibregl'];
  return lib.isA<JSObject>() ? lib as JSObject : null;
}();

/// MapLibre's zoom for flutter_map's: its tiles are 512 pixels, not 256.
double maplibreZoom(double zoom) => zoom - 1;

class MapLibreMapView extends StatefulWidget {
  const MapLibreMapView({
    super.key,
    required this.style,
    required this.apiKey,
    required this.center,
    required this.zoom,
    required this.size,
    this.onFailure,
  });

  /// The style's URL.
  final String style;

  /// Added to every request to Amazon Location that lacks it (its tiles).
  final String apiKey;
  final LatLng center;
  final double zoom;
  final Size size;

  /// MapLibre could not load, the browser has no WebGL, or the key was refused.
  final VoidCallback? onFailure;

  @override
  State<MapLibreMapView> createState() => _MapLibreMapViewState();
}

class _MapLibreMapViewState extends State<MapLibreMapView> {
  JSObject? _gl;
  JSObject? _map;
  web.HTMLElement? _div;
  bool _failed = false;

  void _fail() {
    if (_failed) return;
    _failed = true;
    widget.onFailure?.call();
  }

  @override
  void initState() {
    super.initState();
    _load().then((gl) {
      if (!mounted) return;
      if (gl == null) return _fail();
      _gl = gl;
      _create();
    });
  }

  @override
  void dispose() {
    try {
      _map?.callMethod('remove'.toJS);
    } catch (_) {}
    super.dispose();
  }

  JSAny _camera() => {
    'center': [widget.center.longitude, widget.center.latitude],
    'zoom': maplibreZoom(widget.zoom),
  }.jsify()!;

  JSObject _request(String url, [String? _]) {
    final u = Uri.tryParse(url);
    final keyed = u != null && u.host.endsWith('.amazonaws.com') && !u.queryParameters.containsKey('key');
    return {
          'url': keyed ? u.replace(queryParameters: {...u.queryParameters, 'key': widget.apiKey}).toString() : url,
        }.jsify()!
        as JSObject;
  }

  void _create() {
    final gl = _gl, div = _div;
    if (gl == null || div == null || _map != null || _failed) return;
    try {
      final options =
          {
                        'style': widget.style,
                'interactive': false,
                'attributionControl': false,
                'center': [widget.center.longitude, widget.center.latitude],
                'zoom': maplibreZoom(widget.zoom),
              }.jsify()!
              as JSObject;
      options['container'] = div;
      options['transformRequest'] = _request.toJS;
      final map = (gl['Map'] as JSFunction).callAsConstructor<JSObject>(options);
      map.callMethod(
        'on'.toJS,
        'error'.toJS,
        ((JSObject e) {
          // A refused key (401/403) gives way to tiles; a tile that merely
          // failed to load does not.
          final status = (e['error'] as JSObject?)?['status'];
          final code = status.isA<JSNumber>() ? (status as JSNumber).toDartInt : 0;
          if (code == 401 || code == 403) _fail();
        }).toJS,
      );
      _map = map;
    } catch (_) {
      // No WebGL, or MapLibre refused the options.
      _fail();
    }
  }

  @override
  void didUpdateWidget(MapLibreMapView old) {
    super.didUpdateWidget(old);
    final map = _map;
    if (map == null) return;
    if (old.size != widget.size) map.callMethod('resize'.toJS);
    if (old.style != widget.style) map.callMethod('setStyle'.toJS, widget.style.toJS);
    if (old.center != widget.center || old.zoom != widget.zoom || old.size != widget.size) {
      map.callMethod('jumpTo'.toJS, _camera());
    }
  }

  @override
  Widget build(BuildContext context) => HtmlElementView.fromTagName(
    tagName: 'div',
    onElementCreated: (element) {
      final div = element as web.HTMLElement;
      div.style
        ..width = '100%'
        ..height = '100%'
        // The app's map takes every gesture; this one only shows.
        ..pointerEvents = 'none';
      _div = div;
      _create();
    },
  );
}
