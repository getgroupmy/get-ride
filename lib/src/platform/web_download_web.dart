import 'dart:convert';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Has the browser download [bytes] as [fileName]; false when it could not.
bool webDownload(Uint8List bytes, {required String fileName, required String mimeType}) {
  try {
    final a = web.HTMLAnchorElement()
      ..href = 'data:$mimeType;base64,${base64Encode(bytes)}'
      ..download = fileName
      ..style.display = 'none';
    web.document.body?.append(a);
    a.click();
    a.remove();
    return true;
  } catch (_) {
    return false;
  }
}
