import 'dart:typed_data';

/// Not a browser: nothing is downloaded.
bool webDownload(Uint8List bytes, {required String fileName, required String mimeType}) => false;
