/// The launch connection check behind Admin → Display Settings → Connection
/// Status Popups (Expo `AuthContext` health ping + `ConnectionStatusModal`).
/// Pure: what the check found, and which popup (if any) that earns.
library;

import 'dart:async';

class ConnectionCheck {
  const ConnectionCheck({
    required this.reachable,
    required this.url,
    required this.hasKey,
    this.httpStatus,
    this.errorName,
    this.errorMessage,
    this.durationMs,
  });

  final bool reachable;
  final String url;
  final bool hasKey;
  final int? httpStatus;
  final String? errorName;
  final String? errorMessage;
  final int? durationMs;

  bool get hasUrl => url.trim().isNotEmpty;

  /// What went wrong, in one line.
  String get error => errorMessage ?? (httpStatus != null ? 'HTTP $httpStatus' : 'Unable to reach the server');

  /// What went wrong, in words for the user; [error] stays under "Show details".
  String get summary {
    if (errorName == connectionTimedOut) return 'GET.ride took too long to answer. Try again in a moment.';
    if (httpStatus != null) return 'GET.ride answered with an error. Try again in a moment.';
    return "Couldn't reach GET.ride. Check your connection and try again.";
  }

  /// The rows "Show details" reveals.
  List<(String, String)> get details => [
    ('URL host', Uri.tryParse(url)?.host ?? '—'),
    ('URL set', hasUrl ? 'Yes' : 'No'),
    ('Anon key set', hasKey ? 'Yes' : 'No'),
    ('HTTP status', httpStatus?.toString() ?? '—'),
    ('Error', errorMessage ?? (httpStatus != null ? 'HTTP $httpStatus' : '—')),
    ('Error name', errorName ?? '—'),
    ('Duration', durationMs == null ? '—' : '$durationMs ms'),
  ];
}

/// [ConnectionCheck.errorName] for the failures people can recognise; any
/// other error is named only in debug builds (a release build's type names
/// are minified noise).
const connectionNetworkError = 'Network error';
const connectionTimedOut = 'Timed out';

String connectionErrorName(Object e, {required bool release}) {
  if (e is TimeoutException) return connectionTimedOut;
  final s = '$e';
  if (s.contains('ClientException') || s.contains('SocketException') || s.contains('Failed to fetch')) {
    return connectionNetworkError;
  }
  return release ? 'Error' : e.runtimeType.toString();
}

enum ConnectionPopup { connected, failed }

/// Whether the launch check is worth making: only when either popup is on
/// (the ping is otherwise a request every launch for nothing). Pure.
bool connectionCheckWanted({required bool connectedOn, required bool failedOn}) => connectedOn || failedOn;

/// The popup [check] earns at launch, or null when the admin switched that
/// one off.
ConnectionPopup? connectionPopupFor(ConnectionCheck check, {required bool connectedOn, required bool failedOn}) {
  if (check.reachable) return connectedOn ? ConnectionPopup.connected : null;
  return failedOn ? ConnectionPopup.failed : null;
}
