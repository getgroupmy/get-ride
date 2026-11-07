// Approver (migration 0349) — Admin › People › Approvers. Grant a chosen
// user/partner the delegated reviewer role: a permission level (read → approve
// / reject → upload → delete) and a scope (all · their service region · their
// referrals), with a conflict guard, an optional expiry, and a note. Revoking
// is a soft revoke (the grant goes inactive, the approver loses the in-app menu
// at once). Every change is in the audit log (the server's).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/approvers_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/date_boxes.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../profile_search.dart';
import '../../widgets/admin_widgets.dart';

const approversPage = 'admin-approvers';

final approversListProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) => ref.watch(approversRepositoryProvider).list(),
);

bool canEditApprovers(WidgetRef ref) =>
    (ref.watch(adminAccessProvider).value ?? AdminAccess.none).canEdit(const [approversPage]);

const _scopeLabels = {'all': 'All documents', 'region': 'Their service region', 'referral': 'Their referrals'};

String scopeLabel(String? s) => _scopeLabels[s] ?? 'Their referrals';

/// "Approve/Reject · Upload · Delete", always led by Read.
String permissionSummary(Map<String, dynamic> r) => [
      'Read',
      if (r['can_approve'] == true) 'Approve/Reject',
      if (r['can_upload'] == true) 'Upload',
      if (r['can_delete'] == true) 'Delete',
    ].join(' · ');

/// The dialog's answer: the config to save, or revoke them.
typedef ApproverDialogResult = ({Map<String, dynamic>? config, bool remove});

Future<ApproverDialogResult?> showApproverDialog(BuildContext context, {required String name, Map<String, dynamic>? current}) =>
    showAppDialog<ApproverDialogResult>(
      id: 'admin.approver-config',
      context: context,
      builder: (_) => ApproverDialog(name: name, current: current),
    );

/// Grants / re-configures [userId] (or revokes), with a modal for the result.
Future<bool> editApprover(
  BuildContext context,
  WidgetRef ref, {
  required String userId,
  required String name,
  Map<String, dynamic>? current,
}) async {
  final r = await showApproverDialog(context, name: name, current: current);
  if (r == null || !context.mounted) return false;
  final repo = ref.read(approversRepositoryProvider);
  try {
    if (r.remove) {
      await repo.remove(userId);
    } else {
      await repo.set(userId, r.config!);
    }
  } catch (e) {
    if (context.mounted) await showErrorNotice(context, e, title: "Couldn't change the approver");
    return false;
  }
  ref.invalidate(approversListProvider);
  if (context.mounted) {
    await showNotice(
      context,
      title: 'Approvers',
      message: r.remove ? '$name is no longer an approver.' : '$name: ${permissionSummary(r.config!)}.',
    );
  }
  return true;
}

class ApproverDialog extends StatefulWidget {
  const ApproverDialog({super.key, required this.name, this.current});
  final String name;
  final Map<String, dynamic>? current;

  @override
  State<ApproverDialog> createState() => _ApproverDialogState();
}

class _ApproverDialogState extends State<ApproverDialog> {
  late bool _approve = widget.current?['can_approve'] == true;
  late bool _upload = widget.current?['can_upload'] == true;
  late bool _delete = widget.current?['can_delete'] == true;
  late bool _hard = widget.current?['delete_hard'] == true;
  late String _scope = _scopeLabels.containsKey(widget.current?['scope']) ? '${widget.current?['scope']}' : 'referral';
  late bool _useOwn = widget.current?['use_own_region'] != false;
  late bool _conflict = widget.current?['conflict_guard'] != false;
  late final _until = TextEditingController(text: _dateOnly(widget.current?['ends_at']));
  late final _note = TextEditingController(text: '${widget.current?['note'] ?? ''}');
  String? _problem;

  static String _dateOnly(Object? v) {
    final s = '${v ?? ''}';
    return s.length >= 10 ? s.substring(0, 10) : '';
  }

