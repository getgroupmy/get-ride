// Saving a file from the website: the browser downloads it (an anchor with
// the `download` attribute). Off the web there is no such thing, and
// [webDownload] answers false so the caller picks another way.
export 'web_download_stub.dart' if (dart.library.js_interop) 'web_download_web.dart';
