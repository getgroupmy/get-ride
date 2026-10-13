import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Reloads the page.
void reloadWebPage() {
  try {
    web.window.location.reload();
  } catch (_) {}
}

/// Whether the tab is out of view.
bool webPageHidden() {
  try {
    return web.document.hidden;
  } catch (_) {
    return false;
  }
}

/// Calls [onChange] with [webPageHidden] whenever the tab is shown or
/// hidden; the returned function stops it.
void Function() onWebPageVisibility(void Function(bool hidden) onChange) {
  final listener = ((web.Event _) => onChange(webPageHidden())).toJS;
  web.document.addEventListener('visibilitychange', listener);
  return () => web.document.removeEventListener('visibilitychange', listener);
}
