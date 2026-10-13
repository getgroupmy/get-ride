/// Admin → App Settings → Backend network: the addresses the app may reach
/// the backend on, and the DNS-over-HTTPS resolvers it asks when the
/// phone's own DNS cannot look any of them up.
///
/// The settings ride on the `app_branding` row (column `network`, migration
/// 0171) and are cached on the phone with the rest of the branding, so they
/// apply from the launch after the app last reached the backend -- a phone
/// that cannot reach it cannot read new settings, so they have to be in
/// hand before they are needed. A phone that never connected still has the
/// built-in route ([backendFallbackHost]) and the built-in resolvers.
///
/// Every session token goes to whichever address is used, so an address is
/// only taken from the admin's list when it is the project's own host or
/// under [backendAllowedDomain] ([isAllowedBackend]); anything else is
/// ignored however it got into the row. A resolver only answers with an IP
/// address, and the connection to that address still has to show a valid
/// certificate for the backend's own name, so a wrong resolver can stop the
/// app connecting but cannot read its traffic.
library;

import 'backend_route.dart';

/// The domain admin-listed backend addresses must be under.
const backendAllowedDomain = 'getride.my';

/// The resolvers asked when none is configured. Addressed by IP so that
/// asking them needs no DNS (both certificates cover the IP address), and
/// both answer the JSON API (`?name=…&type=A`).
const defaultDohResolvers = ['https://1.1.1.1/dns-query', 'https://8.8.8.8/resolve'];

/// How many entries each list keeps; a launch tries each in turn.
const backendNetworkMaxEntries = 5;

/// The routes a launch may try, which the admin switches on or off and puts
/// in order (Admin → App Settings → Backend network → Fallback order).
enum BackendRouteLevel {
  /// The project's own address, looked up with the phone's DNS.
  device('device', 'Project address (device DNS)'),

  /// The admin's extra addresses ([BackendNetwork.backends]), in their order.
  extra('extra', 'Extra addresses added by admin'),

  /// The built-in second address, [backendFallbackHost].
  builtin('builtin', backendFallbackHost);

  const BackendRouteLevel(this.key, this.label);

  /// How the level is stored in `app_branding.network.order`.
  final String key;
  final String label;

  static BackendRouteLevel? fromKey(Object? key) {
    for (final l in values) {
      if (l.key == key) return l;
    }
    return null;
  }
}

/// The order a launch tries the routes in when the admin has set none:
/// every one, own address first.
const defaultBackendRouteOrder = BackendRouteLevel.values;

/// The admin's network settings, as read from `app_branding.network`.
class BackendNetwork {
  const BackendNetwork({
    this.backends = const [],
    this.dohResolvers = const [],
    this.order = defaultBackendRouteOrder,
  });

  static const none = BackendNetwork();

  /// Extra backend addresses (`https://host`), tried after the project's
  /// own and before [backendFallbackHost].
  final List<String> backends;

  /// DNS-over-HTTPS resolvers; empty means [defaultDohResolvers].
  final List<String> dohResolvers;

  /// The routes switched on, in the order a launch tries them. A level left
  /// out is not tried at all, by the phone's DNS or by a resolver.
  final List<BackendRouteLevel> order;

  bool get isEmpty => backends.isEmpty && dohResolvers.isEmpty && _same(order, defaultBackendRouteOrder);

  /// The resolvers to ask: the admin's, else the defaults.
  List<String> get resolvers => dohResolvers.isEmpty ? defaultDohResolvers : dohResolvers;

  /// From the stored JSON; anything unusable is dropped, never an error.
  static BackendNetwork fromJson(Object? raw) {
    if (raw is! Map) return none;
    List<String> list(Object? v, String? Function(String) clean) {
      final out = <String>[];
      if (v is List) {
        for (final e in v) {
          final c = e is String ? clean(e) : null;
          if (c != null && !out.contains(c)) out.add(c);
          if (out.length >= backendNetworkMaxEntries) break;
        }
      }
      return out;
    }

    return BackendNetwork(
      backends: list(raw['backends'], normalizeBackendUrl),
      dohResolvers: list(raw['doh'], normalizeDohUrl),
      order: parseBackendRouteOrder(raw['order']),
    );
  }

  Map<String, dynamic> toJson() => {
    if (backends.isNotEmpty) 'backends': backends,
    if (dohResolvers.isNotEmpty) 'doh': dohResolvers,
    if (!_same(order, defaultBackendRouteOrder)) 'order': [for (final l in order) l.key],
  };

  @override
  bool operator ==(Object other) =>
      other is BackendNetwork &&
      _same(other.backends, backends) &&
      _same(other.dohResolvers, dohResolvers) &&
      _same(other.order, order);

