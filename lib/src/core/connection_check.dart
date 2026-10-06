/// The launch connection check behind Admin → Display Settings → Connection
/// Status Popups (Expo `AuthContext` health ping + `ConnectionStatusModal`).
/// Pure: what the check found, and which popup (if any) that earns.
library;

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

  /// The rows "Show details" reveals.
  List<(String, String)> get details => [
    ('URL host', Uri.tryParse(url)?.host ?? '—'),
    ('URL set', hasUrl ? 'Yes' : 'No'),
    ('Anon key set', hasKey ? 'Yes' : 'No'),
    ('HTTP status', httpStatus?.toString() ?? '—'),
    ('Error name', errorName ?? '—'),
    ('Duration', durationMs == null ? '—' : '$durationMs ms'),
  ];
}

enum ConnectionPopup { connected, failed }

/// The popup [check] earns at launch, or null when the admin switched that
/// one off.
ConnectionPopup? connectionPopupFor(ConnectionCheck check, {required bool connectedOn, required bool failedOn}) {
  if (check.reachable) return connectedOn ? ConnectionPopup.connected : null;
  return failedOn ? ConnectionPopup.failed : null;
}
