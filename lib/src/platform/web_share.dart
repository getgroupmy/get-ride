// Whether this platform's share sheet takes files (an image). A phone or
// computer app always does; a browser only with the Web Share API for
// files (`navigator.canShare({files})`), which most desktop browsers lack.
export 'web_share_stub.dart' if (dart.library.js_interop) 'web_share_web.dart';
