// Google's JavaScript map and Google traffic (Admin → Settings → Maps,
// migration 0204): read from the profile, drawn by the browser on the web
// and in a web view on Windows, macOS, Android and iOS (0210, 0213), and the
// map's own tiles whenever Google's map can't be shown.
//
// Whether there is a web view is the machine's own answer in the app. Here
// each test says which it is (debugGoogleJsSupported), so the same things
// are checked on a Linux, macOS or Windows test machine, and the web view is
// a stand-in the test drives as the page would.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/map_appearance.dart';
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/widgets/google_js_layer.dart';
import 'package:get_ride/src/widgets/google_js_map_io.dart';
import 'package:get_ride/src/widgets/map_tiles.dart';
import 'package:latlong2/latlong.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebViewWidget;
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// The page in the stand-in web view: what the app loaded and ran in it, and
/// a way to answer as web/google_map.html does.
class _Page {
  LoadRequestParams? loaded;
  final scripts = <String>[];
  void Function(JavaScriptMessage)? _channel;
  WebResourceErrorCallback? _onError;

  void say(String message) => _channel!(JavaScriptMessage(message: message));
  void failToLoad() => _onError!(const WebResourceError(errorCode: -1, description: 'offline', isForMainFrame: true));
}

class _FakeWebViewPlatform extends WebViewPlatform {
  final pages = <_Page>[];

  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) {
    final page = _Page();
    pages.add(page);
    return _FakeController(params, page);
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) =>
      _FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) =>
      _FakeWebViewWidget(params);
}

class _FakeController extends PlatformWebViewController {
  _FakeController(super.params, this.page) : super.implementation();
  final _Page page;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams javaScriptChannelParams) async {
    expect(javaScriptChannelParams.name, 'GetRide');
    page._channel = javaScriptChannelParams.onMessageReceived;
  }

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async {
    page._onError = (handler as _FakeNavigationDelegate).onError;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async => page.loaded = params;

  @override
  Future<void> runJavaScript(String javaScript) async => page.scripts.add(javaScript);
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();
  WebResourceErrorCallback? onError;

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback onNavigationRequest) async {}
  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}
  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}
  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {}
  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback onWebResourceError) async => onError = onWebResourceError;
  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {}
  @override
  Future<void> setOnHttpAuthRequest(HttpAuthRequestCallback onHttpAuthRequest) async {}
  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback onSslAuthError) async {}
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand(key: ValueKey('web view'));
}

