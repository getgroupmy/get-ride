/// Pure half of Admin → Security & integrations → Claude Code access
/// (migration 0228). Rules live in `claude_access_rules`
/// (`kind in ('session','ip')`, `unique (kind, value)`): the Claude cloud
/// sessions and office IPs that use the Supabase MCP tools without a
/// permission prompt. `.claude/hooks/supabase-ip-gate.sh` reads them.
library;

enum ClaudeRuleKind {
  session,
  ip;

  static ClaudeRuleKind? parse(Object? v) => switch ('$v') {
        'session' => ClaudeRuleKind.session,
        'ip' => ClaudeRuleKind.ip,
        _ => null,
      };
}

class ClaudeAccessRule {
  const ClaudeAccessRule({
    required this.id,
    required this.kind,
    required this.value,
    this.label,
    this.enabled = true,
    this.createdAt,
    this.updatedAt,
  });

  factory ClaudeAccessRule.fromRow(Map<String, dynamic> r) => ClaudeAccessRule(
        id: '${r['id']}',
        kind: ClaudeRuleKind.parse(r['kind']) ?? ClaudeRuleKind.session,
        value: '${r['value'] ?? ''}',
        label: r['label'] as String?,
        enabled: r['enabled'] != false,
        createdAt: r['created_at'] as String?,
        updatedAt: r['updated_at'] as String?,
      );

  final String id;
  final ClaudeRuleKind kind;
  final String value;
  final String? label;
  final bool enabled;
  final String? createdAt;
  final String? updatedAt;

  bool get isSession => kind == ClaudeRuleKind.session;

  /// The link a session id came from.
  String get sessionUrl => 'https://claude.ai/code/session_$value';
}

/// The office IP migration 0228 seeds; the hook's built-in fallback too.
const defaultOfficeIp = '202.188.231.237';

final _sessionId = RegExp(r'^[0-9A-Za-z]{20,32}$');

/// The bare id of a Claude cloud session from whatever was pasted: the
/// `claude.ai/code/session_<id>` link, `session_<id>`, `cse_<id>` or the id
/// itself. Null when it is none of those.
String? normalizeSessionId(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  s = s.split('?').first.split('#').first;
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  s = s.split('/').last;
  for (final prefix in const ['session_', 'cse_']) {
    if (s.startsWith(prefix)) s = s.substring(prefix.length);
  }
  return _sessionId.hasMatch(s) ? s : null;
}

final _ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
final _ipv6Chars = RegExp(r'^[0-9a-fA-F:]+$');

/// A plausible public address: four octets 0–255, or hex groups with colons.
bool isValidIp(String s) {
  final t = s.trim();
  if (t.isEmpty || t.length > 45) return false;
  final v4 = _ipv4.firstMatch(t);
  if (v4 != null) {
    for (var i = 1; i <= 4; i++) {
      if (int.parse(v4.group(i)!) > 255) return false;
    }
    return true;
  }
  return t.contains(':') && _ipv6Chars.hasMatch(t) && !t.contains(':::');
}

/// Row written by add/edit (value normalised, label trimmed, blank → null),
/// or the message to show instead.
({Map<String, dynamic>? row, String? error}) claudeRuleRow({
  required ClaudeRuleKind kind,
  required String value,
  String? label,
}) {
  final String? v;
  switch (kind) {
    case ClaudeRuleKind.session:
      v = normalizeSessionId(value);
      if (v == null) return (row: null, error: 'Paste the session link (claude.ai/code/session_…) or its id.');
    case ClaudeRuleKind.ip:
      v = value.trim();
      if (!isValidIp(v)) return (row: null, error: 'Enter a public IP address, e.g. $defaultOfficeIp.');
  }
  final l = label?.trim() ?? '';
  return (row: {'kind': kind.name, 'value': v, 'label': l.isEmpty ? null : l}, error: null);
}

/// Whether [ip] is an enabled office IP: from there the page may be changed
/// (the database checks the same on every write).
bool isOfficeIp(String? ip, Iterable<ClaudeAccessRule> rules) =>
    ip != null && ip.isNotEmpty && rules.any((r) => r.kind == ClaudeRuleKind.ip && r.enabled && r.value == ip);

/// [kind] is null for both kinds.
List<ClaudeAccessRule> filterClaudeRules(List<ClaudeAccessRule> rules, {String query = '', ClaudeRuleKind? kind}) {
  final q = query.trim().toLowerCase();
  return rules.where((r) {
    if (kind != null && r.kind != kind) return false;
    if (q.isEmpty) return true;
    return '${r.value} ${r.label ?? ''}'.toLowerCase().contains(q);
  }).toList();
}

({int sessions, int ips}) countClaudeRules(Iterable<ClaudeAccessRule> rules) {
  var sessions = 0;
  var ips = 0;
  for (final r in rules) {
    if (r.isSession) {
      sessions++;
    } else {
      ips++;
    }
  }
  return (sessions: sessions, ips: ips);
}

String claudeRuleSubtitle(ClaudeAccessRule r) {
  final l = r.label?.trim() ?? '';
  final what = r.isSession
      ? 'Claude session · Supabase tools run without a prompt'
      : 'Office IP · no prompt there, and this page may be changed from there';
  final base = l.isEmpty ? what : l;
  return r.enabled ? base : '$base · disabled';
}

/// A message for the errors this page's writes can run into; null for any
/// other error (shown as it is).
String? friendlyClaudeRuleError(Object e) {
  final m = '$e';
  if (m.contains('claude_access_last_office_ip')) {
    return 'Add another office IP before removing or disabling this one.';
  }
  if (m.contains('duplicate key') || m.contains('claude_access_rules_kind_value_key')) {
    return 'That entry is already on the list.';
  }
  if (m.contains('row-level security') || m.contains('42501') || m.contains('permission denied') || m.contains('PGRST116')) {
    return 'Only an admin with edit access, connected from an office IP, can change this list.';
  }
  return null;
}
