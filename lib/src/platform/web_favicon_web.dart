import 'package:web/web.dart' as web;

/// Points the tab icon (and the home-screen icon a browser saves) at [url],
/// or back at the built-in ones when null: index.html has one for a light
/// and one for a dark colour scheme.
void setWebFavicon(String? url) {
  try {
    final icons = web.document.querySelectorAll('link[rel="icon"]');
    for (var i = 0; i < icons.length; i++) {
      final icon = icons.item(i) as web.HTMLLinkElement;
      final dark = icon.media.contains('dark');
      icon.href = url ?? (dark ? 'favicon-dark.png' : 'favicon.png');
      icon.type = url == null ? 'image/png' : '';
    }
    final touch = web.document.querySelector('link[rel="apple-touch-icon"]') as web.HTMLLinkElement?;
    touch?.href = url ?? 'icons/Icon-192.png';
  } catch (_) {}
}
