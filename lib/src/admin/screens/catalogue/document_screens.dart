import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/common.dart';
import '../../admin_providers.dart';
import '../../admin_settings_models.dart';
import '../../widgets/admin_widgets.dart';
import 'catalogue_data.dart';
import 'catalogue_logic.dart';
import 'catalogue_widgets.dart';

// ---------------------------------------------------------------------------
// Document Type
// ---------------------------------------------------------------------------

class DocumentTypeScreen extends ConsumerStatefulWidget {
  const DocumentTypeScreen({super.key});

  @override
  ConsumerState<DocumentTypeScreen> createState() => _DocumentTypeScreenState();
}

class _DocumentTypeScreenState extends ConsumerState<DocumentTypeScreen> {
  static const c = documentTypeCategory;
  String _query = '';

  void _refresh() => ref.invalidate(catalogueEntriesProvider(c));

  Future<void> _edit(List<SettingEntry> all, [SettingEntry? e]) async {
    final values = await openEditor<Map<String, dynamic>>(
      context,
      e == null ? 'Add Document Type' : 'Edit Document Type',
      _DocumentTypeEditor(entries: all, entry: e, canEdit: canEditPage(ref, c.page)),
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
    if (!await confirm(context, 'Delete document type', 'Remove "${str(e.values['name'])}"?', ok: 'Delete') ||
        !mounted) {
      return;
    }
    if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).deleteSetting(c, e.id), success: 'Deleted')) {
      _refresh();
    }
  }

  /// The Expo screen applies this plan silently on open; here it is an
  /// explicit, confirmed action so opening a screen never deletes rows.
  Future<void> _syncDefaults(List<SettingEntry> all) async {
    final plan = documentTypeDefaultsPlan(all);
    final parts = [
      if (plan.add.isNotEmpty) 'add ${plan.add.map((v) => v['name']).join(', ')}',
      if (plan.removeIds.isNotEmpty) 'remove ${plan.removeIds.length} legacy default type(s)',
    ];
    if (!await confirm(context, 'Restore default types', 'This will ${parts.join(' and ')}.', ok: 'Apply') || !mounted) {
      return;
    }
    final repo = ref.read(adminRepositoryProvider);
    await runAdminAction(context, () async {
      for (final id in plan.removeIds) {
        await repo.deleteSetting(c, id);
      }
      for (final v in plan.add) {
        await repo.saveSetting(c, values: v, position: 0);
      }
    }, success: 'Default types restored');
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = canEditPage(ref, c.page);
    final entries = ref.watch(catalogueEntriesProvider(c));
    final all = entries.value;
    final plan = all == null ? null : documentTypeDefaultsPlan(all);
    final needsSync = plan != null && (plan.add.isNotEmpty || plan.removeIds.isNotEmpty);
    return AdminPage(
      title: 'Document Type',
      page: c.page,
      actions: [
        if (canEdit && needsSync)
          IconButton(
            tooltip: 'Restore default types',
            icon: const Icon(Icons.settings_backup_restore),
            onPressed: () => _syncDefaults(all!),
          ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(all ?? []),
        icon: const Icon(Icons.add),
        label: const Text('Add document type'),
      ),
      body: AsyncView(
        value: entries,
        onRetry: _refresh,
        data: (all) {
          final q = _query.trim().toLowerCase();
          final rows = sortDocumentTypes(all)
              .where((e) =>
                  q.isEmpty ||
                  str(e.values['name']).toLowerCase().contains(q) ||
                  str(e.values['description']).toLowerCase().contains(q))
              .toList();
          return ResponsiveCenter(
            maxWidth: 820,
            child: Column(children: [
              CatalogueSearch(hint: 'Search document types', onChanged: (v) => setState(() => _query = v)),
              Expanded(
                child: rows.isEmpty
                    ? const EmptyState(
                        icon: Icons.inbox_outlined, title: 'No document types', message: 'Categorize required documents')
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: rows.length,
                        itemBuilder: (_, i) {
                          final e = rows[i];
                          final isDefault = jsBool(e.values['isDefault']);
                          final desc = str(e.values['description']);
                          return Card(
                            child: ListTile(
                              onTap: () => _edit(all, e),
                              leading: const Icon(Icons.badge_outlined),
                              title: Wrap(spacing: 6, children: [
                                Text(str(e.values['name'])),
                                if (isDefault) const Pill('Default', icon: Icons.verified_user_outlined),
                              ]),
                              subtitle: desc.isEmpty ? null : Text(desc),
                              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                Switch(
                                  value: jsBool(e.values['enabled'], true),
                                  onChanged: canEdit ? (_) => _toggle(e) : null,
                                ),
                                if (canEdit)
                                  IconButton(
                                    tooltip: isDefault ? 'Default types cannot be deleted' : 'Delete',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: isDefault ? null : () => _delete(e),
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

class _DocumentTypeEditor extends StatefulWidget {
  const _DocumentTypeEditor({required this.entries, this.entry, required this.canEdit});
  final List<SettingEntry> entries;
  final SettingEntry? entry;
  final bool canEdit;

  @override
  State<_DocumentTypeEditor> createState() => _DocumentTypeEditorState();
}

class _DocumentTypeEditorState extends State<_DocumentTypeEditor> {
  late final v = widget.entry?.values ?? const <String, dynamic>{};
  late final _name = TextEditingController(text: str(v['name']));
  late final _desc = TextEditingController(text: str(v['description']));
  late bool _enabled = jsBool(v['enabled'], true);
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _save() {
    final r = buildDocumentTypeValues(
      entries: widget.entries,
      editing: widget.entry,
      name: _name.text,
      description: _desc.text,
      enabled: _enabled,
    );
    if (r.error != null) return setState(() => _error = r.error);
    Navigator.pop(context, r.values);
  }

  @override
  Widget build(BuildContext context) => EditorBody(
        error: _error,
        saveLabel: widget.entry == null ? 'Add document type' : 'Save changes',
        onSave: widget.canEdit ? _save : null,
        children: [
          if (jsBool(v['isDefault']))
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Default type — name & description can be edited.'),
            ),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name *', hintText: 'e.g. Vehicle')),
          const SizedBox(height: 12),
          TextField(
            controller: _desc,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(labelText: 'Description', hintText: 'Short description'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            subtitle: const Text('Visible & selectable when assigning documents.'),
            value: _enabled,
            onChanged: (x) => setState(() => _enabled = x),
          ),
        ],
      );
}

// ---------------------------------------------------------------------------
// Required Documents
// ---------------------------------------------------------------------------

class RequiredDocumentsScreen extends ConsumerStatefulWidget {
  const RequiredDocumentsScreen({super.key});

  @override
  ConsumerState<RequiredDocumentsScreen> createState() => _RequiredDocumentsScreenState();
}

class _RequiredDocumentsScreenState extends ConsumerState<RequiredDocumentsScreen> {
  static const c = requiredDocumentsCategory;
  String _query = '';

  void _refresh() => ref.invalidate(catalogueEntriesProvider(c));

  Future<void> _edit(List<SettingEntry> all, List<SettingEntry> docTypes, [SettingEntry? e]) async {
    List<String> partnerTypes;
    List<RegionSelection> regions;
    try {
      partnerTypes = enabledPartnerTypeNames(await ref.read(catalogueEntriesProvider(partnerTypeCategory).future));
    } catch (_) {
      partnerTypes = [];
    }
    try {
      regions = await ref.read(regionOptionsProvider.future);
    } catch (_) {
      regions = [];
    }
    if (!mounted) return;
    final values = await openEditor<Map<String, dynamic>>(
      context,
      e == null ? 'Add Document' : 'Edit Document',
      _RequiredDocEditor(
        entries: all,
        entry: e,
        docTypes: enabledDocumentTypes(docTypes),
        partnerTypes: partnerTypes,
        regions: regions,
        canEdit: canEditPage(ref, c.page),
      ),
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
    final next = !jsBool(e.values['active'], true);
    if (await runAdminAction(
        context, () => ref.read(adminRepositoryProvider).saveSetting(c, id: e.id, values: {...e.values, 'active': next}))) {
      _refresh();
    }
  }

  Future<void> _delete(SettingEntry e) async {
    if (!await confirm(context, 'Delete document', 'Remove "${str(e.values['name'])}"?', ok: 'Delete') || !mounted) {
      return;
    }
    if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).deleteSetting(c, e.id), success: 'Deleted')) {
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = canEditPage(ref, c.page);
    final entries = ref.watch(catalogueEntriesProvider(c));
    final docTypes = ref.watch(catalogueEntriesProvider(documentTypeCategory)).value ?? const <SettingEntry>[];
    return AdminPage(
      title: 'Required Documents',
      page: c.page,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(entries.value ?? [], docTypes),
        icon: const Icon(Icons.add),
        label: const Text('Add document'),
      ),
      body: AsyncView(
        value: entries,
        onRetry: _refresh,
        data: (all) {
          final q = _query.trim().toLowerCase();
          final rows = [...all]..sort((a, b) => str(a.values['name']).compareTo(str(b.values['name'])));
          final visible = rows
              .where((e) =>
                  q.isEmpty ||
                  str(e.values['name']).toLowerCase().contains(q) ||
                  str(e.values['description']).toLowerCase().contains(q))
              .toList();
          return ResponsiveCenter(
            maxWidth: 820,
            child: Column(children: [
              CatalogueSearch(hint: 'Search documents', onChanged: (v) => setState(() => _query = v)),
              Expanded(
                child: visible.isEmpty
                    ? const EmptyState(
                        icon: Icons.inbox_outlined, title: 'No required documents', message: 'Partner onboarding docs')
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: visible.length,
                        itemBuilder: (_, i) => _row(visible[i], all, docTypes, canEdit),
                      ),
              ),
            ]),
          );
        },
      ),
    );
  }

  Widget _row(SettingEntry e, List<SettingEntry> all, List<SettingEntry> docTypes, bool canEdit) {
    final v = e.values;
    final types = docTypeLabels(parseLooseList(v['docTypes']), docTypes);
    final pTypes = parseLooseList(v['partnerTypes']);
    final partnerLabels = pTypes.contains(allToken) ? ['All partner types'] : pTypes;
    final summary = regionSummary(v);
    Iterable<Widget> tags(List<String> l) => [
          for (final t in l.take(5)) Pill(t),
          if (l.length > 5) Pill('+${l.length - 5}'),
        ];
    return Card(
      child: ListTile(
        onTap: () => _edit(all, docTypes, e),
        leading: const Icon(Icons.fact_check_outlined),
        title: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(str(v['name'])),
          StatusChip(jsBool(v['required'], true) ? 'Required' : 'Optional'),
          StatusChip(jsBool(v['active'], true) ? 'Active' : 'Not active'),
        ]),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (str(v['description']).isNotEmpty) Text(str(v['description'])),
          const SizedBox(height: 4),
          Wrap(spacing: 4, runSpacing: 4, children: [
            Pill(summary, icon: summary == 'Global' ? Icons.public : Icons.place_outlined),
            ...tags(types),
            ...tags(partnerLabels),
          ]),
        ]),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Switch(value: jsBool(v['active'], true), onChanged: canEdit ? (_) => _toggle(e) : null),
          if (canEdit) IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(e)),
        ]),
      ),
    );
  }
}

class _RequiredDocEditor extends StatefulWidget {
  const _RequiredDocEditor({
    required this.entries,
    this.entry,
    required this.docTypes,
    required this.partnerTypes,
    required this.regions,
    required this.canEdit,
  });
  final List<SettingEntry> entries;
  final SettingEntry? entry;
  final List<SettingEntry> docTypes;
  final List<String> partnerTypes;
  final List<RegionSelection> regions;
  final bool canEdit;

  @override
  State<_RequiredDocEditor> createState() => _RequiredDocEditorState();
}

class _RequiredDocEditorState extends State<_RequiredDocEditor> {
  late final RequiredDocForm f =
      widget.entry == null ? RequiredDocForm() : RequiredDocForm.fromValues(widget.entry!.values);
  late final _name = TextEditingController(text: f.name);
  late final _desc = TextEditingController(text: f.description);
  String _regionFilter = '';
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _save() {
    f
      ..name = _name.text
      ..description = _desc.text;
    final r = buildRequiredDocValues(entries: widget.entries, editing: widget.entry, form: f);
    if (r.error != null) return setState(() => _error = r.error);
    Navigator.pop(context, r.values);
  }

  Widget _regionPicker() {
    final q = _regionFilter.trim().toLowerCase();
    final options = widget.regions.where((r) => q.isEmpty || r.label.toLowerCase().contains(q)).toList();
    final selectedKeys = f.regions.map((r) => r.key).toSet();
    Widget group(String title, String type, String empty) {
      final list = options.where((r) => r.type == type).toList();
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionLabel('$title (${list.length})'),
        if (list.isEmpty)
          Text(empty)
        else
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final r in list)
              FilterChip(
                avatar: Icon(type == 'country' ? Icons.public : Icons.place_outlined, size: 16),
                label: Text(r.label),
                selected: selectedKeys.contains(r.key),
                onSelected: (_) => setState(() => f.toggleRegion(r)),
              ),
          ]),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search countries / states', isDense: true),
        onChanged: (s) => setState(() => _regionFilter = s),
      ),
      if (f.regions.isNotEmpty) ...[
        SectionLabel('Selected (${f.regions.length})', hint: 'Tap to cycle compulsory / optional • remove with ×'),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final r in f.regions)
            InputChip(
              avatar: Icon(r.type == 'country' ? Icons.public : Icons.place_outlined, size: 16),
              label: Text('${r.label} · ${r.compulsory ? 'Compulsory' : 'Optional'}'),
              selected: r.compulsory,
              onPressed: () => setState(() => f.cycleRegionCompulsory(r.key)),
              onDeleted: () => setState(() => f.toggleRegion(r)),
            ),
        ]),
      ],
      group('Countries', 'country', 'No countries found. Add them in Country / States / Cities.'),
      group('States', 'state', 'No states found.'),
    ]);
  }

  @override
  Widget build(BuildContext context) => EditorBody(
        error: _error,
        saveLabel: widget.entry == null ? 'Add document' : 'Save changes',
        onSave: widget.canEdit ? _save : null,
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name *', hintText: 'e.g. Driving License')),
          const SizedBox(height: 12),
          TextField(
            controller: _desc,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(labelText: 'Description', hintText: 'Short description'),
          ),
          const SectionLabel('Document Type *', hint: 'Choose "All" or pick multiple'),
          AllTokenChips(
            options: {for (final d in widget.docTypes) d.id: str(d.values['name'])},
            selected: f.docTypes,
            emptyText: 'No document types yet. Add some in Document Type settings.',
            onChanged: (l) => setState(() => f.docTypes = l),
          ),
          const SectionLabel('Partner Types *', hint: 'Choose "All" or pick specific partner types'),
          AllTokenChips(
            options: {for (final n in widget.partnerTypes) n: n},
            selected: f.partnerTypes,
            emptyText: 'No partner types yet. Add some in Partner Type settings.',
            onChanged: (l) => setState(() => f.partnerTypes = l),
          ),
          const SectionLabel('Applies to *'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.public),
            title: const Text('All country & state (Global)'),
            subtitle: Text(f.regionsGlobal ? 'Applies everywhere' : 'Pick specific countries / states below'),
            value: f.regionsGlobal,
            onChanged: (x) => setState(() => f.regionsGlobal = x),
          ),
          if (f.regionsGlobal)
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Compulsory')),
                  ButtonSegment(value: false, label: Text('Optional')),
                ],
                selected: {f.regionsGlobalCompulsory},
                onSelectionChanged: (s) => setState(() => f.regionsGlobalCompulsory = s.first),
              ),
            )
          else
            _regionPicker(),
          const SectionLabel('Upload Requirements', hint: 'Fields partners must fill at every upload'),
          for (final o in requiredDocOptions)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(o.title),
              subtitle: Text(o.desc),
              value: f.options[o.key] ?? false,
              onChanged: (x) => setState(() => f.options[o.key] = x),
            ),
          const SectionLabel('Taxi Driver Permit', hint: 'For partner-teksi driver permit'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Taxi Driver Permit display'),
            subtitle: const Text(
                'When on, this document is treated as the taxi driver permit. The uploaded image is scanned to capture: '
                'ID Number, Validity From & To, Driver Type, Licence Reference Number, Vehicle Number, Licence Class, '
                'Company Name, Address, Image on Permit and QR Code.'),
            value: f.isTaxiPermit,
            onChanged: (x) => setState(() => f.isTaxiPermit = x),
          ),
          const Divider(),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Default Required'),
            subtitle: Text(f.required ? 'Compulsory for partners' : 'Optional for partners'),
            value: f.required,
            onChanged: (x) => setState(() => f.required = x),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Status'),
            subtitle: Text(f.active ? 'Active — visible to partners' : 'Not active — hidden'),
            value: f.active,
            onChanged: (x) => setState(() => f.active = x),
          ),
        ],
      );
}
