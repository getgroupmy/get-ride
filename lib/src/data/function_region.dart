// Edge functions that talk to the database several times per call are run
// next to it (PERF-71). Left to themselves they run wherever the request
// lands, and each of their 3-8 database calls then crosses to Seoul and back
// (0.25-0.55 s apiece).
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';

/// The database's region: where [dbPinnedFunctions] are asked to run.
const functionDbRegion = 'ap-northeast-2';

/// The functions pinned to [functionDbRegion]: the ones that chain database
/// calls. Functions that mostly call third parties elsewhere (push, TURN,
/// document AI, releases) are left to run near the caller.
const dbPinnedFunctions = {'geo', 'pin-login', 'ip-lookup', 'ai-route-proxy'};

/// The query parameter that pins [name] (Supabase reads it as well as the
/// `x-region` header); empty for a function that is not pinned. Sent on
/// every platform: a backend route that does not forward it (the admin's
/// own addresses, the DNS-over-HTTPS fallback) simply runs the function
/// where it would have anyway.
Map<String, String> functionRegionQuery(String name) =>
    dbPinnedFunctions.contains(name) ? const {'forceFunctionRegion': functionDbRegion} : const {};

/// The `x-region` header that pins [name]; empty for a function that is not
/// pinned, and on the web, where a header the function's CORS answer does
/// not list would make the browser refuse the call (the query parameter
/// alone pins it there).
Map<String, String> functionRegionHeaders(String name, {bool isWeb = kIsWeb}) =>
    !isWeb && dbPinnedFunctions.contains(name) ? const {'x-region': functionDbRegion} : const {};

extension PinnedFunctions on FunctionsClient {
  /// [FunctionsClient.invoke], run in the database's region when [name] is
  /// one of [dbPinnedFunctions].
  Future<FunctionResponse> invokeNearDb(
    String name, {
    Map<String, String>? headers,
    Object? body,
    Map<String, dynamic>? queryParameters,
    HttpMethod method = HttpMethod.post,
    bool isWeb = kIsWeb,
  }) {
    final region = functionRegionQuery(name);
    final pin = functionRegionHeaders(name, isWeb: isWeb);
    return invoke(
      name,
      headers: headers == null && pin.isEmpty ? null : {...?headers, ...pin},
      body: body,
      queryParameters: queryParameters == null && region.isEmpty ? null : {...?queryParameters, ...region},
      method: method,
    );
  }
}
