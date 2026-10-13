import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/backend_network.dart';

/// Whether [host] resolves within [timeout].
Future<bool> hostResolves(String host, Duration timeout) async {
  try {
    final found = await InternetAddress.lookup(host).timeout(timeout);
    return found.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// [host]'s IPv4 addresses from the first of [resolvers] that answers with
/// any (DNS-over-HTTPS, JSON API); empty when none does within [timeout]
/// each. The resolvers are addressed by IP, so asking them needs no DNS.
Future<List<String>> dohLookup(String host, List<String> resolvers, Duration timeout) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = ((_) => 'DIRECT');
  try {
    for (final r in resolvers) {
      try {
        final req = await client.getUrl(dohQuery(r, host)).timeout(timeout);
        req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
        final res = await req.close().timeout(timeout);
        if (res.statusCode != 200) {
          await res.drain<void>();
          continue;
        }
        final body = await res.transform(utf8.decoder).join().timeout(timeout);
        final ips = parseDohAnswer(jsonDecode(body));
        if (ips.isNotEmpty) return ips;
      } catch (_) {
        // The next resolver.
      }
    }
    return const [];
  } finally {
    client.close(force: true);
  }
}

/// An HTTP client whose connections to [host] go to [ip] instead of
/// wherever the phone's DNS would send them, still presenting [host] for
/// TLS (SNI) and checking the certificate against it, so a wrong address
/// fails rather than talks to someone else. Other hosts connect normally.
///
/// [context] is the trust store (the platform's when null; tests pass their own).
http.Client pinnedHttpClient(String host, String ip, {SecurityContext? context}) {
  final inner = HttpClient(context: context)
    // The connection is made to a known address: never through a proxy
    // (one from the environment would otherwise be tunnelled over it).
    ..findProxy = ((_) => 'DIRECT');
  inner.connectionFactory = (uri, proxyHost, proxyPort) {
    if (uri.host != host || uri.scheme != 'https') {
      return Socket.startConnect(uri.host, uri.port);
    }
    final port = uri.hasPort ? uri.port : 443;
    return Socket.startConnect(ip, port).then(
      (task) => ConnectionTask.fromSocket(
        task.socket.then((raw) => SecureSocket.secure(raw, host: host, context: context)),
        task.cancel,
      ),
    );
  };
  return IOClient(inner);
}
