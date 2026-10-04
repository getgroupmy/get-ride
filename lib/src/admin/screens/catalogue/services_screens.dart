import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/common.dart';
import '../../admin_providers.dart';
import '../../admin_settings_models.dart';
import '../../widgets/admin_widgets.dart';
import 'catalogue_data.dart';
import 'catalogue_logic.dart';
import 'catalogue_widgets.dart';

/// Shared list for the two `displayPriority`-ordered service categories.
class _PriorityList extends ConsumerStatefulWidget {
  const _PriorityList({
    required this.category,
    required this.title,
    required this.emptyTitle,
    required this.addLabel,
    required this.tile,
    required this.edit,
    required this.isDefault,
    required this.deleteMessage,
  });

  final SettingsCategory category;
  final String title;
  final String emptyTitle;
  final String addLabel;
  final Widget Function(SettingEntry e) tile;
  final Future<void> Function(BuildContext, List<SettingEntry> all, SettingEntry? e) edit;
  final bool Function(SettingEntry e) isDefault;
  final String deleteMessage;

  @override
  ConsumerState<_PriorityList> createState() => _PriorityListState();
}

class _PriorityListState extends ConsumerState<_PriorityList> {
  String _query = '';

  SettingsCategory get c => widget.category;

  Future<void> _move(List<SettingEntry> sorted, int i, int dir) async {
    final changes = reorderPriorities(sorted, i, dir);
    final repo = ref.read(adminRepositoryProvider);
    await runAdminAction(context, () async {
      for (final e in sorted) {
        final p = changes[e.id];
        if (p != null) await repo.saveSetting(c, id: e.id, values: {...e.values, 'displayPriority': p});
      }
    });
    ref.invalidate(catalogueEntriesProvider(c));
  }

