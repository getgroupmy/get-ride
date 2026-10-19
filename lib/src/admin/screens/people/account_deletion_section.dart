// Admin → Users, a user's sheet (migration 0194): a deleted account's story
// and its final deletion, or linking a deleted account into this one.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../../core/account_deletion.dart';
import '../../../data/account_deletion_repository.dart';
import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';
import '../../../widgets/page_style_host.dart';

final accountEventsProvider = FutureProvider.autoDispose.family<List<AccountEvent>, String>(
  (ref, id) => ref.watch(accountDeletionRepositoryProvider).events(id),
);

/// Runs [action], turning the server's refusal into its sentence.
Future<T> _friendly<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on PostgrestException catch (e) {
    throw StateError(serverRefusalText(e.message, e.hint));
  }
}

class AccountDeletionSection extends ConsumerWidget {
  const AccountDeletionSection({super.key, required this.user, required this.canEdit});
  final Map<String, dynamic> user;
  final bool canEdit;

  String get _id => '${user['id']}';
  bool get _deleted => user['deleted_at'] != null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final events = ref.watch(accountEventsProvider(_id)).value ?? const <AccountEvent>[];
    final days = ref.watch(accountRetentionDaysProvider).value ?? 365;
    final wiped = user['final_deleted_at'] != null;
    final due = finalDeletionDueAt(user, days);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_deleted)
          Card(
            key: const ValueKey('account-deleted-card'),
            color: t.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: t.colorScheme.onErrorContainer),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      wiped ? 'Deleted, personal data wiped' : 'Deleted by the user',
                      style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onErrorContainer),
                    ),
                    const SizedBox(height: 4),
                    Text('On ${dateText(user['deleted_at'])}'),
                    if (user['deleted_phone'] != null) Text('Number: ${user['deleted_phone']} (now free)'),
                    if ((user['deletion_reason'] as String?)?.isNotEmpty == true)
                      Text('Reason: ${user['deletion_reason']}'),
                    if (!wiped && due != null)
                      Text(
                        'Final deletion due ${dateText(due.toUtc().toIso8601String())} '
                        '(after $days days)',
                      ),
                  ],
                ),
              ),
            ),
          ),
        for (final e in events)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.history, size: 18),
            title: Text(e.summary),
            subtitle: Text(
              [
                if (e.at != null) dateText(e.at!.toUtc().toIso8601String()),
                if (e.kind == 'linked' && e.otherProfileId == _id) 'into this account',
              ].join(' · '),
            ),
          ),
        if (canEdit && _deleted && !wiped)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('final-delete'),
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: const Text('Approve final deletion'),
                  onPressed: dueForFinalDeletion(user, days, DateTime.now()) ? () => _finalDelete(context, ref) : null,
                ),
                TextButton(
                  key: const ValueKey('retention-days'),
                  onPressed: () => _editRetention(context, ref, days),
                  child: Text('Keep deleted accounts $days days'),
                ),
              ],
            ),
          ),
        if (canEdit && !_deleted)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              key: const ValueKey('link-previous-account'),
              icon: const Icon(Icons.link),
              label: const Text('Link previous account'),
              onPressed: () => showAppDialog<void>(id: 'account-deletion-section.account-deletion-section',
                context: context,
                builder: (_) => LinkAccountDialog(newAccount: user),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _finalDelete(BuildContext context, WidgetRef ref) async {
    if (!await confirm(
      context,
      'Wipe this account for good?',
      'Name, ID number, photos, documents, contacts, saved places and devices are removed. '
          'Rides, receipts and the wallet ledger stay, anonymised. This can\'t be undone.',
      ok: 'Wipe',
    )) {
      return;
    }
    if (!context.mounted) return;
    var files = 0;
    final ok = await runAdminAction(
      context,
      () async => files = await _friendly(() => ref.read(accountDeletionRepositoryProvider).finalDelete(_id)),
    );
    if (!ok || !context.mounted) return;
    showInfo(context, 'Account wiped, $files ${files == 1 ? 'file' : 'files'} removed');
    ref.invalidate(accountEventsProvider(_id));
    Navigator.pop(context);
  }

  Future<void> _editRetention(BuildContext context, WidgetRef ref, int days) async {
    final c = TextEditingController(text: '$days');
    final v = await showAppDialog<int>(id: 'account-deletion-section.edit-retention',
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Keep deleted accounts'),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Days before final deletion', helperText: '30 to 3650'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(c.text.trim())), child: const Text('Save')),
        ],
      ),
    );
    c.dispose();
    if (v == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () => _friendly(() => ref.read(accountDeletionRepositoryProvider).saveRetentionDays(v)),
      success: 'Saved',
    );
    if (ok) ref.invalidate(accountRetentionDaysProvider);
  }
}

