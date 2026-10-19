// The processor ABIs of the phone this runs on, best first, for picking the
// APK to hand it (core/app_builds.dart): Android's own list in the app, what
// the browser lets on in the web app. Empty when it can't be told.
export 'device_abis_stub.dart' if (dart.library.js_interop) 'device_abis_web.dart';
