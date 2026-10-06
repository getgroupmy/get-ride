import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_categories.g.dart';
import '../admin_providers.dart';
import '../admin_registry.dart';
import '../admin_settings_models.dart';
import '../widgets/admin_widgets.dart';
import '../../data/live_tables.dart';

/// Looks up a category; unknown keys become a raw `settings_entries` editor.
SettingsCategory categoryFor(String key) =>
    crudCategories.where((c) => c.key == key).firstOrNull ??
    SettingsCategory(
      key: key,
      page: 'admin-settings-$key',
      title: key.split('-').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' '),
      subtitle: 'Advanced: edited as raw JSON values',
      table: 'settings_entries',
      fields: const [],
    );

final _otherCategoriesProvider = FutureProvider.autoDispose<List<String>>((ref) async {
  ref.watchLive('settings_entries');
  final known = {...crudCategories.map((c) => c.key), ...allOwnedCategories};
  final names = await ref.watch(adminRepositoryProvider).settingCategoryNames();
  return names.where((n) => !known.contains(n)).toList();
});

AccessLevel _categoryLevel(WidgetRef ref, SettingsCategory c) {
  final access = ref.watch(adminAccessProvider).value ?? AdminAccess.none;
  return access.levelFor([c.page, 'admin-settings']);
}

class AdminSettingsScreen extends ConsumerWidget {
  const AdminSettingsScreen({super.key});

  List<AdminScreenEntry> _entriesIn(WidgetRef ref, String section) {
    final access = ref.watch(adminAccessProvider).value ?? AdminAccess.none;
    return allAdminEntries
        .where((e) => e.listed && e.section == section && access.canRead([...e.pages, 'admin-settings']))
        .toList();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = crudCategories.where((c) => !c.nested && _categoryLevel(ref, c) != AccessLevel.none).toList();
    final others = ref.watch(_otherCategoriesProvider);
    return AdminPage(
      title: 'Settings',
      module: 'settings',
      body: ListView(padding: const EdgeInsets.all(16), children: [
        for (final section in adminSections) ...[
          if (_entriesIn(ref, section).isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
              child: Text(section, style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final e in _entriesIn(ref, section))
              Card(
                child: ListTile(
                  leading: Icon(e.icon),
                  title: Text(e.title),
                  subtitle: Text(e.subtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go(e.path),
                ),
              ),
          ],
        ],
        if (visible.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
            child: Text('Lists', style: Theme.of(context).textTheme.titleMedium),
          ),
        for (final c in visible)
          Card(
            child: ListTile(
              title: Text(c.title),
              subtitle: Text(c.subtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/admin/settings/${c.key}'),
            ),
          ),
        if ((others.value ?? []).isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('More categories (advanced)', style: Theme.of(context).textTheme.titleMedium),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text('These have custom editors in the Expo app. Here they are edited as raw values, so '
                'change them carefully.'),
          ),
          for (final k in others.value!)
            if (_categoryLevel(ref, categoryFor(k)) != AccessLevel.none)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.data_object),
                  title: Text(categoryFor(k).title),
                  subtitle: Text(k),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/admin/settings/$k'),
                ),
              ),
        ],
      ]),
    );
  }
}

final _entriesProvider = FutureProvider.autoDispose.family<List<SettingEntry>, String>(
  (ref, key) {
  ref.watchLive('settings_entries');
  return ref.watch(adminRepositoryProvider).settings(categoryFor(key));
},
);

/// List + editor for one category, optionally scoped to a parent row
/// (insurance provider → types → durations → premiums).
class AdminCategoryScreen extends ConsumerWidget {
  const AdminCategoryScreen({super.key, required this.categoryKey, this.scope = const {}, this.parentLabel});
  final String categoryKey;
  final Map<String, String> scope;
  final String? parentLabel;

  SettingsCategory get category => categoryFor(categoryKey);

