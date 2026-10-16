// Google's JavaScript map (Admin → Settings → Maps, migration 0204): the
// browser draws it, the app's own layers sit on top. Web only; elsewhere
// [googleJsSupported] is false and the map keeps its tiles.
export 'google_js_map_stub.dart' if (dart.library.js_interop) 'google_js_map_web.dart';
