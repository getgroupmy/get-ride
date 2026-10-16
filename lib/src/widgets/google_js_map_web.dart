// Google's JavaScript map on the web (see google_js_map.dart): loaded once
// with the browser key, created in a <div> that ignores the pointer (the
// app's map handles every gesture), and moved to wherever the app's map is.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';
import 'package:web/web.dart' as web;

import 'google_map_style.dart';

const googleJsSupported = true;

/// The API's `maps` library, loaded once per page; null when it can't load.
Future<JSObject?>? _maps;

/// Google's name for why it refused the key on this page
/// ("ApiNotActivatedMapError", "RefererNotAllowedMapError" …), read from the
/// error the API writes to the browser console; null while it hasn't. Only
/// Admin → Settings → Maps → Test shows it; riders' and partners' maps just
/// fall back.
final googleJsError = ValueNotifier<String?>(null);

final _errorName = RegExp(r'Google Maps JavaScript API (?:error|warning): (\w+)');

/// Listens to the console for the API's own error, passing everything on.
void _watchConsole() {
  final console = globalContext['console'] as JSObject;
  final original = console['error'] as JSFunction;
  console['error'] = ((JSAny? a, JSAny? b, JSAny? c) {
    final name = _errorName.firstMatch('${a?.dartify() ?? ''}')?.group(1);
    if (name != null && googleJsError.value == null) googleJsError.value = name;
    original.callMethod('apply'.toJS, console, [a, b, c].whereType<JSAny>().toList().toJS);
  }).toJS;
}

/// Called by the API when the key is refused (wrong key, API off, site not
/// allowed); every Google JavaScript map then gives way to tiles.
final _authFailed = <VoidCallback>{};

Future<JSObject?> _loadMaps(String key) => _maps ??= () async {
  final ready = Completer<bool>();
  _watchConsole();
  globalContext['__getRideGoogleMapsReady'] = (() {
    if (!ready.isCompleted) ready.complete(true);
  }).toJS;
  globalContext['gm_authFailure'] = (() {
    for (final f in [..._authFailed]) {
      f();
    }
  }).toJS;
  final script = web.HTMLScriptElement()
    ..src =
        'https://maps.googleapis.com/maps/api/js?key=${Uri.encodeQueryComponent(key)}'
        '&v=weekly&loading=async&callback=__getRideGoogleMapsReady'
    ..async = true;
  script.onerror = ((web.Event _) {
    if (!ready.isCompleted) ready.complete(false);
  }).toJS;
  web.document.head!.append(script);
  if (!await ready.future.timeout(const Duration(seconds: 20), onTimeout: () => false)) return null;
  try {
    final maps = (globalContext['google'] as JSObject)['maps'] as JSObject;
    final lib = maps.callMethod<JSPromise<JSObject>>('importLibrary'.toJS, 'maps'.toJS);
    return await lib.toDart;
  } catch (_) {
    return null;
  }
}();

class GoogleJsMapView extends StatefulWidget {
  const GoogleJsMapView({
    super.key,
    required this.apiKey,
    required this.center,
    required this.zoom,
    this.satellite = false,
    this.mapType,
    this.dark = false,
    this.traffic = false,
    this.onFailure,
  });

  final String apiKey;
  final LatLng center;
  final double zoom;
  final bool satellite;

  /// "roadmap", "satellite", "hybrid" or "terrain" (migration 0211); null for
  /// the roadmap, or satellite when [satellite].
  final String? mapType;
  final bool dark;
  final bool traffic;

  /// The API could not load, or refused the key.
  final VoidCallback? onFailure;

  @override
  State<GoogleJsMapView> createState() => _GoogleJsMapViewState();
}

class _GoogleJsMapViewState extends State<GoogleJsMapView> {
  JSObject? _lib;
  JSObject? _map;
  JSObject? _trafficLayer;
  web.HTMLElement? _div;

  void _fail() => widget.onFailure?.call();

  @override
  void initState() {
    super.initState();
    _authFailed.add(_fail);
    _loadMaps(widget.apiKey).then((lib) {
      if (!mounted) return;
      if (lib == null) return _fail();
      _lib = lib;
      _create();
    });
  }

  @override
  void dispose() {
    _authFailed.remove(_fail);
    _trafficLayer?.callMethod('setMap'.toJS, null);
    super.dispose();
  }

  JSAny _camera() => {
    'center': {'lat': widget.center.latitude, 'lng': widget.center.longitude},
    'zoom': widget.zoom,
  }.jsify()!;

  String get _type => widget.mapType ?? (widget.satellite ? 'satellite' : 'roadmap');

  JSAny _look() => {
    'mapTypeId': _type,
    'styles': widget.dark && _type == 'roadmap' ? googleNightStyle : <Object>[],
    'backgroundColor': widget.dark ? '#242f3e' : '#e5e3df',
  }.jsify()!;

  void _create() {
    final lib = _lib, div = _div;
    if (lib == null || div == null || _map != null) return;
    final options =
        {
              'disableDefaultUI': true,
              'gestureHandling': 'none',
              'keyboardShortcuts': false,
              'clickableIcons': false,
              'isFractionalZoomEnabled': true,
            }.jsify()
            as JSObject;
    final map = (lib['Map'] as JSFunction).callAsConstructor<JSObject>(div, options);
    map.callMethod('setOptions'.toJS, _look());
    map.callMethod('moveCamera'.toJS, _camera());
    _map = map;
    _syncTraffic();
  }

  void _syncTraffic() {
    final lib = _lib, map = _map;
    if (lib == null || map == null) return;
    if (widget.traffic) {
      _trafficLayer ??= (lib['TrafficLayer'] as JSFunction).callAsConstructor<JSObject>();
      _trafficLayer!.callMethod('setMap'.toJS, map);
    } else {
      _trafficLayer?.callMethod('setMap'.toJS, null);
    }
  }

  @override
  void didUpdateWidget(GoogleJsMapView old) {
    super.didUpdateWidget(old);
    final map = _map;
    if (map == null) return;
    if (old.center != widget.center || old.zoom != widget.zoom) map.callMethod('moveCamera'.toJS, _camera());
    if (old.satellite != widget.satellite || old.mapType != widget.mapType || old.dark != widget.dark) {
      map.callMethod('setOptions'.toJS, _look());
    }
    if (old.traffic != widget.traffic) _syncTraffic();
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
