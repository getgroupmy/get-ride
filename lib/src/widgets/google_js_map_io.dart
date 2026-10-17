// Google's JavaScript map off the web (see google_js_map.dart): on Windows
// and macOS (migration 0210), and on Android and iOS beside Google's own map
// (0213), in a web view of this site's google_map.html, so the browser key's
// website restriction holds as on the web. On Linux there is none, and the
// map keeps its tiles.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:webview_flutter/webview_flutter.dart' as wf;
import 'package:webview_windows/webview_windows.dart' as ww;

import 'google_map_style.dart';

bool get googleJsSupported =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isIOS || Platform.isAndroid);

/// Google's name for why it refused the key ("ApiNotActivatedMapError" …),
/// as the page reports it; only Admin → Settings → Maps → Test shows it.
final googleJsError = ValueNotifier<String?>(null);

/// The page on this site that draws the map (web/google_map.html).
const googleJsPageUrl = String.fromEnvironment(
  'GOOGLE_MAP_PAGE_URL',
  defaultValue: 'https://getride.my/google_map.html',
);

/// [googleJsPageUrl] for [key], which goes in the #fragment (never sent to a
/// server), with Google's dark style.
String googleJsPageAddress(String key) =>
    '$googleJsPageUrl#${Uri(queryParameters: {'key': key, 'night': jsonEncode(googleNightStyle)}).query}';

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

  /// The page could not load, or Google refused the key.
  final VoidCallback? onFailure;

  @override
  State<GoogleJsMapView> createState() => _GoogleJsMapViewState();
}

class _GoogleJsMapViewState extends State<GoogleJsMapView> {
  wf.WebViewController? _mac;
  ww.WebviewController? _windows;
  StreamSubscription<dynamic>? _messages;
  Timer? _timeout;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (!googleJsSupported) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fail('NotSupported'));
      return;
    }
    // Not drawn within 20 s: the app's own map instead.
    _timeout = Timer(const Duration(seconds: 20), () {
      if (!_ready) _fail('NotLoaded');
    });
    final address = googleJsPageAddress(widget.apiKey);
    // WKWebView on macOS and iOS, Android's WebView; WebView2 on Windows.
    if (!Platform.isWindows) {
      _mac = wf.WebViewController()
        ..setJavaScriptMode(wf.JavaScriptMode.unrestricted)
        ..addJavaScriptChannel('GetRide', onMessageReceived: (m) => _message(m.message))
        ..setNavigationDelegate(
          wf.NavigationDelegate(
            onWebResourceError: (e) {
              if (e.isForMainFrame ?? true) _fail('NotLoaded');
            },
          ),
        )
        ..loadRequest(Uri.parse(address));
    } else {
      unawaited(_startWindows(address));
    }
  }

  Future<void> _startWindows(String address) async {
    try {
      // No WebView2 runtime on this PC: no map in a web view.
      if (await ww.WebviewController.getWebViewVersion() == null) return _fail('NoWebView');
      final c = ww.WebviewController();
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      _messages = c.webMessage.listen((m) => _message('$m'));
      await c.loadUrl(address);
      setState(() => _windows = c);
    } catch (_) {
      _fail('NotLoaded');
    }
  }

  void _message(String m) {
    if (m == 'ready') {
      _ready = true;
      _timeout?.cancel();
      _push(view: true, look: true);
    } else if (m.startsWith('failed:')) {
      _fail(m.substring(7));
    }
  }

  void _fail(String name) {
    if (_failed || !mounted) return;
    _failed = true;
    _timeout?.cancel();
    googleJsError.value ??= name;
    widget.onFailure?.call();
  }

  void _run(String js) {
    if (!_ready) return;
    unawaited(_mac?.runJavaScript(js).catchError((_) {}));
    unawaited(_windows?.executeScript(js).catchError((_) {}));
  }

  void _push({bool view = false, bool look = false}) {
    if (view) _run('setView(${widget.center.latitude},${widget.center.longitude},${widget.zoom},0)');
    if (look) {
      final type = widget.mapType ?? (widget.satellite ? 'satellite' : 'roadmap');
      _run("setLook(${widget.satellite},${widget.dark},${widget.traffic},'$type')");
    }
  }

  @override
  void didUpdateWidget(GoogleJsMapView old) {
    super.didUpdateWidget(old);
    _push(
      view: old.center != widget.center || old.zoom != widget.zoom,
      look:
          old.satellite != widget.satellite ||
          old.mapType != widget.mapType ||
          old.dark != widget.dark ||
          old.traffic != widget.traffic,
    );
  }

  @override
  void dispose() {
    _timeout?.cancel();
    unawaited(_messages?.cancel());
    unawaited(_windows?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The app's map takes every gesture; this one only shows.
    final mac = _mac, windows = _windows;
    return IgnorePointer(
      child: mac != null
          ? wf.WebViewWidget(controller: mac)
          : windows != null
          ? ww.Webview(windows)
          : const SizedBox.expand(),
    );
  }
}
