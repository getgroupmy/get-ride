// Scaling a photo down in the browser: the web build has no isolates, so a
// 6 MB photo decoded in Dart would freeze the page. The browser decodes it
// (turning it upright from its EXIF) and writes the JPEG off the page's
// thread. Off the web this answers null and the caller uses `compute`.
export 'image_shrink_stub.dart' if (dart.library.js_interop) 'image_shrink_web.dart';
