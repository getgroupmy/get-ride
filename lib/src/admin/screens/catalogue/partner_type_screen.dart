import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_providers.dart';
import '../../admin_settings_models.dart';
import '../../widgets/admin_widgets.dart';
import 'catalogue_data.dart';
import 'catalogue_logic.dart';
import 'catalogue_widgets.dart';
import 'partner_service_settings_editor.dart';
import 'partner_type_rules_editor.dart';
import 'partner_type_services_screen.dart' show partnerTypeServicesPath;
import '../../../core/partner_modes.dart' show defaultVehicleRequired;
import '../../../core/partner_type_rules.dart';
import '../../../widgets/page_style_host.dart';
import '../../../core/media_assets.dart' show MediaKind;
import '../meterapp/media_picker_sheet.dart' show MediaStore, showMediaPicker;

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
      e == null ? 'Add Partner Service type' : 'Edit Partner Service type',
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
      showInfo(context, 'Default Partner Service types cannot be deleted, only edited.');
      return;
    }
    if (!await confirm(context, 'Delete Partner Service type', 'Remove "${str(e.values['name'])}"?', ok: 'Delete') || !mounted) {
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
      title: 'Partner Service type',
      page: _page,
      actions: [
        IconButton(
          key: const ValueKey('partner-type-services-link'),
          tooltip: 'Services each type sees',
          icon: const Icon(Icons.rule_outlined),
          onPressed: () => context.push(partnerTypeServicesPath),
        ),
      ],
      addAction: PageAddAction(
        onPressed: () => _edit(entries.value ?? []),
        icon: const Icon(Icons.add),
        label: const Text('Add Partner Service type'),
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
                hint: 'Search Partner Service types or sub-services',
                onChanged: (v) => setState(() => _query = v),
              ),
              Expanded(
                child: rows.isEmpty
                    ? const EmptyState(icon: Icons.inbox_outlined, title: 'No Partner Service types', message: 'Categories & nested sub-services')
                    : ListView.builder(
                        padding: EdgeInsets.only(bottom: addActionListBottomPadding(context)),
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
  // Unset: the default the driver app and the server use (teksi, eHailing
  // and pHailing need one).
  late bool _vehicle =
      v.containsKey('vehicleRequired') ? jsBool(v['vehicleRequired']) : defaultVehicleRequired(str(v['name']));
  late List<SubService> _tree = parseSubServiceTree(v['subServicesJson']);
  late List<String> _docTypes = parsePartnerDocTypes(v['docTypes']);
  late PartnerTypeRules _rules = PartnerTypeRules.fromValues(v);
  bool _rulesTouched = false;
  late PartnerServiceSettings _settings = PartnerServiceSettings.fromValues(v);
  bool _settingsTouched = false;
  bool _tried = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _info.dispose();
    super.dispose();
  }

  /// From the Media Gallery (or uploaded there). Kept as the file's web
  /// address: driver apps already installed load `iconUrl` as it is.
  Future<void> _pickIcon() async {
    final v = await showMediaPicker(
      context,
      kind: MediaKind.icon,
      alsoKinds: const {MediaKind.image, MediaKind.logo},
      current: _icon,
      title: 'Partner Service type icon',
      offerDefault: false,
      builtIns: false,
      store: MediaStore.url,
    );
    if (v != null && v.isNotEmpty && mounted) setState(() => _icon = v);
  }

  Future<String?> _askName(String title, [String initial = '']) {
    final ctrl = TextEditingController(text: initial);
    return showAppDialog<String>(id: 'partner-type.ask-name',
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
      // Untouched rules on an entry that never had any are left unset
      // (today's behaviour), not written out as defaults.
      rules: _rulesTouched || v['rules'] != null ? _rules : null,
      // The same for the registration settings: untouched, kept as stored.
      settings: _settingsTouched ? _settings : null,
    );
    if (r.error != null) {
      return setState(() {
        _error = r.error;
        _tried = true;
      });
    }
    Navigator.pop(context, r.values);
  }

  @override
  Widget build(BuildContext context) => EditorBody(
        error: _error,
        saveLabel: widget.entry == null ? 'Add Partner Service type' : 'Save changes',
        onSave: widget.canEdit ? _save : null,
        children: [
          if (jsBool(v['isDefault']))
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Default type — name & sub-services can be edited.'),
            ),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name *', hintText: 'Partner Service type name')),
          const SizedBox(height: 12),
          TextField(
            controller: _info,
            maxLength: shortInfoMax,
            maxLines: 3,
            minLines: 2,
            decoration: const InputDecoration(
              labelText: 'Short Information (optional)',
              hintText: 'Shown as subtitle in the Select your service popup',
              helperText: 'Appears below the Partner Service type name when users pick a service.',
            ),
          ),
          const SectionLabel('Icon (optional)', hint: 'Square image. Shown globally in the "Select your service" popup.'),
          Row(children: [
            StoredImage(_icon, size: 56, fallback: Icons.add_photo_alternate_outlined),
            const SizedBox(width: 12),
            BusyButton.tonal(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: _pickIcon,
              icon: const Icon(Icons.photo_library_outlined),
              child: Text(_icon.isEmpty ? 'Choose' : 'Replace'),

            ),
            const SizedBox(width: 8),
            if (_icon.isNotEmpty)
              OutlinedButton(onPressed: () => setState(() => _icon = ''), child: const Text('Remove')),
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
            title: const Text('Vehicle service: partners must register a vehicle'),
            subtitle: const Text('Registration asks for the vehicle, its documents and its permits.'),
            value: _vehicle,
            onChanged: (x) => setState(() => _vehicle = x),
          ),
          PartnerTypeRulesEditor(
            rules: _rules,
            vehicleRequired: _vehicle,
            isTeksi: partnerTypeNameKey(_name.text) == 'teksi',
            showErrors: _tried,
            onChanged: (r) => setState(() {
              _rules = r;
              _rulesTouched = true;
            }),
          ),
          PartnerServiceSettingsEditor(
            settings: _settings,
            vehicleRequired: _vehicle,
            ageRequired: _rules.ageRequired,
            otherTypes: [
              for (final e in sortByPriority(widget.entries, byName: true))
                if (e.id != widget.entry?.id && str(e.values['name']).trim().isNotEmpty) str(e.values['name']).trim(),
            ],
            onChanged: (x) => setState(() {
              _settings = x;
              _settingsTouched = true;
            }),
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
