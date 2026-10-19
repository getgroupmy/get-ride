import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// True when the browser's share sheet can take an image file.
bool canShareFiles() {
  try {
    final probe = web.File(<JSAny>[].toJS, 'probe.png', web.FilePropertyBag(type: 'image/png'));
    return web.window.navigator.canShare(web.ShareData(files: [probe].toJS));
  } catch (_) {
    // No Web Share at all (canShare missing).
    return false;
  }
}
