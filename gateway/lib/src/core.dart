// The GET.ride Gateway's rules, with no Flutter or Supabase in them: what a
// job is, how a phone number is shown in the log, how long to wait after a
// failure, and what a server refusal means to the person holding the phone.

/// An SMS the server handed this gateway to send (`sms_outbox`, claimed by
/// `gateway_claim_sms`).
class SmsJob {
  const SmsJob({required this.id, required this.channel, required this.to, required this.body, this.attempts = 1});

  final String id;

  /// `otp`, `marketing` or `support_message`.
  final String channel;
  final String to;
  final String body;

  /// How many times it has been claimed, this one included.
  final int attempts;

  /// Null for a row that is not a job this app can send.
  static SmsJob? fromRow(Map<String, dynamic> r) {
    final id = '${r['id'] ?? ''}';
    final to = '${r['to_phone'] ?? ''}'.trim();
    final body = '${r['body'] ?? ''}';
    if (id.isEmpty || to.isEmpty || body.isEmpty) return null;
    return SmsJob(
      id: id,
      channel: '${r['channel'] ?? ''}',
      to: to,
      body: body,
      attempts: (r['attempts'] as num?)?.toInt() ?? 1,
    );
  }
}

/// An SMS this phone received, waiting to be handed to the server. [id] is
/// the phone's own, so a message is acknowledged (and dropped from the
/// phone's queue) only once the server has it.
class IncomingSms {
  const IncomingSms({required this.id, required this.from, required this.body, required this.at});

  final String id;
  final String from;
  final String body;
  final DateTime at;

  static IncomingSms? fromMap(Map<Object?, Object?> m) {
    final id = '${m['id'] ?? ''}';
    final from = '${m['from'] ?? ''}'.trim();
    if (id.isEmpty || from.isEmpty) return null;
    final ms = m['at'];
    return IncomingSms(
      id: id,
      from: from,
      body: '${m['body'] ?? ''}',
      at: ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : DateTime.now(),
    );
  }
}

/// A SIM in the phone, as Android lists it.
class SimCard {
  const SimCard({required this.subscriptionId, required this.label, this.number, this.slot});

  final int subscriptionId;
  final String label;
  final String? number;
  final int? slot;

  String get title {
    final n = number?.trim() ?? '';
    final s = slot == null ? '' : 'SIM ${slot! + 1} · ';
    return n.isEmpty ? '$s$label' : '$s$label ($n)';
  }

  static SimCard? fromMap(Map<Object?, Object?> m) {
    final id = m['id'];
    if (id is! num) return null;
    final number = '${m['number'] ?? ''}'.trim();
    return SimCard(
      subscriptionId: id.toInt(),
      label: '${m['label'] ?? 'SIM'}'.trim().isEmpty ? 'SIM' : '${m['label']}'.trim(),
      number: number.isEmpty ? null : number,
      slot: (m['slot'] as num?)?.toInt(),
    );
  }
}

/// How a send went on the phone's radio.
class SmsSendResult {
  const SmsSendResult.sent() : ok = true, error = null;
  const SmsSendResult.failed(this.error) : ok = false;

  final bool ok;
  final String? error;
}

/// A phone number as the log shows it: the country code and the last three
/// digits, the rest hidden (`+6012*****789`). The log is on a phone that may
/// sit on a desk; it should not be a list of everyone's numbers.
String maskPhone(String phone) {
  final p = phone.trim();
  final digits = p.replaceAll(RegExp(r'\D'), '');
  if (digits.length <= 5) return p;
  final head = p.startsWith('+') ? '+${digits.substring(0, 4)}' : digits.substring(0, 3);
  final tail = digits.substring(digits.length - 3);
  final hidden = digits.length - (head.replaceAll('+', '').length) - 3;
  return '$head${'*' * (hidden < 0 ? 0 : hidden)}$tail';
}

/// What the log says about a job: its channel and masked number, never the
/// text of a sign-in code.
String jobSummary(SmsJob j) {
  final what = switch (j.channel) {
    'otp' => 'Sign-in code',
    'marketing' => 'Marketing',
    'support_message' => 'Support message',
    _ => 'SMS',
  };
  return '$what to ${maskPhone(j.to)}';
}

/// How long to wait before talking to the server again after [failures]
/// failures in a row: 5 s, doubling, at most two minutes.
Duration backoffAfter(int failures) {
  if (failures <= 0) return Duration.zero;
  final s = 5 * (1 << (failures - 1).clamp(0, 10));
  return Duration(seconds: s > 120 ? 120 : s);
}

