// Admin › People › Families (migration 0317): every family with its member
// cap (raised by an admin), the hosts' requests for more members (approve or
// decline), and God View's logged look: a reason first, every look logged
// (who, when, why), the log below.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/date_order.dart' show formatDateForUser;
import '../../../core/family.dart';
import '../../../data/family_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';

class FamilyListScreen extends ConsumerStatefulWidget {
  const FamilyListScreen({super.key});

  @override
  ConsumerState<FamilyListScreen> createState() => _FamilyListScreenState();
}

class _FamilyListScreenState extends ConsumerState<FamilyListScreen> {
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _reload() {
    ref.invalidate(familyAdminListProvider);
    ref.invalidate(familyCapRequestsProvider);
    ref.invalidate(familyAdminLogProvider);
  }

  Future<void> _cap(FamilyAdminRow f) async {
    var cap = f.cap;
    final ok = await showAppDialog<bool>(
      id: 'admin.family-cap',
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text('Member cap · ${f.hostName}'),
          content: Row(children: [
            Expanded(child: Text('Most members (now ${f.count})')),
            IconButton(tooltip: 'Lower', onPressed: cap > 1 ? () => set(() => cap--) : null, icon: const Icon(Icons.remove)),
            Text('$cap', key: const ValueKey('family-admin-cap-value')),
            IconButton(
              key: const ValueKey('family-admin-cap-up'),
              tooltip: 'Raise',
              onPressed: cap < 200 ? () => set(() => cap++) : null,
              icon: const Icon(Icons.add),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(key: const ValueKey('family-admin-cap-save'), onPressed: () => Navigator.pop(c, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    if (await runAdminAction(context, () => ref.read(familyRepositoryProvider).setCap(f.id, cap),
        success: 'Member cap saved')) {
      _reload();
    }
  }

  /// God View, logged: a reason first.
  Future<void> _look(FamilyAdminRow f) async {
    var kind = 'report';
    final reason = TextEditingController();
    final go = await showAppDialog<bool>(
      id: 'admin.family-view-reason',
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text('Open ${f.hostName}\'s family'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('This look is logged with your name, the time and the reason. The members can read it.'),
              const SizedBox(height: 10),
              Wrap(spacing: 6, children: [
                for (final e in familyViewReasons.entries)
                  ChoiceChip(
                    key: ValueKey('family-reason-${e.key}'),
                    label: Text(e.value),
                    selected: kind == e.key,
                    onSelected: (_) => set(() => kind = e.key),
                  ),
              ]),
              TextField(
                key: const ValueKey('family-reason-text'),
                controller: reason,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Reason', helperText: 'At least 10 characters'),
                onChanged: (_) => set(() {}),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(
              key: const ValueKey('family-reason-open'),
              onPressed: familyReasonOk(kind, reason.text) ? () => Navigator.pop(c, true) : null,
              child: const Text('Open, logged'),
            ),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    try {
      final v = await ref.read(familyRepositoryProvider).adminView(f.id, kind, reason.text.trim());
      ref.invalidate(familyAdminLogProvider);
      if (!mounted) return;
      final members = [
        for (final m in (v['members'] as List? ?? const []))
          if (m is Map) FamilyMember.fromJson(Map<String, dynamic>.from(m)),
      ];
      final trips = [for (final t in (v['trips'] as List? ?? const [])) if (t is Map) t];
      await showAppDialog<void>(
        id: 'admin.family-view',
        context: context,
        builder: (c) => AlertDialog(
          title: Text('${f.hostName}\'s family'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(key: const ValueKey('family-admin-view'), crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final m in members)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(m.isChild ? Icons.child_care : Icons.person_outline),
                    title: Text(m.name),
                    subtitle: Text('${m.status} · location rule ${m.locationNow.label.toLowerCase()}'),
                  ),
                const Divider(),
                Text('Recent trips', style: Theme.of(c).textTheme.titleSmall),
                for (final t in trips)
                  Text('${t['member']} · ${t['module']} · ${t['status'] ?? ''}'
                      '${t['lat'] != null ? ' · ${t['lat']}, ${t['lng']}' : ''}'),
              ]),
            ),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _decide(FamilyCapRequest r, bool approve) async {
    String? note;
    if (!approve) {
      final c = TextEditingController();
      final ok = await showAppDialog<bool>(
        id: 'admin.family-decline',
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Decline the request'),
          content: TextField(
            key: const ValueKey('family-decline-note'),
            controller: c,
            maxLength: 300,
            decoration: const InputDecoration(labelText: 'Note to the host (optional)'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
            FilledButton(key: const ValueKey('family-decline-confirm'), onPressed: () => Navigator.pop(d, true),
                child: const Text('Decline')),
          ],
        ),
      );
      if (ok != true) return;
      note = c.text.trim();
    }
    if (!mounted) return;
    if (await runAdminAction(context, () => ref.read(familyRepositoryProvider).decide(r.id, approve: approve, note: note),
        success: approve ? 'Approved: ${r.hostName} can have ${r.wanted}' : 'Declined')) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(familyAdminPage)) == AccessLevel.edit;
    final t = Theme.of(context);
    return DefaultTabController(
      length: 3,
      child: AdminPage(
        title: 'Families',
        page: familyAdminPage,
        bottom: const TabBar(tabs: [Tab(text: 'Families'), Tab(text: 'Requests'), Tab(text: 'God View log')]),
        body: TabBarView(children: [
          Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                key: const ValueKey('family-admin-search'),
                controller: _search,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Search a host by name or phone'),
                onSubmitted: (s) => setState(() => _q = s),
                onChanged: (s) {
                  if (s.isEmpty) setState(() => _q = '');
                },
              ),
            ),
            Expanded(
              child: AsyncView(
                value: ref.watch(familyAdminListProvider(_q)),
                onRetry: _reload,
                data: (rows) => rows.isEmpty
                    ? const EmptyState(icon: Icons.family_restroom, title: 'No families yet')
                    : ListView(children: [
                        for (final f in rows)
                          ListTile(
                            key: ValueKey('family-admin-row-${f.id}'),
                            title: Text(f.hostName),
                            subtitle: Text([
                              ?f.hostPhone,
                              if (f.place.isNotEmpty) f.place,
                              '${f.count} of ${f.cap} members${f.capOwn != null ? ' (raised)' : ''}',
                              if (f.children > 0) '${f.children} ${f.children == 1 ? 'child' : 'children'}',
                              if (f.pending > 0) 'asks for more',
                            ].join(' · ')),
                            trailing: Wrap(children: [
                              IconButton(
                                key: ValueKey('family-admin-look-${f.id}'),
                                tooltip: 'Open in God View (logged)',
                                icon: const Icon(Icons.visibility_outlined),
                                onPressed: () => _look(f),
                              ),
                              if (canEdit)
                                IconButton(
                                  key: ValueKey('family-admin-cap-${f.id}'),
                                  tooltip: 'Member cap',
                                  icon: const Icon(Icons.group_add_outlined),
                                  onPressed: () => _cap(f),
                                ),
                            ]),
                          ),
                      ]),
              ),
            ),
          ]),
          AsyncView(
            value: ref.watch(familyCapRequestsProvider),
            onRetry: _reload,
            data: (reqs) => reqs.isEmpty
                ? const EmptyState(icon: Icons.inbox_outlined, title: 'No requests')
                : ListView(children: [
                    for (final r in reqs)
                      ListTile(
                        key: ValueKey('family-request-${r.id}'),
                        title: Text('${r.hostName} asks for ${r.wanted} members'),
                        subtitle: Text('Now ${r.count} of ${r.cap}${r.reason == null ? '' : ' · ${r.reason}'}'),
                        trailing: canEdit
                            ? Wrap(children: [
                                TextButton(
                                  key: ValueKey('family-request-decline-${r.id}'),
                                  onPressed: () => _decide(r, false),
                                  child: const Text('Decline'),
                                ),
                                FilledButton(
                                  key: ValueKey('family-request-approve-${r.id}'),
                                  style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                                  onPressed: () => _decide(r, true),
                                  child: const Text('Approve'),
                                ),
                              ])
                            : null,
                      ),
                  ]),
          ),
          AsyncView(
            value: ref.watch(familyAdminLogProvider),
            onRetry: _reload,
            data: (log) => log.isEmpty
                ? const EmptyState(icon: Icons.policy_outlined, title: 'No looks logged')
                : ListView(children: [
                    for (final e in log)
                      ListTile(
                        leading: const Icon(Icons.history),
                        title: Text('${e.by ?? 'Admin'} opened ${e.hostName ?? 'a family'}'),
                        subtitle: Text('${familyViewReasons[e.kind] ?? e.kind}: ${e.reason}'
                            '${e.at == null ? '' : ' · ${formatDateForUser(e.at)}'}'),
                        subtitleTextStyle: t.textTheme.bodySmall,
                      ),
                  ]),
          ),
        ]),
      ),
    );
  }
}
