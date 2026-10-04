/// Pure half of `expo/utils/ipAccessStore.ts` plus the list filtering done in
/// `expo/app/admin-settings-ip-access.tsx`. Rules live in `ip_access_rules`
/// (`unique (ip_address, list_type)`, `list_type in ('whitelist','blacklist')`).
library;

enum IpListType {
  whitelist,
  blacklist;

  static IpListType? parse(Object? v) => switch ('$v') {
        'whitelist' => IpListType.whitelist,
        'blacklist' => IpListType.blacklist,
        _ => null,
      };
}

class IpAccessRule {
  const IpAccessRule({required this.id, required this.ipAddress, required this.listType, this.label, this.createdAt, this.updatedAt});

  factory IpAccessRule.fromRow(Map<String, dynamic> r) => IpAccessRule(
        id: '${r['id']}',
        ipAddress: '${r['ip_address'] ?? ''}',
        listType: IpListType.parse(r['list_type']) ?? IpListType.blacklist,
        label: r['label'] as String?,
        createdAt: r['created_at'] as String?,
        updatedAt: r['updated_at'] as String?,
      );

  final String id;
  final String ipAddress;
  final IpListType listType;
  final String? label;
  final String? createdAt;
  final String? updatedAt;

  bool get isWhitelist => listType == IpListType.whitelist;
}

/// Blacklist wins over whitelist when an IP is (improbably) in both; null for
/// an unmatched IP. This is the decision `evaluateIp` makes on the matching
/// rows' `list_type`s.
IpListType? classifyIp(Iterable<Object?> listTypes) {
  final types = listTypes.map(IpListType.parse).toSet();
  if (types.contains(IpListType.blacklist)) return IpListType.blacklist;
  if (types.contains(IpListType.whitelist)) return IpListType.whitelist;
  return null;
}

/// Row written by add/update (label trimmed, blank → null). Returns an error
/// message instead when the IP is blank.
({Map<String, dynamic>? row, String? error}) ipRuleRow({required String ip, required IpListType listType, String? label}) {
  final v = ip.trim();
  if (v.isEmpty) return (row: null, error: 'Enter an IP address to add.');
  final l = label?.trim() ?? '';
  return (row: {'ip_address': v, 'list_type': listType.name, 'label': l.isEmpty ? null : l}, error: null);
}

({int white, int black}) countRules(List<IpAccessRule> rules) {
  var white = 0;
  for (final r in rules) {
    if (r.isWhitelist) white++;
  }
  return (white: white, black: rules.length - white);
}

/// [filter] is null for "all".
List<IpAccessRule> filterRules(List<IpAccessRule> rules, {String query = '', IpListType? filter}) {
  final q = query.trim().toLowerCase();
  return rules.where((r) {
    if (filter != null && r.listType != filter) return false;
    if (q.isEmpty) return true;
    return '${r.ipAddress} ${r.label ?? ''}'.toLowerCase().contains(q);
  }).toList();
}

String ruleSubtitle(IpAccessRule r) {
  final l = r.label?.trim() ?? '';
  if (l.isNotEmpty) return l;
  return r.isWhitelist ? 'Allowed — bypass admin login' : 'Blocked — Service Not Available';
}

/// Public-IP providers tried in order (same list as Expo `lookupPublicIp`).
const publicIpProviders = [
  'https://api.ipify.org?format=json',
  'https://api64.ipify.org?format=json',
  'https://ipapi.co/json/',
  'https://icanhazip.com',
];

/// Extracts the IP from a provider response (JSON `{ip}` or plain text).
String? parsePublicIp(String body) {
  final t = body.trim();
  if (t.isEmpty) return null;
  if (t.startsWith('{')) {
    final m = RegExp(r'"ip"\s*:\s*"([^"]+)"').firstMatch(t);
    return m?.group(1);
  }
  return RegExp(r'^[0-9a-fA-F:.]+$').hasMatch(t) ? t : null;
}
