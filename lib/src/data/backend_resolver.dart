import '../core/backend_network.dart';
import '../core/backend_route.dart';
import 'backend_lookup.dart';

/// How to reach the backend this launch (see core/backend_network.dart):
/// the first of the routes the admin switched on, in their order (the
/// project's own address, the admin's addresses, the built-in second one),
/// that the phone's DNS resolves; failing every one,
/// the first a DNS-over-HTTPS resolver finds an address for. Lookups stop
/// at the first that works, so a normal launch costs one lookup the HTTP
/// client would have made anyway; the resolvers are only asked when the
/// phone's own DNS has failed for every address.
Future<BackendChoice> pickBackend(String direct, BackendNetwork network) async {
  final candidates = backendCandidates(direct, network);
  String? resolved;
  for (final c in candidates) {
    final host = Uri.tryParse(c)?.host ?? '';
    if (host.isNotEmpty && await hostResolves(host, backendLookupTimeout)) {
      resolved = c;
      break;
    }
  }
  if (resolved != null) return BackendChoice(resolved);
  final dohIps = <String, List<String>>{};
  for (final c in candidates) {
    final ips = await dohLookup(Uri.parse(c).host, network.resolvers, backendLookupTimeout);
    if (ips.isNotEmpty) {
      dohIps[c] = ips;
      break;
    }
  }
  return chooseBackend(candidates, resolves: (_) => false, dohIps: dohIps);
}
