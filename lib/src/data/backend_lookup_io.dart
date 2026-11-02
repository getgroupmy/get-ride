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

/// [host]'s addresses (A and AAAA) from the first of [resolvers] that
/// answers with any (DNS-over-HTTPS, JSON API); empty when none does within
/// [timeout] each. The resolvers are addressed by IP (v4 or v6), so asking
/// them needs no DNS; one this phone cannot reach just fails, and the next
/// is asked.
Future<List<String>> dohLookup(String host, List<String> resolvers, Duration timeout) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = ((_) => 'DIRECT');
  try {
    for (final r in resolvers) {
      final ips = <String>[];
      for (final type in const ['A', 'AAAA']) {
        try {
          final req = await client.getUrl(dohQuery(r, host, type: type)).timeout(timeout);
          req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
          final res = await req.close().timeout(timeout);
          if (res.statusCode != 200) {
            await res.drain<void>();
            continue;
          }
          final body = await res.transform(utf8.decoder).join().timeout(timeout);
          for (final ip in parseDohAnswer(jsonDecode(body))) {
            if (!ips.contains(ip)) ips.add(ip);
          }
        } catch (_) {
          // The other type, then the next resolver.
        }
      }
      if (ips.isNotEmpty) return ips;
    }
    return const [];
  } finally {
    client.close(force: true);
  }
}

/// Which address families this phone has a non-loopback address of.
Future<({bool v4, bool v6})> deviceAddressFamilies() async {
  try {
    final all = await NetworkInterface.list(type: InternetAddressType.any);
    final addrs = all.expand((n) => n.addresses).where((a) => !a.isLoopback && !a.isLinkLocal);
    return (
      v4: addrs.any((a) => a.type == InternetAddressType.IPv4),
      v6: addrs.any((a) => a.type == InternetAddressType.IPv6),
    );
  } catch (_) {
    return (v4: false, v6: false);
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
