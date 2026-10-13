// Whether a host resolves on this phone's network. On the web the browser
// does its own lookups and reports nothing, so it always "resolves".
export 'backend_lookup_io.dart' if (dart.library.js_interop) 'backend_lookup_web.dart';