void main() {
  // Before any test says otherwise: a machine with no web view for the map
  // starts on the app's own tiles, one with a web view on Google's map.
  final failedAtStart = googleJsFailed.value;
  final supportedHere = googleJsSupported;

  test("the app's own tiles from the start exactly where there is no web view", () {
    expect(failedAtStart, !supportedHere);
  });

  group('the profile', () {
    test("Google's JavaScript map: the browser key and the map type, no tiles", () {
      final light = MapTileSpec.fromJson({
        'url': '',
        'engine': 'google_js',
        'key': 'BROWSER',
        'mapType': 'roadmap',
        'attribution': 'Map data © Google',
      })!;
      expect(light.isGoogleJs, isTrue);
      expect(light.googleJsKey, 'BROWSER');
      expect(light.url, MapTileSpec.googleJsRoadmap);
      final sat = MapTileSpec.fromJson({'engine': 'google_js', 'key': 'BROWSER', 'mapType': 'satellite'})!;
      expect(sat.url, MapTileSpec.googleJsSatellite);
      expect(MapTileSpec.fromJson({'engine': 'google_js', 'key': ''}), isNull, reason: 'no key, no map');
      expect(MapTileSpec.fromJson({'url': '', 'darken': false}), isNull, reason: 'an older answer without a template');
      expect(light == MapTileSpec.googleJs('OTHER'), isFalse);
    });

    test('Google traffic', () {
      final t = MapTrafficSpec.fromJson({'google': true})!;
      expect([t.google, t.off, t.url], [true, false, null]);
      expect(MapTrafficSpec.fromJson({'off': true})!.google, isFalse);
    });

    test('on the web and where there is a web view; elsewhere the tiles the app was built with', () {
      const spec = MapTileSpec.googleJs('BROWSER');
      const profile = MapProfile(light: spec, dark: spec);
      final web = profileTileSource(profile, dark: false, web: true, googleJs: false)!;
      expect(web.googleJsKey, 'BROWSER');
      final webView = profileTileSource(profile, dark: true, web: false, googleJs: true)!;
      expect(webView.googleJsKey, 'BROWSER');
      expect(profileTileSource(profile, dark: true, web: false, googleJs: false), isNull);

      // Not told: the machine's own answer.
      addTearDown(() => debugGoogleJsSupported = null);
      debugGoogleJsSupported = false;
      expect(profileTileSource(profile, dark: true, web: false), isNull);
      debugGoogleJsSupported = true;
      expect(profileTileSource(profile, dark: true, web: false)!.googleJsKey, 'BROWSER');
    });
  });

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    // The admin's "Follow app theme": the map is dark when the app is.
    Future<void> pump(WidgetTester tester) => tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: MapAppearanceScope(
            appearance: MapAppearance.app,
            child: SizedBox(
              width: 400,
              height: 400,
              child: FlutterMap(
                options: const MapOptions(initialCenter: LatLng(3.15, 101.7), initialZoom: 14),
                children: const [
                  GoogleJsBaseLayer(
                    apiKey: 'BROWSER',
                    fallback: Text('app tiles', key: ValueKey('fallback')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    /// This test's machine: with a web view for the map or without, and
    /// starting as the app does on such a machine.
    void machine({required bool webView}) {
      debugGoogleJsSupported = webView;
      googleJsFailed.value = !webView;
      googleJsError.value = null;
      addTearDown(() {
        debugGoogleJsSupported = null;
        googleJsFailed.value = failedAtStart;
        googleJsError.value = null;
      });
    }

    final ignoresPointer = find.descendant(of: find.byType(GoogleJsBaseLayer), matching: find.byType(IgnorePointer));

    group('no web view', () {
      testWidgets("the app's tiles when Google's map can't be shown ($mode)", (tester) async {
        machine(webView: false);
        expect(googleJsFailed.value, isTrue, reason: 'nothing to draw it');
        await pump(tester);
        expect(find.byKey(const ValueKey('fallback')), findsOneWidget);
        expect(find.byType(WebViewWidget), findsNothing);
      });

      testWidgets("Google's map under the app's layers, taking no gestures ($mode)", (tester) async {
        machine(webView: false);
        googleJsFailed.value = false;
        await pump(tester);
        expect(find.byKey(const ValueKey('fallback')), findsNothing);
        expect(ignoresPointer, findsWidgets);
        expect(googleJsFailed.value, isTrue, reason: 'the map itself says it cannot draw here');
        expect(googleJsError.value, 'NotSupported');
        await tester.pump();
        expect(find.byKey(const ValueKey('fallback')), findsOneWidget, reason: 'gives way when Google refuses');
      });
    });

    group('in a web view', () {
      late _FakeWebViewPlatform platform;

      Future<_Page> open(WidgetTester tester) async {
        machine(webView: true);
        platform = _FakeWebViewPlatform();
        WebViewPlatform.instance = platform;
        await pump(tester);
        return platform.pages.single;
      }

      testWidgets("Google's map under the app's layers, taking no gestures ($mode)", (tester) async {
        final page = await open(tester);
        expect(find.byKey(const ValueKey('fallback')), findsNothing);
        final view = find.byKey(const ValueKey('web view'));
        expect(view, findsOneWidget);
        expect(
          find.ancestor(of: view, matching: ignoresPointer),
          findsWidgets,
          reason: 'the web view is under an IgnorePointer: the app\'s map takes every gesture',
        );
        expect(tester.widgetList<IgnorePointer>(ignoresPointer).every((w) => w.ignoring), isTrue);

        // The site's page, the key in the #fragment (never sent to a server).
        expect(page.loaded!.uri.toString(), googleJsPageAddress('BROWSER'));
        expect(page.loaded!.uri.fragment, contains('key=BROWSER'));
        expect(page.loaded!.uri.query, isEmpty);
        expect(page.scripts, isEmpty, reason: 'nothing is run before the page is ready');

        // Ready: where the app's map is, and its light or dark look.
        page.say('ready');
        expect(page.scripts, ['setView(3.15,101.7,14.0,0)', "setLook(false,$dark,false,'roadmap')"]);
        expect(googleJsFailed.value, isFalse);
        await tester.pump(const Duration(seconds: 30));
        expect(find.byKey(const ValueKey('fallback')), findsNothing, reason: 'drawn in time: it stays');
      });

      testWidgets("the app's tiles when Google refuses the key ($mode)", (tester) async {
        final page = await open(tester);
        page.say('ready');
        page.say('failed:InvalidKeyMapError');
        expect(googleJsFailed.value, isTrue);
        expect(googleJsError.value, 'InvalidKeyMapError');
        await tester.pump();
        expect(find.byKey(const ValueKey('fallback')), findsOneWidget);
        expect(find.byType(WebViewWidget), findsNothing);
      });

      testWidgets("the app's tiles when the page can't load ($mode)", (tester) async {
        final page = await open(tester);
        page.failToLoad();
        expect(googleJsError.value, 'NotLoaded');
        await tester.pump();
        expect(find.byKey(const ValueKey('fallback')), findsOneWidget);
      });

      testWidgets("the app's tiles when the map is not drawn within 20 s ($mode)", (tester) async {
        await open(tester);
        await tester.pump(const Duration(seconds: 19));
        expect(find.byKey(const ValueKey('fallback')), findsNothing);
        await tester.pump(const Duration(seconds: 2));
        expect(googleJsError.value, 'NotLoaded');
        await tester.pump();
        expect(find.byKey(const ValueKey('fallback')), findsOneWidget);
      });
    });
  }
}
