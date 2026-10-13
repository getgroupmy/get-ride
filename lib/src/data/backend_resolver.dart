import '../core/backend_route.dart';
import 'backend_lookup.dart';

/// The backend address to launch against: [direct] unless its host does
/// not resolve here and the second address does (chooseBackendUrl). The
/// second lookup only happens when the first fails, so a normal launch
/// costs one lookup the HTTP client would have made anyway.
Future<String> pickBackendUrl(String direct) async {
  final host = Uri.tryParse(direct)?.host ?? '';
  if (host.isEmpty || await hostResolves(host, backendLookupTimeout)) return direct;
  final fallback = await hostResolves(backendFallbackHost, backendLookupTimeout);
  return chooseBackendUrl(direct, directResolves: false, fallbackResolves: fallback);
}