  @override
  void dispose() {
    _until.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final until = _until.text.trim();
    if (until.isNotEmpty && DateTime.tryParse(until) == null) {
      setState(() => _problem = 'Check the end date, or leave it empty.');
      return;
    }
    Navigator.pop(context, (
      config: <String, dynamic>{
        'active': true,
        'can_approve': _approve,
        'can_upload': _upload,
        'can_delete': _delete,
        'delete_hard': _delete && _hard,
        'scope': _scope,
        'use_own_region': _useOwn,
        'conflict_guard': _conflict,
        'ends_at': until.isEmpty ? null : until,
        'note': _note.text.trim(),
      },
      remove: false,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final today = DateTime.now();
    return AlertDialog(
      key: const ValueKey('approver-config'),
      scrollable: true,
      title: Text(widget.current == null ? 'Add approver' : 'Approver: ${widget.name}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.current == null) Text(widget.name, style: t.textTheme.titleSmall),
            Text('What they can do', style: t.textTheme.bodyMedium),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 2),
              child: Text('They can always view documents in their scope.', style: TextStyle(fontSize: 12)),
            ),
            SwitchListTile(
              key: const ValueKey('approver-approve'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Approve / Reject'),
              value: _approve,
              onChanged: (v) => setState(() => _approve = v),
            ),
            SwitchListTile(
              key: const ValueKey('approver-upload'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Upload on their behalf'),
              value: _upload,
              onChanged: (v) => setState(() => _upload = v),
            ),
            SwitchListTile(
              key: const ValueKey('approver-delete'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Delete uploaded documents'),
              value: _delete,
              onChanged: (v) => setState(() => _delete = v),
            ),
            if (_delete)
              SwitchListTile(
                key: const ValueKey('approver-hard'),
                contentPadding: const EdgeInsets.only(left: 16),
                title: const Text('Hard delete (permanent)'),
                subtitle: const Text('Off: the file is archived and an admin can restore it.'),
                value: _hard,
                onChanged: (v) => setState(() => _hard = v),
              ),
            const Divider(),
            Text('Whose documents', style: t.textTheme.bodyMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in _scopeLabels.entries)
                  ChoiceChip(
                    key: ValueKey('approver-scope-${e.key}'),
                    label: Text(e.value),
                    selected: _scope == e.key,
                    onSelected: (_) => setState(() => _scope = e.key),
                  ),
              ],
            ),
            if (_scope == 'region')
              SwitchListTile(
                key: const ValueKey('approver-own-region'),
                contentPadding: EdgeInsets.zero,
                title: const Text("Use the approver's own service region"),
                subtitle: const Text('Off: set specific regions (coming next).'),
                value: _useOwn,
                onChanged: (v) => setState(() => _useOwn = v),
              ),
            const Divider(),
            SwitchListTile(
              key: const ValueKey('approver-conflict'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Conflict guard'),
              // On the referral scope the whole grant IS their referrals, so the
              // "nor people they referred" exclusion is deliberately skipped
              // (approver_covers, 0350) — else the grant would reach no one.
              subtitle: Text(_scope == 'referral'
                  ? "Can't act on their own documents."
                  : "Can't act on their own documents, nor people they referred."),
              value: _conflict,
              onChanged: (v) => setState(() => _conflict = v),
            ),
            const SizedBox(height: 8),
            DateBoxesField(
              key: const ValueKey('approver-until'),
              label: 'Access until (optional)',
              controller: _until,
              firstDate: DateTime(today.year, today.month, today.day),
              lastDate: DateTime(today.year + 3, today.month, today.day),
              helperText: 'Empty: until they are revoked.',
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('approver-note'),
              controller: _note,
              maxLength: 300,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'Branch lead for Selangor'),
            ),
            if (_problem != null)
              Text(_problem!, key: const ValueKey('approver-problem'), style: TextStyle(color: t.colorScheme.error)),
            Text(
              'Every change is in the audit log.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            key: const ValueKey('approver-remove'),
            onPressed: () => Navigator.pop(context, (config: null, remove: true)),
            child: Text('Revoke', style: TextStyle(color: t.colorScheme.error)),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('approver-save'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class ApproversScreen extends ConsumerWidget {
  const ApproversScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final query = await showAppDialog<String>(
      id: 'admin.approver-find',
      context: context,
      builder: (c) {
        final ctl = TextEditingController();
        return AlertDialog(
          title: const Text('Add an approver'),
          content: TextField(
            key: const ValueKey('approver-find'),
            controller: ctl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name, phone or account id'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Search')),
          ],
        );
      },
    );
    if (query == null || query.trim().isEmpty || !context.mounted) return;
    final found = await ref.read(adminRepositoryProvider).searchPeople(query);
    if (!context.mounted) return;
    final id = await showSearchPicker<String>(
      context,
      title: 'Choose who to make an approver',
      choices: [
        for (final p in found) (value: '${p['id']}', label: personLabel(p), subtitle: personDetails(p), leading: null),
      ],
    );
    if (id == null || !context.mounted) return;
    final p = found.firstWhere((x) => '${x['id']}' == id);
    await editApprover(context, ref, userId: id, name: personLabel(p));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final canEdit = canEditApprovers(ref);
    return AdminPage(
      title: 'Approvers',
      page: approversPage,
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              key: const ValueKey('approver-add'),
              onPressed: () => _add(context, ref),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add approver'),
            )
          : null,
      body: AsyncView(
        value: ref.watch(approversListProvider),
        onRetry: () => ref.invalidate(approversListProvider),
        data: (rows) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            ResponsiveCenter(
              maxWidth: 820,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'People you trust to review documents inside the app — on their own menu, limited to their '
                    'permission level and scope. Revoking keeps the history and removes their access at once. '
                    'Every change is in the audit log.',
                    style: muted,
                  ),
                  const SizedBox(height: 8),
                  if (rows.isEmpty) const EmptyState(icon: Icons.verified_user_outlined, title: 'No approvers yet'),
                  ListSearchFilter(
                    count: rows.length,
                    hint: 'Search name or phone',
                    fieldKey: const ValueKey('approver-search'),
                    builder: (_, q) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final r in rows)
                          if (q.isEmpty ||
                              '${r['name'] ?? ''} ${r['phone'] ?? ''}'.toLowerCase().contains(q.toLowerCase()))
                            _ApproverRow(row: r, canEdit: canEdit),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApproverRow extends ConsumerWidget {
  const _ApproverRow({required this.row, required this.canEdit});
  final Map<String, dynamic> row;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final name = '${row['name'] ?? row['phone'] ?? 'User'}';
    final active = row['active'] == true;
    return Card(
      child: ListTile(
        key: ValueKey('approver-row-${row['profile_id']}'),
        title: Row(children: [
          Flexible(child: Text(name)),
          if (!active)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: StatusChip('Revoked'),
            ),
        ]),
        subtitle: Text('${scopeLabel('${row['scope']}')} · ${permissionSummary(row)}'),
        trailing: canEdit ? const Icon(Icons.chevron_right) : null,
        onTap: canEdit
            ? () => editApprover(context, ref, userId: '${row['profile_id']}', name: name, current: row)
            : null,
        titleTextStyle: active ? null : t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
