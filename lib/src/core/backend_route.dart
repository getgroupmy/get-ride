/// Which address the app talks to the backend on.
///
/// Normally the Supabase project's own host. Some networks fail to look it
/// up (an iPhone on one carrier got "Failed host lookup", errno 8, while
/// public DNS answered fine), and then nothing works, sign-in included. The
/// backend has a second address, `api.getride.my`, which the Cloudflare
/// worker passes straight through to the project (cloudflare/subdomain-
/// proxy). At launch the app looks both up and uses the second only when
/// the first does not resolve and the second does. Admin → App Settings →
/// Backend network adds addresses and DNS-over-HTTPS resolvers to that
/// (core/backend_network.dart).
library;

/// The backend's second address.
const backendFallbackHost = 'api.getride.my';

/// How long each lookup may take before it counts as failed.
const backendLookupTimeout = Duration(seconds: 3);

/// The URL the app was launched against (set in main); the project's own
/// URL until then.
String? _active;

String activeBackendUrl(String direct) => _active ?? direct;

/// The IP address the app connects to when a DNS-over-HTTPS resolver had
/// to find it (the phone's own DNS could not); null otherwise.
String? _pinnedIp;

String? get activeBackendPinnedIp => _pinnedIp;

void setActiveBackendUrl(String url, {String? pinnedIp}) {
  _active = url;
  _pinnedIp = pinnedIp;
}

/// Whether the app is on another address than the project's own.
bool onBackendFallback(String direct) => _active != null && _active != direct;

/// [url] moved onto [active] when it points at the project's own host
/// ([direct]): a stored file link (avatar, document photo, chat image)
/// loads through whichever address the app is on. Anything else is left
/// alone. Pure.
String onActiveBackend(String url, String direct, String active) {
  if (active == direct) return url;
  final from = Uri.tryParse(direct), to = Uri.tryParse(active), u = Uri.tryParse(url);
  if (from == null || to == null || u == null || u.host != from.host) return url;
  return u.replace(scheme: to.scheme, host: to.host, port: to.hasPort ? to.port : null).toString();
}

/// How Settings → Backend describes the connection: the project's host,
/// "via" the address used when it is another, and the resolver-found IP
/// when the phone's own DNS could not look it up.
String backendRouteText(String direct) {
  final own = Uri.parse(direct).host;
  final active = Uri.parse(activeBackendUrl(direct)).host;
  final via = active == own ? own : '$own via $active';
  final ip = activeBackendPinnedIp;
  return ip == null ? via : '$via ($ip, DNS over HTTPS)';
}
