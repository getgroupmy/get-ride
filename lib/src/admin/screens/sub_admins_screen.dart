import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth_utils.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_categories.g.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import '../../data/live_tables.dart';

typedef _GrantsView = ({List<AdminGrant> grants, Map<String, Map<String, dynamic>> people});

final _grantsProvider = FutureProvider.autoDispose<_GrantsView>((ref) async {
  ref.watchLive('admin_access');
  final repo = ref.watch(adminRepositoryProvider);
  final grants = (await repo.allGrants()).map(AdminGrant.fromRow).toList();
  final people = await repo.profilesByIds(grants.map((g) => g.profileId).whereType<String>());
  return (grants: grants, people: people);
});

/// Every page key an admin can be granted: modules plus each settings page.
final grantablePages = <String, String>{
  '*': 'All pages (full admin)',
  for (final m in adminModules.values)
    for (final p in m.pages) p: '${m.label} · $p',
  for (final c in crudCategories) c.page: 'Settings · ${c.title}',
};

class AdminSubAdminsScreen extends ConsumerWidget {
  const AdminSubAdminsScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final phone = TextEditingController();
    String page = '*';
    bool edit = false;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Grant admin access'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Account phone number',
                  helperText: 'Include the country code, e.g. +60123456789',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: page,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Page'),
                items: [
                  for (final e in grantablePages.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => set(() => page = v ?? page),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Can edit'),
                subtitle: const Text('Off = view only'),
                value: edit,
                onChanged: (v) => set(() => edit = v),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Grant')),
          ],
        ),
      ),
    );
    if (go != true || !context.mounted) return;
    final repo = ref.read(adminRepositoryProvider);
    final profile = await repo.profileByPhone(normalizeE164(phone.text));
    if (!context.mounted) return;
    if (profile == null) {
      showInfo(context, 'No GET.ride account has that phone number. They need to sign up first.');
      return;
    }
    final ok = await runAdminAction(
      context,
      () => repo.grant(profileId: profile['id'] as String, page: page, edit: edit),
      success: 'Access granted to ${profile['name'] ?? profile['phone']}',
    );
    if (ok) ref.invalidate(_grantsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(moduleAccessProvider('sub-admins')) == AccessLevel.edit;
    final me = ref.watch(currentUserIdProvider);
    return AdminPage(
      title: 'Sub-admins',
      module: 'sub-admins',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context, ref),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Grant access'),
      ),
      body: AsyncView(
        value: ref.watch(_grantsProvider),
        onRetry: () => ref.invalidate(_grantsProvider),
        data: (v) {
          final byPerson = <String, List<AdminGrant>>{};
          for (final g in v.grants) {
            byPerson.putIfAbsent(g.profileId ?? '?', () => []).add(g);
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            for (final e in byPerson.entries)
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.admin_panel_settings_outlined),
                  title: Text('${v.people[e.key]?['name'] ?? v.people[e.key]?['phone'] ?? e.key}'
                      '${e.key == me ? ' (you)' : ''}'),
                  subtitle: Text('${v.people[e.key]?['phone'] ?? ''} · ${e.value.length} grant(s)'),
                  children: [
                    for (final g in e.value)
                      ListTile(
                        title: Text(grantablePages[g.page] ?? g.page),
                        subtitle: g.notes == null ? null : Text(g.notes!),
                        leading: StatusChip(g.edit ? 'edit' : 'read'),
                        trailing: canEdit && g.id != null
                            ? IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Revoke',
                                onPressed: () async {
                                  final self = e.key == me && g.page == '*';
                                  if (!await confirm(
                                    context,
                                    'Revoke access?',
                                    self
                                        ? 'This removes your own full admin access. You may lose access to this panel.'
                                        : 'Revoke ${grantablePages[g.page] ?? g.page}?',
                                    ok: 'Revoke',
                                  )) {
                                    return;
                                  }
                                  if (!context.mounted) return;
                                  if (await runAdminAction(
                                      context, () => ref.read(adminRepositoryProvider).revoke(g.id!))) {
                                    ref.invalidate(_grantsProvider);
                                    ref.invalidate(adminAccessProvider);
                                  }
                                },
                              )
                            : null,
                      ),
                  ],
                ),
              ),
          ]);
        },
      ),
    );
  }
}
