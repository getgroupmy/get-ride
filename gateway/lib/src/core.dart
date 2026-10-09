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
  if (s.contains('NOT_SIGNED_IN') || s.contains('JWT expired') || s.contains('invalid JWT')) {
    return 'You were signed out. Sign in again.';
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

enum GatewayLogKind { sent, failed, received, info, error }

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
}

/// Sign-in phone number from a dial code and a local number, dropping a
/// trunk `0` (`+60` + `012 345 6789` → `+60123456789`), as the GET.ride app
/// signs in.
String composeSignInPhone(String dialCode, String local) {
  var l = local.replaceAll(RegExp(r'\D'), '');
  if (l.startsWith('0')) l = l.substring(1);
  final d = dialCode.replaceAll(RegExp(r'\D'), '');
  return d.isEmpty || l.isEmpty ? '' : '+$d$l';
}

/// The GET.ride app's PIN-derived password (`derivePinPassword`), so this
/// app signs in to the same account with the same PIN.
String pinPassword(String pin) => 'teksi-pin-v1-$pin';

bool isValidPin(String pin) => RegExp(r'^\d{6}$').hasMatch(pin);
