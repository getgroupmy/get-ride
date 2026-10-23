// The phone's own face detector and text reader where there is one
// (on_device_mlkit.dart), none on the web (on_device_stub.dart).
export 'on_device_stub.dart' if (dart.library.io) 'on_device_mlkit.dart';