  @override
  int get hashCode => Object.hash(Object.hashAll(backends), Object.hashAll(dohResolvers), Object.hashAll(order));
}

/// The stored order: known levels, each once, in the order given. Missing,
/// unreadable or naming no level at all, it is the default -- a row cannot
/// leave a launch with nothing to try. Pure.
List<BackendRouteLevel> parseBackendRouteOrder(Object? raw) {
  if (raw is! List) return defaultBackendRouteOrder;
  final out = <BackendRouteLevel>[];
  for (final e in raw) {
    final l = BackendRouteLevel.fromKey(e);
    if (l != null && !out.contains(l)) out.add(l);
  }
  return out.isEmpty ? defaultBackendRouteOrder : out;
}

bool _same<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// `api2.getride.my` or `https://api2.getride.my/` → `https://api2.getride.my`;
/// null for anything that is not a plain https host (a path, a query,
/// credentials or plain http are refused). Pure.
String? normalizeBackendUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.scheme != 'https' || u.host.isEmpty || u.userInfo.isNotEmpty) return null;
  if (u.path.isNotEmpty && u.path != '/') return null;
  if (u.hasQuery || u.hasFragment) return null;
  final host = u.host.toLowerCase();
  return u.hasPort && u.port != 443 ? 'https://$host:${u.port}' : 'https://$host';
}

/// Whether [url] may carry the app's traffic: the project's own host
/// ([direct]'s) or a host under [backendAllowedDomain]. Pure.
bool isAllowedBackend(String url, String direct) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  if (host == Uri.tryParse(direct)?.host.toLowerCase()) return true;
  return host == backendAllowedDomain || host.endsWith('.$backendAllowedDomain');
}

/// A DNS-over-HTTPS endpoint: an https URL with a path, no query. Pure.
String? normalizeDohUrl(String raw) {
  final s = raw.trim();
  final u = Uri.tryParse(s);
  if (u == null || u.scheme != 'https' || u.host.isEmpty || u.userInfo.isNotEmpty) return null;
  if (u.hasQuery || u.hasFragment) return null;
  return u.toString();
}

/// The addresses to try, in the admin's order ([BackendNetwork.order]):
/// the project's own, the admin's (only those [isAllowedBackend] passes)
/// and the built-in second address, each only where its level is on.
/// Duplicates dropped. Never empty: with nothing switched on that yields an
/// address, the project's own is tried, so a launch always has somewhere
/// to go. Pure.
List<String> backendCandidates(String direct, BackendNetwork network) {
  final out = <String>[];
  for (final level in network.order) {
    final urls = switch (level) {
      BackendRouteLevel.device => [direct],
      BackendRouteLevel.extra => network.backends,
      BackendRouteLevel.builtin => ['https://$backendFallbackHost'],
    };
    for (final u in urls) {
      if (isAllowedBackend(u, direct) && !out.contains(u)) out.add(u);
    }
  }
  return out.isEmpty ? [direct] : out;
}

/// The JSON-API query for [host]'s IPv4 addresses at [resolver]. Pure.
Uri dohQuery(String resolver, String host) {
  final r = Uri.parse(resolver);
  return r.replace(queryParameters: {...r.queryParameters, 'name': host, 'type': 'A'});
}

/// The IPv4 addresses in a DNS-over-HTTPS JSON answer
/// (`{"Status":0,"Answer":[{"type":1,"data":"104.18.1.1"},…]}`); empty for
/// an error status or no A records. CNAME steps are skipped. Pure.
List<String> parseDohAnswer(Object? json) {
  if (json is! Map || (json['Status'] ?? 0) != 0) return const [];
  final answers = json['Answer'];
  if (answers is! List) return const [];
  final out = <String>[];
  for (final a in answers) {
    if (a is! Map || a['type'] != 1) continue;
    final ip = '${a['data'] ?? ''}'.trim();
    if (_ipv4.hasMatch(ip) && !out.contains(ip)) out.add(ip);
  }
  return out;
}

final _ipv4 = RegExp(r'^((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(25[0-5]|2[0-4]\d|1?\d?\d)$');

/// How the app reaches the backend this launch.
class BackendChoice {
  const BackendChoice(this.url, {this.pinnedIp});

  /// The address requests go to.
  final String url;

  /// Set when the phone's DNS could not look [url]'s host up and a
  /// DNS-over-HTTPS resolver did: requests connect to this IP while still
  /// checking the certificate against the host's name.
  final String? pinnedIp;

  String get host => Uri.parse(url).host;

  @override
  bool operator ==(Object other) => other is BackendChoice && other.url == url && other.pinnedIp == pinnedIp;

