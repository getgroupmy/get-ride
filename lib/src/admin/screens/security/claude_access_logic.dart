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

/// The bytes of an IPv4 (4) or IPv6 (16) address, or null when [s] is
/// neither. IPv6 may use `::` and may end in a dotted IPv4.
List<int>? parseIpBytes(String s) {
  final t = s.trim();
  if (t.isEmpty || t.length > 45) return null;
  if (!t.contains(':')) return _parseIpv4(t);
  final zone = t.indexOf('%');
  final body = zone < 0 ? t : t.substring(0, zone);
  if (body.contains(':::')) return null;
  final halves = body.split('::');
  if (halves.length > 2) return null;
  List<int>? groups(String part) {
    if (part.isEmpty) return <int>[];
    final out = <int>[];
    final items = part.split(':');
    for (var i = 0; i < items.length; i++) {
      final g = items[i];
      if (i == items.length - 1 && g.contains('.')) {
        final v4 = _parseIpv4(g);
        if (v4 == null) return null;
        out.addAll([(v4[0] << 8) | v4[1], (v4[2] << 8) | v4[3]]);
        continue;
      }
      if (g.isEmpty || g.length > 4 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(g)) return null;
      out.add(int.parse(g, radix: 16));
    }
    return out;
  }
  final head = groups(halves[0]);
  final tail = halves.length == 2 ? groups(halves[1]) : <int>[];
  if (head == null || tail == null) return null;
  final missing = 8 - head.length - tail.length;
  if (halves.length == 2 ? missing < 1 : missing != 0) return null;
  final all = [...head, ...List.filled(missing, 0), ...tail];
  return [for (final g in all) ...[g >> 8, g & 0xff]];
}

List<int>? _parseIpv4(String t) {
  final parts = t.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    if (p.isEmpty || p.length > 3 || !RegExp(r'^[0-9]+$').hasMatch(p)) return null;
    final n = int.parse(p);
    if (n > 255) return null;
    out.add(n);
  }
  return out;
}

/// An address, or a network in CIDR form (`198.51.100.0/24`,
/// `2001:db8::/64`): its bytes and prefix length. Null when it is neither.
({List<int> bytes, int prefix})? parseIpOrNetwork(String s) {
  final t = s.trim();
  final slash = t.indexOf('/');
  final bytes = parseIpBytes(slash < 0 ? t : t.substring(0, slash));
  if (bytes == null) return null;
  final max = bytes.length * 8;
  if (slash < 0) return (bytes: bytes, prefix: max);
  final p = t.substring(slash + 1);
  if (p.isEmpty || p.length > 3 || !RegExp(r'^[0-9]+$').hasMatch(p)) return null;
  final prefix = int.parse(p);
  if (prefix > max) return null;
  return (bytes: bytes, prefix: prefix);
}

/// The widest IPv4 network an office rule may name (migration 0233).
const minIpv4Prefix = 24;

/// The widest IPv6 network an office rule may name (migration 0233).
const minIpv6Prefix = 48;

/// Inside the IPv4-mapped range (`::ffff:0:0/96`) an IPv6 network counts as
/// IPv4: /24 there is /120.
const minMappedPrefix = 96 + minIpv4Prefix;

const _mappedRange = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff];

/// Why [s] can not be an office rule, or null when it can: a single address,
/// an IPv4 network of /24 or narrower, or an IPv6 network of /48 or narrower
/// (/120 inside the IPv4-mapped range). The database checks the same
/// (`claude_access_ip_rule_ok`, migration 0233).
String? ipRuleProblem(String s) {
  final r = parseIpOrNetwork(s);
  if (r == null) return 'Enter a public address or network, e.g. $defaultOfficeIp or 2001:db8::/64.';
  if (r.bytes.length == 4) {
    return r.prefix < minIpv4Prefix
        ? 'Too wide: an IPv4 office network can be /$minIpv4Prefix at the widest (256 addresses).'
        : null;
  }
  if (r.prefix < minIpv6Prefix) return 'Too wide: an IPv6 office network can be /$minIpv6Prefix at the widest.';
  if (r.prefix < minMappedPrefix && _overlapsMapped(r.bytes, r.prefix)) {
    return 'Too wide: inside ::ffff:0:0/96 (IPv4-mapped) a network can be /$minMappedPrefix at the widest.';
  }
  return null;
}

/// Whether the IPv6 network [bytes]/[prefix] and `::ffff:0:0/96` overlap: their
/// first min(prefix, 96) bits agree.
bool _overlapsMapped(List<int> bytes, int prefix) {
  var bits = prefix < 96 ? prefix : 96;
  for (var i = 0; bits > 0; i++) {
    final take = bits >= 8 ? 8 : bits;
    final mask = (0xff << (8 - take)) & 0xff;
    if ((bytes[i] & mask) != (_mappedRange[i] & mask)) return false;
    bits -= take;
  }
  return true;
}

/// A public address, or a network narrow enough for an office rule.
bool isValidIp(String s) => ipRuleProblem(s) == null;

/// Whether [ip] is [rule] itself or inside the network [rule] names. Never
/// true across families (an IPv6 address is in no IPv4 network).
bool ipInRule(String ip, String rule) {
  final a = parseIpBytes(ip);
  final r = parseIpOrNetwork(rule);
  if (a == null || r == null || a.length != r.bytes.length) return false;
  var bits = r.prefix;
  for (var i = 0; i < a.length && bits > 0; i++) {
    final take = bits >= 8 ? 8 : bits;
    final mask = (0xff << (8 - take)) & 0xff;
    if ((a[i] & mask) != (r.bytes[i] & mask)) return false;
    bits -= take;
  }
  return true;
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
      final problem = ipRuleProblem(v);
      if (problem != null) return (row: null, error: problem);
  }
  final l = label?.trim() ?? '';
  return (row: {'kind': kind.name, 'value': v, 'label': l.isEmpty ? null : l}, error: null);
}

/// Whether [ip] is inside an enabled office rule: from there the page may be
/// changed (the database checks the same on every write). A rule too wide to
/// be an office never counts.
bool isOfficeIp(String? ip, Iterable<ClaudeAccessRule> rules) =>
    ip != null &&
    ip.isNotEmpty &&
    rules.any((r) => r.kind == ClaudeRuleKind.ip && r.enabled && isValidIp(r.value) && ipInRule(ip, r.value));

/// Whether any of a device's public addresses (IPv4 and IPv6, where it has
/// both) is inside an enabled office rule.
bool isOfficeDevice(Iterable<String> ips, Iterable<ClaudeAccessRule> rules) => ips.any((ip) => isOfficeIp(ip, rules));

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
      : r.value.contains('/')
          ? 'Office network · no prompt there, and this page may be changed from there'
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
  if (m.contains('claude_access_rules_ip_value_check')) {
    return 'An office rule is one address, or a network no wider than /$minIpv4Prefix (IPv4) or /$minIpv6Prefix (IPv6).';
  }
  if (m.contains('duplicate key') || m.contains('claude_access_rules_kind_value_key')) {
    return 'That entry is already on the list.';
  }
  if (m.contains('row-level security') || m.contains('42501') || m.contains('permission denied') || m.contains('PGRST116')) {
    return 'Only an admin with edit access, connected from an office IP, can change this list.';
  }
  return null;
}
