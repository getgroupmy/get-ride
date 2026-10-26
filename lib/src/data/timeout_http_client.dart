import 'dart:async';

import 'package:http/http.dart' as http;

import '../core/server_timeout.dart';

final _outcomes = StreamController<bool>.broadcast(sync: true);

/// Whether each request through [TimeoutHttpClient] reached the server
/// (true: any answer, even an error status) or not (false: no connection,
/// or no answer in time). The connection strip follows it (app_connection.dart).
Stream<bool> get httpOutcomes => _outcomes.stream;

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
        )
        .then(
          (r) {
            _outcomes.add(true);
            return r;
          },
          onError: (Object e, StackTrace st) {
            if (e is http.ClientException || e is ServerTimeout) _outcomes.add(false);
            Error.throwWithStackTrace(e, st);
          },
        );
  }

  @override
  void close() => _inner.close();
}
