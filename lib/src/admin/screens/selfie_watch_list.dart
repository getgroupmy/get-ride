// The selfie watch list (migration 0290): partners checked more often when
// they go online, each with their own rule (every go-online, a % with a
// daily cap, or every N hours online), an optional end date and the reason.
// Set here, from Edit Partner, or from a low-match alert. Removing someone
// puts them back on the normal rule. Every change is in the audit log (the
// server's). The partner is never told.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/online_selfie.dart';
import '../../data/online_selfie_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/date_boxes.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../profile_search.dart';
import '../widgets/admin_widgets.dart';
import 'dispatch/selfie_checks_settings.dart' show dispatchSelfiePage;

final selfieWatchListProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) => ref.watch(onlineSelfieRepositoryProvider).watchList(),
);

/// Pages whose editors change the watch list (the server's admin_table_pages).
const watchListEditPages = [
  dispatchSelfiePage,
  'admin-partners',
  'admin-partner-edit',
  'admin-documents',
  'admin-documents-partners',
  'admin-support',
];

bool canEditWatchList(WidgetRef ref) =>
    (ref.watch(adminAccessProvider).value ?? AdminAccess.none).canEdit(watchListEditPages);

/// The dialog's answer: the entry to keep, or remove them.
typedef WatchDialogResult = ({WatchEntry? entry, bool remove});

/// "Every go-online · until 30 Nov".
String watchEntryText(WatchEntry w) =>
    watchRuleText(w, untilText: w.until == null ? null : formatStoredDateForUser(w.until));

Future<WatchDialogResult?> showWatchRuleDialog(BuildContext context, {required String name, WatchEntry? initial}) =>
    showAppDialog<WatchDialogResult>(
      id: 'admin.selfie-watch-rule',
      context: context,
      builder: (_) => WatchRuleDialog(name: name, initial: initial),
    );

/// Adds [userId] to the watch list or changes their rule (or removes them),
/// with a modal for the result. True when something changed.
Future<bool> editSelfieWatch(
  BuildContext context,
  WidgetRef ref, {
  required String userId,
  required String name,
  WatchEntry? current,
  String? fromCheck,
}) async {
  final r = await showWatchRuleDialog(context, name: name, initial: current);
  if (r == null || !context.mounted) return false;
  final repo = ref.read(onlineSelfieRepositoryProvider);
  try {
    if (r.remove) {
      await repo.watchRemove(userId);
    } else {
      await repo.watchSet(userId, r.entry!, fromCheck: fromCheck);
    }
  } catch (e) {
    if (context.mounted) await showErrorNotice(context, e, title: "Couldn't change the watch list");
    return false;
  }
  ref.invalidate(selfieWatchListProvider);
  if (context.mounted) {
    await showNotice(
      context,
      title: 'Watch list',
      message: r.remove ? '$name is back on the normal rule.' : '$name: ${watchEntryText(r.entry!)}.',
    );
  }
  return true;
}

class WatchRuleDialog extends StatefulWidget {
  const WatchRuleDialog({super.key, required this.name, this.initial});
  final String name;
  final WatchEntry? initial;

  @override
  State<WatchRuleDialog> createState() => _WatchRuleDialogState();
}

class _WatchRuleDialogState extends State<WatchRuleDialog> {
  late WatchRule _rule = widget.initial?.rule ?? WatchRule.every;
  late final _pct = TextEditingController(text: '${widget.initial?.pct ?? 50}');
  late final _cap = TextEditingController(text: '${widget.initial?.cap ?? 3}');
  late final _hours = TextEditingController(text: '${widget.initial?.hours ?? 8}');
  late final _until = TextEditingController(text: widget.initial?.until ?? '');
  late final _reason = TextEditingController(text: widget.initial?.reason ?? '');
  String? _problem;