  Future<void> _delete(SettingEntry e) async {
    if (widget.isDefault(e)) {
      showInfo(context, 'Default entries cannot be deleted. You can edit them instead.');
      return;
    }
    if (!await confirm(context, 'Delete', widget.deleteMessage, ok: 'Delete') || !mounted) return;
    if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).deleteSetting(c, e.id),
        success: 'Deleted')) {
      ref.invalidate(catalogueEntriesProvider(c));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = canEditPage(ref, c.page);
    final entries = ref.watch(catalogueEntriesProvider(c));
    return AdminPage(
      title: widget.title,
      page: c.page,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => widget.edit(context, entries.value ?? [], null),
        icon: const Icon(Icons.add),
        label: Text(widget.addLabel),
      ),
      body: AsyncView(
        value: entries,
        onRetry: () => ref.invalidate(catalogueEntriesProvider(c)),
        data: (all) {
          final sorted = sortByPriority(all);
          final rows = sorted.where((e) => entryMatches(e, _query)).toList();
          final searching = _query.trim().isNotEmpty;
          return ResponsiveCenter(
            maxWidth: 820,
            child: Column(children: [
              CatalogueSearch(onChanged: (v) => setState(() => _query = v)),
              Expanded(
                child: rows.isEmpty
                    ? EmptyState(icon: Icons.inbox_outlined, title: widget.emptyTitle, message: c.subtitle)
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: rows.length,
                        itemBuilder: (_, i) {
                          final e = rows[i];
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(children: [
                                if (canEdit)
                                  ReorderButtons(
                                    onUp: searching || i == 0 ? null : () => _move(sorted, i, -1),
                                    onDown: searching || i == rows.length - 1 ? null : () => _move(sorted, i, 1),
                                  )
                                else
                                  const SizedBox(width: 12),
                                Expanded(
                                  child: InkWell(
                                    onTap: () => widget.edit(context, all, e),
                                    child: widget.tile(e),
                                  ),
                                ),
                                if (canEdit)
                                  IconButton(
                                    tooltip: widget.isDefault(e) ? 'Default entries cannot be deleted' : 'Delete',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: widget.isDefault(e) ? null : () => _delete(e),
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

Future<void> _saveEntry(
    BuildContext context, WidgetRef ref, SettingsCategory c, SettingEntry? editing, Map<String, dynamic> values) async {
  final ok = await runAdminAction(
    context,
    () => ref.read(adminRepositoryProvider).saveSetting(c, id: editing?.id, values: values, position: 0),
    success: 'Saved',
  );
  if (ok) ref.invalidate(catalogueEntriesProvider(c));
}

// ---------------------------------------------------------------------------
// Service Settings
// ---------------------------------------------------------------------------

class ServiceSettingsScreen extends ConsumerWidget {
  const ServiceSettingsScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, List<SettingEntry> all, SettingEntry? e) async {
    final values = await openEditor<Map<String, dynamic>>(
      context,
      e == null ? 'Add Service' : 'Edit Service',
      _ServiceEditor(entry: e, count: all.length, canEdit: canEditPage(ref, serviceSettingsCategory.page)),
    );
    if (values != null && context.mounted) await _saveEntry(context, ref, serviceSettingsCategory, e, values);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => _PriorityList(
        category: serviceSettingsCategory,
        title: 'Service Settings',
        emptyTitle: 'No services yet',
        addLabel: 'Add Service',
        deleteMessage: 'Remove this service?',
        isDefault: (e) => jsBool(e.values['isDefault']),
        edit: (ctx, all, e) => _edit(ctx, ref, all, e),
        tile: (e) {
          final v = e.values;
          final p = v['displayPriority'];
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: StoredImage(str(v['iconUri']), fallback: Icons.build_outlined),
            title: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(str(v['name']).isEmpty ? 'Untitled' : str(v['name'])),
              Pill(p == null || '$p' == '' ? '-' : '$p', icon: Icons.format_list_numbered),
              if (jsBool(v['isDefault'])) const Pill('Default', icon: Icons.lock_outline),
            ]),
            subtitle: Text([
              if (str(v['description']).isNotEmpty) str(v['description']),
              jsBool(v['active'], true) ? 'Active' : 'Inactive',
            ].join('\n')),
          );
        },
      );
}

class _ServiceEditor extends StatefulWidget {
  const _ServiceEditor({this.entry, required this.count, required this.canEdit});
  final SettingEntry? entry;
  final int count;
  final bool canEdit;

  @override
  State<_ServiceEditor> createState() => _ServiceEditorState();
}

class _ServiceEditorState extends State<_ServiceEditor> {
  late final v = widget.entry?.values ?? const <String, dynamic>{};
  late final _name = TextEditingController(text: str(v['name']));
  late final _desc = TextEditingController(text: str(v['description']));
  late final _priority = TextEditingController(
      text: widget.entry == null ? '${widget.count + 1}' : str(v['displayPriority']));
  late String _icon = str(v['iconUri']);
  late bool _active = jsBool(v['active'], true);
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _priority.dispose();
    super.dispose();
  }

  void _save() {
    final r = buildServiceValues(
      name: _name.text,
      description: _desc.text,
      iconUri: _icon,
      priorityText: _priority.text,
      active: _active,
      entryCount: widget.count,
      editing: widget.entry?.values,
    );
    if (r.error != null) return setState(() => _error = r.error);
    Navigator.pop(context, r.values);
  }

  @override
  Widget build(BuildContext context) => EditorBody(
        error: _error,
        saveLabel: widget.entry == null ? 'Add Service' : 'Save changes',
        onSave: widget.canEdit ? _save : null,
        children: [
          DataUrlImageField(label: 'Icon', value: _icon, onChanged: (u) => setState(() => _icon = u)),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Service Name *', hintText: 'e.g. Car')),
          const SizedBox(height: 12),
          TextField(controller: _desc, decoration: const InputDecoration(labelText: 'Description')),
          const SizedBox(height: 12),
          TextField(
            controller: _priority,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Display Priority'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Active'),
            value: _active,
            onChanged: (x) => setState(() => _active = x),
          ),
          if (jsBool(v['isDefault']))
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.lock_outline),
              title: Text('This is a default service. It can be edited but not deleted.'),
            ),
        ],
      );
}

// ---------------------------------------------------------------------------
// Vehicle Services
// ---------------------------------------------------------------------------

class VehicleServicesScreen extends ConsumerWidget {
  const VehicleServicesScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, List<SettingEntry> all, SettingEntry? e) async {
    List<String> options;
    try {
      options = serviceTypeOptions(await ref.read(catalogueEntriesProvider(serviceSettingsCategory).future));
    } catch (_) {
      options = [];
    }
    if (!context.mounted) return;
    final values = await openEditor<Map<String, dynamic>>(
      context,
      e == null ? 'Add Vehicle Service' : 'Edit Vehicle Service',
      _VehicleServiceEditor(
        entry: e,
        count: all.length,
        serviceTypes: options,
        canEdit: canEditPage(ref, vehicleServicesCategory.page),
      ),
    );
    if (values != null && context.mounted) await _saveEntry(context, ref, vehicleServicesCategory, e, values);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => _PriorityList(
        category: vehicleServicesCategory,
        title: 'Vehicle Services',
        emptyTitle: 'No vehicle services yet',
        addLabel: 'Add Vehicle Service',
        deleteMessage: 'Remove this vehicle service?',
        isDefault: (_) => false,
        edit: (ctx, all, e) => _edit(ctx, ref, all, e),
        tile: (e) {
          final v = e.values;
          final p = v['displayPriority'];
          final meta = vehicleServiceMeta(v);
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: StoredImage(str(v['iconUri']), fallback: Icons.layers_outlined),
            title: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(str(v['name']).isEmpty ? 'Untitled' : str(v['name'])),
              Pill(p == null || '$p' == '' ? '-' : '$p', icon: Icons.format_list_numbered),
              StatusChip(jsBool(v['status'], true) ? 'Active' : 'Inactive'),
            ]),
            subtitle: meta.isEmpty ? null : Text(meta),
          );
        },
      );
}

class _VehicleServiceEditor extends StatefulWidget {
  const _VehicleServiceEditor({this.entry, required this.count, required this.serviceTypes, required this.canEdit});
  final SettingEntry? entry;
  final int count;
  final List<String> serviceTypes;
  final bool canEdit;

  @override
  State<_VehicleServiceEditor> createState() => _VehicleServiceEditorState();
}

class _VehicleServiceEditorState extends State<_VehicleServiceEditor> {
  late final v = widget.entry?.values ?? const <String, dynamic>{};
  late final _text = {
    for (final k in ['name', 'description', 'shortDescription']) k: TextEditingController(text: str(v[k])),
  };
  late final _numbers = {
    for (final f in vehicleServiceNumberFields)
      f.key: TextEditingController(
        text: widget.entry == null
            ? (f.key == 'displayPriority' ? '${widget.count + 1}' : '')
            : (v[f.key] == null ? '' : '${v[f.key]}'),
      ),
  };
  late final _images = {for (final k in ['iconUri', 'heroImageUri', 'mapIconUri']) k: str(v[k])};
  late String _color = str(v['mapIconColor']);
  late List<String> _serviceTypes = stringList(v['serviceTypes']);
  late List<String> _fuel = stringList(v['fuelTypes']);
  late bool _status = jsBool(v['status'], true);
  String? _error;

  @override
  void dispose() {
    for (final c in [..._text.values, ..._numbers.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final r = buildVehicleServiceValues(
      text: {
        for (final e in _text.entries) e.key: e.value.text,
        ..._images,
        'mapIconColor': _color,
      },
      numbers: {for (final e in _numbers.entries) e.key: e.value.text},
      serviceTypes: _serviceTypes,
      fuel: _fuel,
      status: _status,
    );
    if (r.error != null) return setState(() => _error = r.error);
    Navigator.pop(context, r.values);
  }

  static Color _parseHex(String hex) => Color(int.parse('FF${hex.substring(1)}', radix: 16));

  List<String> _toggle(List<String> l, String x) => l.contains(x) ? l.where((s) => s != x).toList() : [...l, x];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return EditorBody(
      error: _error,
      saveLabel: widget.entry == null ? 'Add Vehicle Service' : 'Save changes',
      onSave: widget.canEdit ? _save : null,
      children: [
        DataUrlImageField(
            label: 'Vehicle Icon',
            value: _images['iconUri']!,
            onChanged: (u) => setState(() => _images['iconUri'] = u)),
        DataUrlImageField(
            label: 'Hero Image',
            aspect: 16 / 9,
            value: _images['heroImageUri']!,
            onChanged: (u) => setState(() => _images['heroImageUri'] = u)),
        DataUrlImageField(
            label: 'Map Icon',
            value: _images['mapIconUri']!,
            onChanged: (u) => setState(() => _images['mapIconUri'] = u)),
        const SectionLabel('Colour Palette', hint: 'Pick a colour from the palette or upload a custom icon shown on the map.'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ChoiceChip(label: const Text('None'), selected: _color.isEmpty, onSelected: (_) => setState(() => _color = '')),
          for (final c in mapIconPalette)
            InkWell(
              onTap: () => setState(() => _color = c),
              customBorder: const CircleBorder(),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _parseHex(c),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _color.toLowerCase() == c.toLowerCase() ? cs.primary : cs.outlineVariant,
                    width: _color.toLowerCase() == c.toLowerCase() ? 3 : 1,
                  ),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 16),
        TextField(
            controller: _text['name'],
            decoration: const InputDecoration(labelText: 'Service Name *', hintText: 'Express')),
        const SizedBox(height: 12),
        TextField(
          controller: _text['description'],
          maxLines: 4,
          minLines: 2,
          decoration: const InputDecoration(labelText: 'Description', hintText: 'Brief description of this service'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _text['shortDescription'],
          decoration: const InputDecoration(labelText: 'Short Description', hintText: 'One-liner shown in lists'),
        ),
        const SectionLabel('Service Type Allowed'),
        if (widget.serviceTypes.isEmpty)
          const Text('No record. Add services in Service Settings first.')
        else
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final o in widget.serviceTypes)
              FilterChip(
                label: Text(o),
                selected: _serviceTypes.contains(o),
                onSelected: (_) => setState(() => _serviceTypes = _toggle(_serviceTypes, o)),
              ),
          ]),
        const SectionLabel('Fuel Type'),
        Wrap(spacing: 8, children: [
          for (final o in fuelTypes)
            FilterChip(
              label: Text(o),
              selected: _fuel.contains(o),
              onSelected: (_) => setState(() => _fuel = _toggle(_fuel, o)),
            ),
        ]),
        const SizedBox(height: 12),
        for (final f in vehicleServiceNumberFields)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: _numbers[f.key],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: '${f.label}${f.suffix != null ? ' (in ${f.suffix})' : ''}${f.required ? ' *' : ''}',
                hintText: '0',
                suffixText: f.suffix,
              ),
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Status'),
          subtitle: Text(_status ? 'Active' : 'Inactive'),
          value: _status,
          onChanged: (x) => setState(() => _status = x),
        ),
      ],
    );
  }
}