final _deletedAccountsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({String? phone, String search})>(
      (ref, q) => ref.watch(accountDeletionRepositoryProvider).deletedAccounts(phone: q.phone, search: q.search),
    );

/// Pick the deleted account, then what moves into [newAccount].
class LinkAccountDialog extends ConsumerStatefulWidget {
  const LinkAccountDialog({super.key, required this.newAccount});
  final Map<String, dynamic> newAccount;

  @override
  ConsumerState<LinkAccountDialog> createState() => _LinkAccountDialogState();
}

class _LinkAccountDialogState extends ConsumerState<LinkAccountDialog> {
  String _search = '';
  Map<String, dynamic>? _old;
  final _what = <AccountLinkCategory>{};
  bool _busy = false;

  String get _phone => '${widget.newAccount['phone'] ?? ''}';

  Future<void> _link() async {
    final old = _old;
    if (old == null || _what.isEmpty || _busy) return;
    setState(() => _busy = true);
    Map<String, dynamic> result = const {};
    final ok = await runAdminAction(
      context,
      () async => result = await _friendly(
        () => ref.read(accountDeletionRepositoryProvider).link('${old['id']}', '${widget.newAccount['id']}', _what),
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    ref.invalidate(accountEventsProvider('${widget.newAccount['id']}'));
    ref.invalidate(accountEventsProvider('${old['id']}'));
    final moved = [
      for (final e in result.entries)
        if (e.key != 'ok' && e.value is num && e.value != 0) '${e.key}: ${e.value}',
    ];
    Navigator.pop(context);
    showInfo(context, moved.isEmpty ? 'Linked' : 'Linked · ${moved.join(', ')}');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final old = _old;
    return AlertDialog(
      title: Text(old == null ? 'Link previous account' : 'What moves to this account'),
      content: SizedBox(width: 460, child: old == null ? _pickAccount(t) : _pickParts(t, old)),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => old == null ? Navigator.pop(context) : setState(() => _old = null),
          child: Text(old == null ? 'Cancel' : 'Back'),
        ),
        if (old != null)
          FilledButton(
            key: const ValueKey('link-confirm'),
            onPressed: _what.isEmpty || _busy ? null : _link,
            child: const Text('Link'),
          ),
      ],
    );
  }

  Widget _pickAccount(ThemeData t) {
    final list = ref.watch(_deletedAccountsProvider((phone: _phone, search: _search)));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('link-search'),
          // The dialog's first step is a search: typing goes straight in.
          autofocus: true,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search old number or name'),
          onSubmitted: (v) => setState(() => _search = v),
        ),
        const SizedBox(height: 8),
        Flexible(
          child: list.when(
            skipLoadingOnReload: true,
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text(errorText(e)),
            data: (rows) => rows.isEmpty
                ? const Padding(padding: EdgeInsets.all(16), child: Text('No deleted accounts found.'))
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final r in rows)
                        ListTile(
                          key: ValueKey('deleted-account-${r['id']}'),
                          leading: const Icon(Icons.person_off_outlined),
                          title: Text((r['name'] as String?)?.isNotEmpty == true ? r['name'] as String : '(no name)'),
                          subtitle: Text('${r['deleted_phone'] ?? '—'} · deleted ${dateText(r['deleted_at'])}'),
                          trailing:
                              '${r['deleted_phone']}'.replaceAll(RegExp(r'\D'), '') ==
                                  _phone.replaceAll(RegExp(r'\D'), '')
                              ? Chip(
                                  label: const Text('Same number'),
                                  backgroundColor: t.colorScheme.secondaryContainer,
                                )
                              : null,
                          onTap: () => setState(() {
                            _old = r;
                            _what.clear();
                          }),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _pickParts(ThemeData t, Map<String, dynamic> old) {
    final events = ref.watch(accountEventsProvider('${old['id']}'));
    final done = linkedCategories(events.value ?? const []);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'From ${old['name'] ?? '(no name)'} · ${old['deleted_phone'] ?? ''}',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          for (final c in AccountLinkCategory.values)
            CheckboxListTile(
              key: ValueKey('link-${c.key}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: done.contains(c.key) || _what.contains(c),
              onChanged: done.contains(c.key) || _busy
                  ? null
                  : (v) => setState(() => v == true ? _what.add(c) : _what.remove(c)),
              title: Text(c.label),
              subtitle: done.contains(c.key) ? const Text('Already linked') : null,
            ),
          if (_what.contains(AccountLinkCategory.partner))
            Text(
              'The partner profile goes back to review: approve it again once checked.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          const SizedBox(height: 4),
          Text(
            'Every link is recorded with your name.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