  @override
  void dispose() {
    for (final c in [_pct, _cap, _hours, _until, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final until = _until.text.trim();
    if (until.isNotEmpty && DateTime.tryParse(until) == null) {
      setState(() => _problem = 'Check the end date, or leave it empty.');
      return;
    }
    final e = WatchEntry(
      rule: _rule,
      pct: int.tryParse(_pct.text.trim()) ?? 0,
      cap: int.tryParse(_cap.text.trim()) ?? 0,
      hours: int.tryParse(_hours.text.trim()) ?? 0,
      until: until.isEmpty ? null : until,
      reason: _reason.text.trim(),
    );
    final p = e.problem;
    if (p != null) {
      setState(() => _problem = p);
      return;
    }
    Navigator.pop(context, (entry: e, remove: false));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final today = DateTime.now();
    Widget number(Key key, TextEditingController c, String label, {String? suffix}) => SizedBox(
      width: 150,
      child: TextField(
        key: key,
        controller: c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label, suffixText: suffix),
      ),
    );
    return AlertDialog(
      key: const ValueKey('watch-rule'),
      scrollable: true,
      title: Text(widget.initial == null ? 'Add to the watch list' : 'Watch list: ${widget.name}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.initial == null) Text(widget.name, style: t.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text('Check them', style: t.textTheme.bodyMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in WatchRule.values)
                  ChoiceChip(
                    key: ValueKey('watch-rule-${r.value}'),
                    label: Text(r.label),
                    selected: _rule == r,
                    onSelected: (_) => setState(() => _rule = r),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_rule == WatchRule.percent)
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  number(const ValueKey('watch-pct'), _pct, 'Chance', suffix: '%'),
                  number(const ValueKey('watch-cap'), _cap, 'At most', suffix: 'a day'),
                ],
              ),
            if (_rule == WatchRule.hours)
              number(const ValueKey('watch-hours'), _hours, 'Every', suffix: 'hours online'),
            if (_rule != WatchRule.every) const SizedBox(height: 12),
            DateBoxesField(
              key: const ValueKey('watch-until'),
              label: 'Until (optional)',
              controller: _until,
              firstDate: DateTime(today.year, today.month, today.day),
              lastDate: DateTime(today.year + 2, today.month, today.day),
              helperText: 'Empty: until they are removed.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('watch-reason'),
              controller: _reason,
              maxLength: 300,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Reason', hintText: 'Reported by a rider: different driver'),
            ),
            if (_problem != null)
              Text(
                _problem!,
                key: const ValueKey('watch-problem'),
                style: TextStyle(color: t.colorScheme.error),
              ),
            Text(
              'The partner is not told. Every change is in the audit log.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.initial != null)
          TextButton(
            key: const ValueKey('watch-remove'),
            onPressed: () => Navigator.pop(context, (entry: null, remove: true)),
            child: Text('Remove', style: TextStyle(color: t.colorScheme.error)),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('watch-save'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// The watch list page (from Dispatch › Partner selfie checks).
class SelfieWatchListScreen extends ConsumerWidget {
  const SelfieWatchListScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final query = await showAppDialog<String>(
      id: 'admin.selfie-watch-find',
      context: context,
      builder: (c) {
        final ctl = TextEditingController();
        return AlertDialog(
          title: const Text('Add a partner'),
          content: TextField(
            key: const ValueKey('watch-find'),
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
      title: 'Add to the watch list',
      choices: [
        for (final p in found) (value: '${p['id']}', label: personLabel(p), subtitle: personDetails(p), leading: null),
      ],
    );
    if (id == null || !context.mounted) return;
    final p = found.firstWhere((x) => '${x['id']}' == id);
    await editSelfieWatch(context, ref, userId: id, name: personLabel(p));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final canEdit = canEditWatchList(ref);
    return AdminPage(
      title: 'Selfie watch list',
      page: dispatchSelfiePage,
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              key: const ValueKey('watch-add'),
              onPressed: () => _add(context, ref),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add partner'),
            )
          : null,
      body: AsyncView(
        value: ref.watch(selfieWatchListProvider),
        onRetry: () => ref.invalidate(selfieWatchListProvider),
        data: (rows) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            ResponsiveCenter(
              maxWidth: 820,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Partners to check more often when they go online (possible abuse), each with their own rule '
                    'and a reason. Set here, from Edit Partner, or from a low-match alert. Removing someone puts '
                    'them back on the normal rule. Every change is in the audit log.',
                    style: muted,
                  ),
                  const SizedBox(height: 8),
                  if (rows.isEmpty)
                    const EmptyState(icon: Icons.visibility_off_outlined, title: 'Nobody on the watch list'),
                  ListSearchFilter(
                    count: rows.length,
                    hint: 'Search name or phone',
                    fieldKey: const ValueKey('watch-search'),
                    builder: (_, q) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final r in rows)
                          if (q.isEmpty ||
                              '${r['name'] ?? ''} ${r['phone'] ?? ''}'.toLowerCase().contains(q.toLowerCase()))
                            _WatchRow(row: r, canEdit: canEdit),
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

class _WatchRow extends ConsumerWidget {
  const _WatchRow({required this.row, required this.canEdit});
  final Map<String, dynamic> row;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final w = WatchEntry.fromJson(row);
    final name = '${row['name'] ?? row['phone'] ?? 'Partner'}';
    final by = row['updated_by_name'] ?? row['added_by_name'];
    return Card(
      child: ListTile(
        key: ValueKey('watch-row-${row['profile_id']}'),
        title: Text(name),
        subtitle: Text(
          [w.reason, if (by != null) 'By $by · ${dateText(row['updated_at'] ?? row['added_at'])}'].join('\n'),
        ),
        isThreeLine: by != null,
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 170),
          child: Text(
            watchEntryText(w),
            textAlign: TextAlign.end,
            style: t.textTheme.labelMedium?.copyWith(
              color: w.active ? t.colorScheme.onSurface : t.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        onTap: () async {
          if (!canEdit) {
            if (row['partner_id'] != null) await context.push('/admin/m/partner-edit?id=${row['partner_id']}');
            return;
          }
          await editSelfieWatch(context, ref, userId: '${row['profile_id']}', name: name, current: w);
        },
      ),
    );
  }
}