/// Why the server refused, in words for the person holding the phone; null
/// when it is not a refusal (a network failure, worth retrying).
String? gatewayRefusal(Object error) {
  final s = '$error';
  if (s.contains('GATEWAY_NEEDS_ADMIN')) {
    return 'This account is not an admin. Sign in with an admin account to run the gateway.';
  }
  if (s.contains('NOT_A_GATEWAY')) {
    return 'The server does not know this phone as a gateway. Turn the gateway off and on again.';
  }
  if (s.contains('GATEWAY_KEY_INVALID')) {
    return 'This phone is no longer paired. Unpair it, then pair it again from Admin → SMS / WhatsApp.';
  }
  return null;
}

/// A short, readable form of a failure for the log.
String describeError(Object error) {
  final s = '$error'.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.contains('SocketException') || s.contains('ClientException') || s.contains('Failed host lookup')) {
    return 'No connection to the server.';
  }
  return s.length > 160 ? '${s.substring(0, 157)}...' : s;
}

enum GatewayLogKind { sent, failed, received, info, error, proxy }

class GatewayLogEntry {
  const GatewayLogEntry(this.at, this.kind, this.text);

  final DateTime at;
  final GatewayLogKind kind;
  final String text;
}

/// The newest [capacity] entries, newest first.
class GatewayLog {
  GatewayLog({this.capacity = 200});

  final int capacity;
  final List<GatewayLogEntry> _entries = [];

  List<GatewayLogEntry> get entries => List.unmodifiable(_entries);

  void add(GatewayLogEntry e) {
    _entries.insert(0, e);
    if (_entries.length > capacity) _entries.removeRange(capacity, _entries.length);
  }
}

/// What this session has done.
class GatewayStats {
  int sent = 0;
  int failed = 0;
  int received = 0;

  /// Requests performed for a test session over the shared internet.
  int relayed = 0;
}

/// A pairing code as typed: letters and digits only, in capitals
/// (`abcd-2345` → `ABCD2345`). Pure.
String normalizePairCode(String typed) => typed.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// Whether [typed] is a whole pairing code (8 characters, Admin → SMS /
/// WhatsApp → Pair a gateway phone).
bool isPairCode(String typed) => normalizePairCode(typed).length == 8;

/// What `gateway_pair` (migration 0190) answered: the device key to keep,
/// or the sentence to show. Pure.
({String? key, String? error}) pairResult(Object? body) {
  final map = body is Map ? body : const {};
  final key = map['key'];
  if (key is String && key.length >= 32) return (key: key, error: null);
  final hint = map['hint'];
  if (hint is String && hint.trim().isNotEmpty) return (key: null, error: hint.trim());
  return (key: null, error: 'Pairing did not answer properly. Please try again.');
}

/// The shared internet (migration 0223, ProxyClient.kt): whether the relay
/// at proxy.getride.my has this phone.
enum ProxyState { off, connecting, connected, reconnecting, error }

/// The state an event from the phone's side moves the shared internet to;
/// null for an event that is not a change of state (a request relayed,
/// mobile data coming or going). Pure.
ProxyState? proxyStateFrom(Map<String, Object?> event) => switch (event['state']) {
  'off' => ProxyState.off,
  'connecting' => ProxyState.connecting,
  'connected' => ProxyState.connected,
  'reconnecting' => ProxyState.reconnecting,
  'error' => ProxyState.error,
  _ => null,
};

/// What the log says about an event from the phone's side, or null for one
/// not worth a line. Names the host a request went to, never its path or
/// what came back. Pure.
String? proxyLogLine(Map<String, Object?> event) {
  final reason = event['reason'];
  switch (event['state']) {
    case 'connected':
      return 'Internet shared: the relay has this phone.';
    case 'reconnecting':
      return 'Internet sharing: no connection to the relay${reason == null ? '' : ' ($reason)'}. Retrying.';
    case 'error':
      return 'Internet sharing stopped: ${reason ?? 'refused'}';
    case 'off':
      return 'Internet sharing stopped.';
    case 'request':
      final host = event['host'] ?? '?';
      final error = event['error'];
      if (error != null) return 'Request to $host failed: $error';
      final status = event['status'];
      return 'Relayed a request to $host${status == null ? '' : ' ($status)'}';
    case 'mobile':
      return event['available'] == true
          ? 'Mobile data is up: shared requests use it.'
          : 'Mobile data is down: shared requests take the phone\'s default route.';
    default:
      return null;
  }
}
