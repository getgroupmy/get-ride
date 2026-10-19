import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Has the browser download [bytes] as [fileName]: a Blob, an object URL
/// and a hidden `<a download>` clicked. False when it could not.
bool webDownload(Uint8List bytes, {required String fileName, required String mimeType}) {
  try {
    final blob = web.Blob(<JSAny>[bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
    final url = web.URL.createObjectURL(blob);
    final a = web.HTMLAnchorElement()
      ..href = url
      ..download = fileName
      ..style.display = 'none';
    web.document.body?.append(a);
    a.click();
    a.remove();
    // Freed once the download has taken the bytes.
    Timer(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
    return true;
  } catch (_) {
    return false;
  }
}
