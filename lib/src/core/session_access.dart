// Admin → SMS / WhatsApp → Session access (migration 0226): a key a full
// admin gives a test session (a Claude Code cloud session, a CI job) so it
// can take part in a live test without a phone of its own. Each key is
// scoped to one test phone number and to what the session may do. Pure.

/// What a session key lets its holder do.
enum SessionScope {
  sms(
    'sms',
    'Text the test number',
    'Send support or marketing SMS to the test number through the gateway phone, and read what went out '
        'and came in for it. Never sign-in codes.',
  ),
  codes(
    'codes',
    'Read sign-in codes',
    'Read the sign-in codes sent to the test number in clear, so the session can sign the test account in by SMS.',
  ),
  proxy(
    'proxy',
    "Use a gateway phone's internet",
    "Reach the internet through a gateway phone's mobile data (via proxy.getride.my), so requests leave from a real "
        'SIM, not a data centre.',
  );

  const SessionScope(this.id, this.label, this.description);
  final String id;
  final String label;
  final String description;

  static SessionScope? fromId(Object? id) => values.where((s) => s.id == id).firstOrNull;
}

/// A session key as the card lists it (`admin_session_keys`); never the key.
class SessionKey {
  const SessionKey({
    required this.id,
    required this.label,
    required this.testPhone,
    required this.scopes,
    required this.createdAt,
    required this.expiresAt,
    this.proxyDevice,
    this.proxyLabel,
    this.revokedAt,
    this.lastUsedAt,
    this.uses = 0,
  });

  final String id;
  final String label;
  final String testPhone;
  final List<SessionScope> scopes;
  final String? proxyDevice;
  final String? proxyLabel;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? revokedAt;
  final DateTime? lastUsedAt;
  final int uses;

  bool get removed => revokedAt != null;
  bool expiredAt(DateTime now) => !now.isBefore(expiresAt);
  bool activeAt(DateTime now) => !removed && !expiredAt(now);

  static SessionKey? fromRow(Map<String, dynamic> r) {
    final id = '${r['id'] ?? ''}';
    final created = DateTime.tryParse('${r['created_at'] ?? ''}');
    final expires = DateTime.tryParse('${r['expires_at'] ?? ''}');
    if (id.isEmpty || created == null || expires == null) return null;
    return SessionKey(
      id: id,
      label: '${r['label'] ?? ''}',
      testPhone: '${r['test_phone'] ?? ''}',
      scopes: [
        if (r['scopes'] is List)
          for (final s in r['scopes'] as List) ?SessionScope.fromId(s),
      ],
      proxyDevice: r['proxy_device'] as String?,
      proxyLabel: r['proxy_label'] as String?,
      createdAt: created,
      expiresAt: expires,
      revokedAt: DateTime.tryParse('${r['revoked_at'] ?? ''}'),
      lastUsedAt: DateTime.tryParse('${r['last_used_at'] ?? ''}'),
      uses: (r['uses'] as num?)?.toInt() ?? 0,
    );
  }
}

/// "Active", "Removed" or "Expired".
String sessionKeyStatus(SessionKey k, DateTime now) {
  if (k.removed) return 'Removed';
  if (k.expiredAt(now)) return 'Expired';
  return 'Active';
}

/// How long a new key lasts: the choices offered, in hours (a day by default).
const sessionKeyHoursChoices = [1, 8, 24, 72, 168, 720];
const sessionKeyDefaultHours = 24;

/// "8 h", "1 day", "30 days".
String sessionKeyHoursLabel(int hours) {
  if (hours < 24) return '$hours h';
  final days = hours ~/ 24;
  return days == 1 ? '1 day' : '$days days';
}

/// "Used 12× · last 5 min ago", "Never used".
String sessionKeyUseLabel(SessionKey k, DateTime now) {
  final last = k.lastUsedAt;
  if (last == null || k.uses == 0) return 'Never used';
  final ago = now.difference(last);
  final when = ago.inMinutes < 1
      ? 'just now'
      : ago.inMinutes < 60
      ? '${ago.inMinutes} min ago'
      : ago.inHours < 48
      ? '${ago.inHours} h ago'
      : '${ago.inDays} d ago';
  return 'Used ${k.uses}× · last $when';
}

/// A key's row subtitle: the test phone, what it may do, the gateway, when
/// it ends (or its status) and its use, with the parts it lacks left out
/// so no " · · " is left behind. [ends] formats the end time.
String sessionKeySubtitle(SessionKey k, DateTime now, String Function(DateTime) ends) => [
      k.testPhone.trim(),
      k.scopes.map((s) => s.label).join(', '),
      if (k.proxyLabel != null) 'Internet via ${k.proxyLabel}',
      k.activeAt(now) ? 'Ends ${ends(k.expiresAt.toLocal())}' : sessionKeyStatus(k, now),
      sessionKeyUseLabel(k, now),
    ].where((p) => p.trim().isNotEmpty).join(' · ');

/// The test number as the server wants it (`+60123456789`), or null.
String? normalizeSessionPhone(String raw) {
  final t = raw.replaceAll(RegExp(r'[\s()-]'), '');
  return RegExp(r'^\+[1-9][0-9]{6,14}$').hasMatch(t) ? t : null;
}

/// What is wrong with a new key as drafted, or null when it can be added.
String? sessionKeyProblem({
  required String label,
  required String phone,
  required Set<SessionScope> scopes,
  String? proxyDevice,
}) {
  if (label.trim().isEmpty) return 'Give the session a name, e.g. "Claude cloud session".';
  if (normalizeSessionPhone(phone) == null) {
    return 'Enter the test phone number with its country code, e.g. +60123456789.';
  }
  if (scopes.isEmpty) return 'Tick at least one thing the session may do.';
  if (scopes.contains(SessionScope.proxy) && (proxyDevice == null || proxyDevice.isEmpty)) {
    return 'Pick the gateway phone whose internet the session uses.';
  }
  return null;
}

/// The environment secret a cloud session reads the key from.
const sessionKeyEnvName = 'GETRIDE_SESSION_KEY';
