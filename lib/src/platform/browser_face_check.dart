// The in-browser face check (migration 0320): the selfie and the ID photo
// compared in the admin's browser with vladmandic/human
// (web/face_check/face_check.js), the last fallback of the face match order.
// Only the web build has it; the phone and desktop apps never run it.
export 'browser_face_check_stub.dart' if (dart.library.js_interop) 'browser_face_check_web.dart';
