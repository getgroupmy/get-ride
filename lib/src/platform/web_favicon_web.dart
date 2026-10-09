import 'package:web/web.dart' as web;

/// Points the tab icon (and the home-screen icon a browser saves) at [url],
/// or back at the built-in one when null.
void setWebFavicon(String? url) {
  try {
    final icon = web.document.querySelector('link[rel="icon"]') as web.HTMLLinkElement?;
    final touch = web.document.querySelector('link[rel="apple-touch-icon"]') as web.HTMLLinkElement?;
    icon?.href = url ?? 'favicon.png';
    icon?.type = url == null ? 'image/png' : '';
    touch?.href = url ?? 'icons/Icon-192.png';
  } catch (_) {}
}
