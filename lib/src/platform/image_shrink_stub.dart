import 'dart:typed_data';

/// Not a browser: null, so the caller scales the photo in an isolate.
Future<Uint8List?> browserShrinkImage(Uint8List bytes, {required int maxSide, required int quality}) async => null;
