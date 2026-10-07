import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_providers.dart';
import '../../admin_settings_models.dart';
import '../../widgets/admin_widgets.dart';
import 'catalogue_data.dart';
import 'catalogue_logic.dart';
import 'catalogue_widgets.dart';

const _page = 'admin-settings-partner-type';

class PartnerTypeScreen extends ConsumerStatefulWidget {
  const PartnerTypeScreen({super.key});

  @override
  ConsumerState<PartnerTypeScreen> createState() => _PartnerTypeScreenState();
}

class _PartnerTypeScreenState extends ConsumerState<PartnerTypeScreen> {
  String _query = '';
  final _expanded = <String>{};

  static const c = partnerTypeCategory;

  void _refresh() => ref.invalidate(catalogueEntriesProvider(c));

  Future<void> _edit(List<SettingEntry> all, [SettingEntry? e]) async {
    List<SettingEntry> docTypes;
    try {
      docTypes = enabledDocumentTypes(await ref.read(catalogueEntriesProvider(documentTypeCategory).future));
    } catch (_) {
      docTypes = [];
    }
    if (!mounted) return;
    final values = await openEditor<Map<String, dynamic>>(
      context,
      e == null ? 'Add Partner Type' : 'Edit Partner Type',
      _PartnerTypeEditor(entries: all, entry: e, docTypes: docTypes, canEdit: canEditPage(ref, _page)),
    );
    if (values == null || !mounted) return;
    if (await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).saveSetting(c, id: e?.id, values: values, position: 0),
      success: 'Saved',
    )) {
      _refresh();
    }
  }

  Future<void> _toggle(SettingEntry e) async {
    final next = !jsBool(e.values['enabled'], true);
    if (await runAdminAction(
        context, () => ref.read(adminRepositoryProvider).saveSetting(c, id: e.id, values: {...e.values, 'enabled': next}))) {
      _refresh();
    }
  }

  Future<void> _delete(SettingEntry e) async {
    if (jsBool(e.values['isDefault'])) {
      showInfo(context, 'Default partner types cannot be deleted, only edited.');
      return;
    }
    if (!await confirm(context, 'Delete partner type', 'Remove "${str(e.values['name'])}"?', ok: 'Delete') || !mounted) {
      return;
    }
    if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).deleteSetting(c, e.id), success: 'Deleted')) {
      _refresh();
    }
  }

  Future<void> _move(List<SettingEntry> sorted, int i, int dir) async {
    final changes = reorderPriorities(sorted, i, dir);
    final repo = ref.read(adminRepositoryProvider);
    await runAdminAction(context, () async {
      for (final e in sorted) {
        final p = changes[e.id];
        if (p != null) await repo.saveSetting(c, id: e.id, values: {...e.values, 'displayPriority': p});
      }
    });
    _refresh();
  }

  Widget _preview(List<SubService> list, int depth) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final n in list) ...[
            Padding(
              padding: EdgeInsets.only(left: 12.0 * depth, top: 2, bottom: 2),
              child: Row(children: [
                Icon(Icons.circle, size: 6, color: n.enabled ? null : Theme.of(context).disabledColor),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(n.name,
                      style: TextStyle(decoration: n.enabled ? null : TextDecoration.lineThrough),
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
            ),
            if (n.children.isNotEmpty) _preview(n.children, depth + 1),
          ],
        ],
      );

  @override
  Widget build(BuildContext context) {
    final canEdit = canEditPage(ref, _page);
    final entries = ref.watch(catalogueEntriesProvider(c));
    return AdminPage(
      title: 'Partner Type',
      page: _page,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(entries.value ?? []),
        icon: const Icon(Icons.add),
        label: const Text('Add partner type'),
      ),
      body: AsyncView(
        value: entries,
        onRetry: _refresh,
        data: (all) {
          final sorted = sortByPriority(all, byName: true);
          final rows = sorted.where((e) => partnerTypeMatches(e, _query)).toList();
          final searching = _query.trim().isNotEmpty;
          return ResponsiveCenter(
            maxWidth: 820,
            child: Column(children: [
              CatalogueSearch(
                hint: 'Search partner types or sub-services',
                onChanged: (v) => setState(() => _query = v),
              ),
              Expanded(
                child: rows.isEmpty
                    ? const EmptyState(icon: Icons.inbox_outlined, title: 'No partner types', message: 'Categories & nested sub-services')
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: rows.length,
                        itemBuilder: (_, i) {
                          final e = rows[i];
                          final v = e.values;
                          final tree = parseSubServiceTree(v['subServicesJson']);
                          final count = countSubServices(tree);
                          final subOn = jsBool(v['subServicesEnabled']);
                          final isDefault = jsBool(v['isDefault']);
                          final p = v['displayPriority'];
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Column(children: [
                                Row(children: [
                                  if (canEdit)
                                    ReorderButtons(
                                      onUp: searching || i == 0 ? null : () => _move(sorted, i, -1),
                                      onDown: searching || i == rows.length - 1 ? null : () => _move(sorted, i, 1),
                                    )
                                  else
                                    const SizedBox(width: 12),
                                  Expanded(
                                    child: BusyListTile(
                                      contentPadding: EdgeInsets.zero,
                                      onTap: () => _edit(all, e),
                                      leading: StoredImage(str(v['iconUrl']).trim(), fallback: Icons.groups_outlined),
                                      title: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                                        Text(str(v['name'])),
                                        Pill(p == null || '$p' == '' ? '-' : '$p', icon: Icons.format_list_numbered),
                                        if (isDefault) const Pill('Default', icon: Icons.verified_user_outlined),
                                      ]),
                                      subtitle: Text(subOn
                                          ? '$count sub-service${count == 1 ? '' : 's'} • up to $maxSubServiceDepth levels'
                                          : 'Sub-services off'),
                                    ),
                                  ),
                                  BusySwitch(value: jsBool(v['enabled'], true), onChanged: canEdit ? (_) => _toggle(e) : null),
                                  if (subOn && count > 0)
                                    IconButton(
                                      tooltip: _expanded.contains(e.id) ? 'Hide sub-services' : 'View sub-services',
                                      icon: Icon(_expanded.contains(e.id) ? Icons.expand_less : Icons.expand_more),
                                      onPressed: () => setState(() =>
                                          _expanded.contains(e.id) ? _expanded.remove(e.id) : _expanded.add(e.id)),
                                    ),
                                  if (canEdit)
                                    BusyIconButton(
                                      tooltip: isDefault ? 'Default types cannot be deleted' : 'Delete',
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: isDefault ? null : () => _delete(e),
                                    ),
                                ]),
                                if (_expanded.contains(e.id) && subOn && count > 0)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
                                    child: Align(alignment: Alignment.centerLeft, child: _preview(tree, 0)),
                                  ),
                              ]),
                            ),
                          );
                        },
                      ),
              ),
            ]),
          );
        },
      ),
    );
  }
}

