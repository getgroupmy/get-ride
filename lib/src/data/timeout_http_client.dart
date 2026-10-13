import 'dart:async';

import 'package:http/http.dart' as http;

import '../core/server_timeout.dart';

/// The HTTP client every Supabase request goes through (see `main.dart`):
/// [requestTimeoutFor] limits how long the response headers may take, and a
/// request past it fails with a [ServerTimeout] rather than waiting on.
///
/// Only the wait for the answer is limited, not the reading of its body, so
/// a large download that has started is not cut off. On the web the browser
/// request is left to finish on its own; its answer is simply not waited for.
class TimeoutHttpClient extends http.BaseClient {
  TimeoutHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final t = requestTimeoutFor(request.url);
    return _inner
        .send(request)
        .timeout(
          t.limit,
          onTimeout: () => throw ServerTimeout(limit: t.limit, unconfirmed: t.unconfirmed),
        );
  }

  @override
  void close() => _inner.close();
}