  @override
  int get hashCode => Object.hash(url, pinnedIp);

  @override
  String toString() => pinnedIp == null ? url : '$url @ $pinnedIp';
}

/// Picks the address, given the [candidates] in order and what the lookups
/// found: the first the phone's own DNS resolves ([resolves]); failing all,
/// the first a DNS-over-HTTPS resolver found an address for ([dohIps]);
/// failing that too, the first candidate as it is. Pure.
BackendChoice chooseBackend(
  List<String> candidates, {
  required bool Function(String url) resolves,
  Map<String, List<String>> dohIps = const {},
}) {
  for (final c in candidates) {
    if (resolves(c)) return BackendChoice(c);
  }
  for (final c in candidates) {
    final ips = dohIps[c];
    if (ips != null && ips.isNotEmpty) return BackendChoice(c, pinnedIp: ips.first);
  }
  return BackendChoice(candidates.first);
}

/// The admin form's text for one list: one entry per line.
String networkListText(List<String> entries) => entries.join('\n');

/// One list from the admin form, and the first line it could not use (null
/// when every line is usable). Blank lines are skipped. Pure.
({List<String> entries, String? bad}) parseNetworkList(String text, String? Function(String) clean) {
  final out = <String>[];
  for (final line in text.split(RegExp(r'[\n,]'))) {
    if (line.trim().isEmpty) continue;
    final c = clean(line);
    if (c == null) return (entries: out, bad: line.trim());
    if (!out.contains(c)) out.add(c);
  }
  return (entries: out, bad: null);
}

/// The first problem with the admin's two lists and route order, or null.
/// [direct] is the project's own URL, for [isAllowedBackend]. Pure.
String? validateBackendNetwork(
  String backendsText,
  String dohText,
  String direct, {
  List<BackendRouteLevel> order = defaultBackendRouteOrder,
}) {
  final b = parseNetworkList(backendsText, normalizeBackendUrl);
  if (b.bad != null) return 'Not a backend address: ${b.bad} (use https://host, nothing after it)';
  for (final url in b.entries) {
    if (!isAllowedBackend(url, direct)) {
      return '$url is not allowed: backend addresses must be under $backendAllowedDomain';
    }
  }
  if (b.entries.length > backendNetworkMaxEntries) return 'At most $backendNetworkMaxEntries backend addresses';
  final d = parseNetworkList(dohText, normalizeDohUrl);
  if (d.bad != null) return 'Not a DNS-over-HTTPS address: ${d.bad} (use https://…, no query)';
  if (d.entries.length > backendNetworkMaxEntries) return 'At most $backendNetworkMaxEntries resolvers';
  if (order.isEmpty) return 'Switch on at least one route for the app to try at launch';
  if (order.length == 1 && order.single == BackendRouteLevel.extra && b.entries.isEmpty) {
    return 'Only "${BackendRouteLevel.extra.label}" is on, but none are listed: add one or switch on another route';
  }
  return null;
}

/// The `app_branding.network` value for the admin's two lists and route
/// order. Pure.
Map<String, dynamic> backendNetworkPatch(
  String backendsText,
  String dohText, {
  List<BackendRouteLevel> order = defaultBackendRouteOrder,
}) => BackendNetwork(
  backends: parseNetworkList(backendsText, normalizeBackendUrl).entries,
  dohResolvers: parseNetworkList(dohText, normalizeDohUrl).entries,
  order: order,
).toJson();

/// One row of the admin's Fallback order list: a level and whether it is on.
typedef BackendRouteRow = ({BackendRouteLevel level, bool on});

/// The rows the admin edits for a stored [order]: the levels that are on,
/// in order, then the ones that are off (in their default order). Pure.
List<BackendRouteRow> backendRouteRows(List<BackendRouteLevel> order) => [
  for (final l in order) (level: l, on: true),
  for (final l in defaultBackendRouteOrder)
    if (!order.contains(l)) (level: l, on: false),
];

/// The order saved from the admin's [rows]: the switched-on levels, top to
/// bottom. Pure.
List<BackendRouteLevel> backendRouteOrderOf(List<BackendRouteRow> rows) => [
  for (final r in rows)
    if (r.on) r.level,
];

/// [rows] with the row at [index] moved up ([by] -1) or down (+1); the same
/// rows when that would leave the list. Pure.
List<BackendRouteRow> moveBackendRouteRow(List<BackendRouteRow> rows, int index, int by) {
  final to = index + by;
  if (index < 0 || index >= rows.length || to < 0 || to >= rows.length) return rows;
  final out = [...rows];
  final r = out.removeAt(index);
  out.insert(to, r);
  return out;
}