  Future<void> _edit(BuildContext context, WidgetRef ref, List<SettingEntry> all, [SettingEntry? entry]) async {
    final c = category;
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => c.isRaw ? _RawEditor(entry: entry) : _FieldEditor(category: c, entry: entry),
    );
    if (values == null || !context.mounted) return;
    // Field editors only own their declared keys, so keep the rest; the raw
    // editor shows every key, so its result replaces the entry outright.
    final merged = c.isRaw ? {...values, ...scope} : {...?entry?.values, ...scope, ...values};
    final ok = await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).saveSetting(
            c,
            id: entry?.id,
            values: merged,
            position: all.length,
          ),
      success: 'Saved',
    );
    if (ok) ref.invalidate(_entriesProvider(categoryKey));
  }

  Future<void> _move(BuildContext context, WidgetRef ref, List<SettingEntry> sorted, int i, int dir) async {
    final key = category.orderKey!;
    final j = i + dir;
    if (j < 0 || j >= sorted.length) return;
    final reordered = [...sorted]..insert(j, sorted.removeAt(i));
    final repo = ref.read(adminRepositoryProvider);
    await runAdminAction(context, () async {
      for (var k = 0; k < reordered.length; k++) {
        final e = reordered[k];
        if (num.tryParse('${e.values[key] ?? ''}') != k + 1) {
          await repo.saveSetting(category, id: e.id, values: {...e.values, key: k + 1});
        }
      }
    });
    ref.invalidate(_entriesProvider(categoryKey));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = category;
    final canEdit = _categoryLevel(ref, c) == AccessLevel.edit;
    final entries = ref.watch(_entriesProvider(categoryKey));
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/admin/settings')),
        title: Text(parentLabel == null ? c.title : '${c.title} · $parentLabel'),
      ),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: () => _edit(context, ref, entries.value ?? []),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            )
          : null,
      body: AsyncView(
        value: entries,
        onRetry: () => ref.invalidate(_entriesProvider(categoryKey)),
        data: (all) {
          final rows = sortEntries(all.where((e) => matchesScope(e, scope)).toList(), c.orderKey);
          if (rows.isEmpty) {
            return EmptyState(icon: Icons.inbox_outlined, title: 'No ${c.title.toLowerCase()} yet', message: c.subtitle);
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final e = rows[i];
              final title = c.isRaw ? (e.values['name'] ?? e.values['title'] ?? e.id) : (e.values[c.titleKey] ?? '—');
              final sub = c.isRaw
                  ? jsonEncode(e.values)
                  : [
                      if (c.subtitleKey != null) e.values[c.subtitleKey],
                      for (final f in c.fields.where((f) => f.kind != FieldKind.text).take(3))
                        if (e.values[f.key] != null)
                          '${f.label}: ${f.kind == FieldKind.boolean ? (e.values[f.key] == true ? 'Yes' : 'No') : e.values[f.key]}',
                    ].whereType<Object>().map((v) => '$v').where((s) => s.isNotEmpty).join(' · ');
              return ListTile(
                title: Text('$title'),
                subtitle: sub.isEmpty ? null : Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: c.childCategory != null
                    ? () => context.push(Uri(
                          path: '/admin/settings/${c.childCategory}',
                          queryParameters: {...scope, c.childScopeKey!: e.id, '_label': '$title'},
                        ).toString())
                    : (canEdit ? () => _edit(context, ref, all, e) : null),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (canEdit && c.orderKey != null) ...[
                    IconButton(icon: const Icon(Icons.arrow_upward), onPressed: () => _move(context, ref, rows, i, -1)),
                    IconButton(icon: const Icon(Icons.arrow_downward), onPressed: () => _move(context, ref, rows, i, 1)),
                  ],
                  if (canEdit && c.childCategory != null)
                    IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(context, ref, all, e)),
                  if (canEdit)
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        if (!await confirm(context, 'Delete?', 'Delete "$title"?', ok: 'Delete')) return;
                        if (!context.mounted) return;
                        if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).deleteSetting(c, e.id))) {
                          ref.invalidate(_entriesProvider(categoryKey));
                        }
                      },
                    ),
                  if (c.childCategory != null) const Icon(Icons.chevron_right),
                ]),
              );
            },
          );
        },
      ),
    );
  }
}

class _FieldEditor extends StatefulWidget {
  const _FieldEditor({required this.category, this.entry});
  final SettingsCategory category;
  final SettingEntry? entry;

  @override
  State<_FieldEditor> createState() => _FieldEditorState();
}

class _FieldEditorState extends State<_FieldEditor> {
  late final Map<String, Object?> _input = {
    for (final f in widget.category.fields)
      f.key: f.kind == FieldKind.boolean
          ? widget.entry?.values[f.key] == true
          : (widget.entry?.values[f.key]?.toString() ?? ''),
  };
  String? _error;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('${widget.entry == null ? 'Add' : 'Edit'} ${widget.category.title}'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final f in widget.category.fields)
                if (f.kind == FieldKind.boolean)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(f.label),
                    value: _input[f.key] == true,
                    onChanged: (v) => setState(() => _input[f.key] = v),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextFormField(
                      initialValue: _input[f.key] as String,
                      keyboardType: f.kind == FieldKind.number
                          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
                          : TextInputType.text,
                      maxLines: f.key == 'body' || f.key == 'content' ? 5 : 1,
                      decoration: InputDecoration(labelText: '${f.label}${f.required ? ' *' : ''}'),
                      onChanged: (v) => _input[f.key] = v,
                    ),
                  ),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final r = coerceValues(widget.category.fields, _input);
              if (r.error != null) {
                setState(() => _error = r.error);
              } else {
                Navigator.pop(context, r.values);
              }
            },
            child: const Text('Save'),
          ),
        ],
      );
}

class _RawEditor extends StatefulWidget {
  const _RawEditor({this.entry});
  final SettingEntry? entry;

  @override
  State<_RawEditor> createState() => _RawEditorState();
}

class _RawEditorState extends State<_RawEditor> {
  late final _text = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert(widget.entry?.values ?? {'name': ''}),
  );
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.entry == null ? 'Add entry' : 'Edit entry'),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: _text,
              maxLines: 16,
              minLines: 8,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(helperText: 'A JSON object of this entry\'s values'),
            ),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              try {
                final v = jsonDecode(_text.text);
                if (v is! Map) throw const FormatException('Must be a JSON object');
                Navigator.pop(context, Map<String, dynamic>.from(v));
              } catch (e) {
                setState(() => _error = 'Invalid JSON: ${e is FormatException ? e.message : e}');
              }
            },
            child: const Text('Save'),
          ),
        ],
      );
}
