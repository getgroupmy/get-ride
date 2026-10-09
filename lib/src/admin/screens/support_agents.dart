/// Support agents for (re)assigning a ticket (Expo `fetchSupportAgents` /
/// `assignTicket` and the admin support pool's assign sheet).
library;

import 'package:flutter/material.dart';
import '../../widgets/net_image.dart';

/// An admin who can handle support. [priority] is their `admin_access.support`
/// tag: lowest first; untagged agents come after, by name.
typedef SupportAgent = ({String id, String name, String? avatarUrl, int? priority});

List<SupportAgent> sortSupportAgents(Iterable<SupportAgent> agents) => agents.toList()
  ..sort((a, b) {
    final pa = a.priority, pb = b.priority;
    if (pa != null && pb != null && pa != pb) return pa.compareTo(pb);
    if (pa != null && pb == null) return -1;
    if (pa == null && pb != null) return 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

/// Rows of the `support_agents()` RPC (0069), one per admin, sorted.
List<SupportAgent> supportAgentsFromRows(List<dynamic> rows) => sortSupportAgents([
  for (final r in rows)
    if (r is Map && r['profile_id'] != null)
      (
        id: '${r['profile_id']}',
        name: '${r['name'] ?? ''}'.trim().isEmpty ? 'Agent' : '${r['name']}'.trim(),
        avatarUrl: r['avatar_url'] as String?,
        priority: (r['priority'] as num?)?.toInt(),
      ),
]);

/// Picks who a ticket goes to: "Assign to me" first, then every agent in
/// priority order, the current assignee ticked. Null when dismissed.
Future<SupportAgent?> showSupportAgentPicker(
  BuildContext context, {
  required List<SupportAgent> agents,
  required String? meId,
  required String meName,
  String? currentId,
}) {
  final others = [
    for (final a in agents)
      if (a.id != meId) a,
  ];
  return showDialog<SupportAgent>(
    context: context,
    builder: (c) => SimpleDialog(
      key: const ValueKey('support-agent-picker'),
      title: const Text('Assign ticket'),
      children: [
        if (meId != null)
          ListTile(
            key: const ValueKey('assign-me'),
            leading: const Icon(Icons.person_add_alt),
            title: Text('Assign to me ($meName)'),
            trailing: currentId == meId ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(c, (id: meId, name: meName, avatarUrl: null, priority: null)),
          ),
        if (others.isEmpty)
          const ListTile(title: Text('No other support agents found.'))
        else
          for (final a in others)
            ListTile(
              key: ValueKey('assign-${a.id}'),
              leading: NetAvatar(url: a.avatarUrl, fallback: Text(a.name.characters.first.toUpperCase())),
              title: Text(a.name),
              subtitle: a.priority == null ? null : Text('Priority ${a.priority}'),
              trailing: currentId == a.id ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(c, a),
            ),
      ],
    ),
  );
}