class _PartnerTypeEditor extends ConsumerStatefulWidget {
  const _PartnerTypeEditor({required this.entries, this.entry, required this.docTypes, required this.canEdit});
  final List<SettingEntry> entries;
  final SettingEntry? entry;
  final List<SettingEntry> docTypes;
  final bool canEdit;

  @override
  ConsumerState<_PartnerTypeEditor> createState() => _PartnerTypeEditorState();
}

class _PartnerTypeEditorState extends ConsumerState<_PartnerTypeEditor> {
  late final v = widget.entry?.values ?? const <String, dynamic>{};
  late final _name = TextEditingController(text: str(v['name']));
  late final _info = TextEditingController(text: str(v['shortInfo']));
  late String _icon = str(v['iconUrl']);
  late bool _enabled = jsBool(v['enabled'], true);
  late bool _subOn = jsBool(v['subServicesEnabled']);
  late bool _vehicle = jsBool(v['vehicleRequired']);
  late List<SubService> _tree = parseSubServiceTree(v['subServicesJson']);
  late List<String> _docTypes = parsePartnerDocTypes(v['docTypes']);
  bool _uploading = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _info.dispose();
    super.dispose();
  }

  Future<void> _pickIcon() async {
    try {
      final f = await pickImageFile();
      if (f == null) return;
      setState(() => _uploading = true);
      final url = await ref.read(catalogueRepositoryProvider).uploadPartnerTypeIcon(f.bytes, f.name);
      if (mounted) setState(() => _icon = url);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<String?> _askName(String title, [String initial = '']) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Sub-service name'),
          onSubmitted: (s) => Navigator.pop(ctx, s),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
        ],
      ),
    ).whenComplete(ctrl.dispose);
  }

  Future<void> _add(List<int> parentPath) async {
    final name = await _askName('Add sub-service');
    if (name != null) setState(() => _tree = addSubService(_tree, parentPath, name));
  }

  Future<void> _rename(List<int> path, String current) async {
    final name = await _askName('Rename sub-service', current);
    if (name != null) setState(() => _tree = renameSubService(_tree, path, name));
  }

  List<Widget> _nodes(List<SubService> list, List<int> parent) => [
        for (var i = 0; i < list.length; i++) ...[
          Padding(
            padding: EdgeInsets.only(left: 16.0 * parent.length),
            child: Row(children: [
              Expanded(child: Text(list[i].name, overflow: TextOverflow.ellipsis)),
              Switch(
                value: list[i].enabled,
                onChanged: (_) => setState(() => _tree = toggleSubService(_tree, [...parent, i])),
              ),
              IconButton(
                tooltip: 'Rename',
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: () => _rename([...parent, i], list[i].name),
              ),
              if (canAddSubServiceChild([...parent, i]))
                IconButton(
                  tooltip: 'Add child',
                  icon: const Icon(Icons.add, size: 20),
                  onPressed: () => _add([...parent, i]),
                ),
              IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () => setState(() => _tree = removeSubService(_tree, [...parent, i])),
              ),
            ]),
          ),
          ..._nodes(list[i].children, [...parent, i]),
        ],
      ];

  void _save() {
    final r = buildPartnerTypeValues(
      entries: widget.entries,
      editing: widget.entry,
      name: _name.text,
      shortInfo: _info.text,
      iconUrl: _icon,
      enabled: _enabled,
      subServicesEnabled: _subOn,
      vehicleRequired: _vehicle,
      tree: _tree,
      docTypes: _docTypes,
    );
    if (r.error != null) return setState(() => _error = r.error);
    Navigator.pop(context, r.values);
  }

  @override
  Widget build(BuildContext context) => EditorBody(
        error: _error,
        saveLabel: widget.entry == null ? 'Add partner type' : 'Save changes',
        onSave: widget.canEdit && !_uploading ? _save : null,
        children: [
          if (jsBool(v['isDefault']))
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Default type — name & sub-services can be edited.'),
            ),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name *', hintText: 'Partner type name')),
          const SizedBox(height: 12),
          TextField(
            controller: _info,
            maxLength: shortInfoMax,
            maxLines: 3,
            minLines: 2,
            decoration: const InputDecoration(
              labelText: 'Short Information (optional)',
              hintText: 'Shown as subtitle in the Select your service popup',
              helperText: 'Appears below the partner type name when users pick a service.',
            ),
          ),
          const SectionLabel('Icon (optional)', hint: 'Square image. Shown globally in the "Select your service" popup.'),
          Row(children: [
            _uploading
                ? const SizedBox(width: 56, height: 56, child: Center(child: CircularProgressIndicator()))
                : StoredImage(_icon, size: 56, fallback: Icons.add_photo_alternate_outlined),
            const SizedBox(width: 12),
            BusyButton.tonal(
              onPressed: _uploading ? null : _pickIcon,
              icon: const Icon(Icons.upload),
              child: Text(_icon.isEmpty ? 'Upload' : 'Replace'),

            ),
            const SizedBox(width: 8),
            if (_icon.isNotEmpty)
              OutlinedButton(onPressed: _uploading ? null : () => setState(() => _icon = ''), child: const Text('Remove')),
          ]),
          const SectionLabel('Document Types', hint: 'Choose "All" or pick multiple'),
          AllTokenChips(
            options: {for (final d in widget.docTypes) d.id: str(d.values['name'])},
            selected: _docTypes,
            emptyText: 'No document types yet. Add some in Document Type settings.',
            onChanged: (l) => setState(() => _docTypes = l),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            subtitle: const Text('Visible & selectable in the app.'),
            value: _enabled,
            onChanged: (x) => setState(() => _enabled = x),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Vehicle required'),
            subtitle: const Text('Partners of this type must register a vehicle.'),
            value: _vehicle,
            onChanged: (x) => setState(() => _vehicle = x),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sub-services'),
            subtitle: const Text('Organize offerings up to $maxSubServiceDepth levels deep.'),
            value: _subOn,
            onChanged: (x) => setState(() => _subOn = x),
          ),
          if (_subOn) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: () => _add(const []), icon: const Icon(Icons.add), label: const Text('Add level 1')),
            ),
            if (_tree.isEmpty) const Text('No sub-services yet. Tap "Add level 1" to get started.'),
            ..._nodes(_tree, const []),
            const SizedBox(height: 12),
          ],
        ],
      );
}
