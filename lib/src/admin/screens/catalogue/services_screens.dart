import 'dart:async';

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
import 'service_order_screen.dart' show serviceOrderPath;
import 'catalogue_widgets.dart';
import '../../../core/freight.dart' show isCourierTypes, isFreightTypes;
import '../../../data/permits_repository.dart' show permitsRepositoryProvider;
import '../../../core/service_tree.dart' show serviceParentIds;
import '../../../widgets/search_select.dart';
import 'safe_rename.dart';

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
    this.header,
    this.openId,
  });

  final SettingsCategory category;
  final String title;
  final String emptyTitle;
  final String addLabel;
  final Widget Function(SettingEntry e) tile;
  final Future<void> Function(BuildContext, List<SettingEntry> all, SettingEntry? e) edit;
  final bool Function(SettingEntry e) isDefault;
  final String deleteMessage;

  /// Above the list (Vehicle Services: the service order).
  final Widget? header;

  /// An entry to open as the list loads (the Media Gallery's "Where used").
  final String? openId;

  @override
  ConsumerState<_PriorityList> createState() => _PriorityListState();
}

class _PriorityListState extends ConsumerState<_PriorityList> {
  String _query = '';
  bool _opened = false;

  SettingsCategory get c => widget.category;

  /// Opens [SettingsCategory] entry [_PriorityList.openId] once, after the
  /// list first shows.
  void _openOnce(List<SettingEntry> all) {
    final id = widget.openId;
    if (_opened || id == null) return;
    _opened = true;
    final e = all.where((x) => x.id == id).firstOrNull;
    if (e == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.edit(context, all, e);
    });
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
      addAction: PageAddAction(
        onPressed: () => widget.edit(context, entries.value ?? [], null),
        icon: const Icon(Icons.add),
        label: Text(widget.addLabel),
      ),
      body: AsyncView(
        value: entries,
        onRetry: () => ref.invalidate(catalogueEntriesProvider(c)),
        data: (all) {
          _openOnce(all);
          final sorted = sortByPriority(all);
          final rows = sorted.where((e) => entryMatches(e, _query)).toList();
          final searching = _query.trim().isNotEmpty;
          return ResponsiveCenter(
            maxWidth: 820,
            child: Column(children: [
              CatalogueSearch(onChanged: (v) => setState(() => _query = v)),
              ?widget.header,
              Expanded(
                child: rows.isEmpty
                    ? EmptyState(icon: Icons.inbox_outlined, title: widget.emptyTitle, message: c.subtitle)
                    : ListView.builder(
                        padding: EdgeInsets.only(bottom: addActionListBottomPadding(context)),
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
                                  BusyIconButton(
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
  const ServiceSettingsScreen({super.key, this.openId});

  /// An entry to open as the list loads.
  final String? openId;

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
        openId: openId,
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
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Service name *', hintText: 'e.g. Car')),
          const SizedBox(height: 12),
          TextField(controller: _desc, decoration: const InputDecoration(labelText: 'Description')),
          const SizedBox(height: 12),
          TextField(
            controller: _priority,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Display priority'),
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
  const VehicleServicesScreen({super.key, this.openId});

  /// An entry to open as the list loads.
  final String? openId;

  Future<void> _edit(BuildContext context, WidgetRef ref, List<SettingEntry> all, SettingEntry? e) async {
    List<String> options;
    try {
      options = serviceTypeOptions(await ref.read(catalogueEntriesProvider(serviceSettingsCategory).future));
    } catch (_) {
      options = [];
    }
    // The vehicle permit types a freight size may ask for (0254, 0267).
    List<({String key, String name})> permits;
    try {
      final types = await ref.read(permitsRepositoryProvider).permitTypes();
      final seen = <String>{};
      permits = [
        for (final t in types)
          if (!t.forDriver && t.key.isNotEmpty && seen.add(t.key)) (key: t.key, name: t.name),
      ];
    } catch (_) {
      permits = const [];
    }
    if (!context.mounted) return;
    final values = await openEditor<Map<String, dynamic>>(
      context,
      e == null ? 'Add Vehicle Service' : 'Edit Vehicle Service',
      _VehicleServiceEditor(
        permits: permits,
        entry: e,
        count: all.length,
        serviceTypes: options,
        parents: parentServiceOptions(all, e?.id),
        otherNames: [for (final o in all) if (o.id != e?.id) str(o.values['name'])],
        canEdit: canEditPage(ref, vehicleServicesCategory.page),
      ),
    );
    if (values == null || !context.mounted) return;
    // A new name moves every place that uses the old one (0304).
    if (e != null && renamesEntry(e, values)) {
      await saveEntryWithRename(context, ref, category: vehicleServicesCategory, entry: e, values: values);
    } else {
      await _saveEntry(context, ref, vehicleServicesCategory, e, values);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => _PriorityList(
        openId: openId,
        category: vehicleServicesCategory,
        title: 'Vehicle Services',
        emptyTitle: 'No vehicle services yet',
        addLabel: 'Add Vehicle Service',
        deleteMessage: 'Remove this vehicle service?',
        isDefault: (_) => false,
        // Which services may take which orders (0249, 0250).
        header: Card(
          child: ListTile(
            key: const ValueKey('vehicle-services-service-order'),
            leading: const Icon(Icons.stairs_outlined),
            title: const Text('Service order'),
            subtitle: const Text('Lowest to highest: a higher service may take a lower one\'s orders'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(serviceOrderPath),
          ),
        ),
        edit: (ctx, all, e) => _edit(ctx, ref, all, e),
        tile: (e) {
          final v = e.values;
          final p = v['displayPriority'];
          final meta = vehicleServiceMeta(v);
          final dispatch = vehicleServiceDispatchSummary(v);
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: StoredImage(str(v['iconUri']), fallback: Icons.layers_outlined),
            title: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(str(v['name']).isEmpty ? 'Untitled' : str(v['name'])),
              Pill(p == null || '$p' == '' ? '-' : '$p', icon: Icons.format_list_numbered),
              StatusChip(jsBool(v['status'], true) ? 'Active' : 'Inactive'),
            ]),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (meta.isNotEmpty) Text(meta),
              Row(children: [
                const Icon(Icons.radar, size: 14),
                const SizedBox(width: 4),
                Expanded(child: Text(dispatch, key: ValueKey('vs-dispatch-summary-${e.id}'))),
              ]),
            ]),
          );
        },
      );
}

class _VehicleServiceEditor extends ConsumerStatefulWidget {
  const _VehicleServiceEditor({
    this.entry,
    required this.count,
    required this.serviceTypes,
    this.parents = const [],
    this.otherNames = const [],
    required this.canEdit,
    this.permits = const [],
  });
  final SettingEntry? entry;

  /// The other Vehicle Services' names: a new name may not be one of them.
  final List<String> otherNames;

  /// The vehicle permit types (by key) a freight size may ask for.
  final List<({String key, String name})> permits;
  final int count;
  final List<String> serviceTypes;

  /// The other vehicle services it may sit under (parentServiceOptions).
  final List<({String id, String name})> parents;
  final bool canEdit;

  @override
  ConsumerState<_VehicleServiceEditor> createState() => _VehicleServiceEditorState();
}

class _VehicleServiceEditorState extends ConsumerState<_VehicleServiceEditor> {
  late final v = widget.entry?.values ?? const <String, dynamic>{};
  late final _name = RenameFieldController(
    category: vehicleServicesKey,
    entryId: widget.entry?.id,
    name: str(v['name']),
    otherNames: widget.otherNames,
  )..addListener(_renamed);
  late final _text = {
    for (final k in ['description', 'shortDescription']) k: TextEditingController(text: str(v[k])),
  };
  late final _numbers = {
    for (final f in vehicleServiceNumberFields)
      f.key: TextEditingController(
        text: widget.entry == null
            ? (f.key == 'displayPriority' ? '${widget.count + 1}' : '')
            : (v[f.key] == null ? '' : '${v[f.key]}'),
      ),
  };
  late final _dispatch = {
    for (final f in vehicleServiceDispatchFields) f.key: TextEditingController(text: dispatchFieldText(v, f)),
  };
  late final _freight = {
    for (final f in vehicleServiceFreightFields)
      f.key: TextEditingController(text: v[f.key] == null || v[f.key] == 0 ? '' : '${v[f.key]}'),
  };
  late bool _closedBody = v[closedBodyKey] == true;
  late bool _refrigerated = v[refrigeratedKey] == true;
  late String _permit = str(v[goodsPermitKey]);
  late final _images = {for (final k in ['iconUri', 'heroImageUri', 'mapIconUri']) k: str(v[k])};
  late String _color = str(v['mapIconColor']);
  late List<String> _serviceTypes = stringList(v['serviceTypes']);
  late List<String> _parents = serviceParentIds(v);
  late List<String> _fuel = stringList(v['fuelTypes']);
  late bool _status = jsBool(v['status'], true);
  String? _error;

  @override
  void dispose() {
    for (final c in [..._text.values, ..._numbers.values, ..._dispatch.values, ..._freight.values]) {
      c.dispose();
    }
    _name
      ..removeListener(_renamed)
      ..dispose();
    super.dispose();
  }

  void _renamed() {
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    final r = buildVehicleServiceValues(
      text: {
        'name': _name.text.text,
        for (final e in _text.entries) e.key: e.value.text,
        ..._images,
        'mapIconColor': _color,
      },
      numbers: {for (final e in _numbers.entries) e.key: e.value.text},
      serviceTypes: _serviceTypes,
      parents: [for (final p in _parents) if (widget.parents.any((o) => o.id == p)) p],
      fuel: _fuel,
      status: _status,
      dispatch: _dispatchText,
      freight: {for (final e in _freight.entries) e.key: e.value.text},
      closedBody: _closedBody,
      refrigerated: _refrigerated,
      goodsPermit: _permit,
      existing: widget.entry?.values,
    );
    if (r.error != null) return setState(() => _error = r.error);
    // A new name: what follows it, then Rename (0304).
    if (!await reviewRename(context, ref, _name) || !mounted) return;
    Navigator.pop(context, r.values);
  }

  Map<String, String> get _dispatchText => {for (final e in _dispatch.entries) e.key: e.value.text};

  Widget _dispatchField(DispatchField f, String? error) {
    final c = _dispatch[f.key]!;
    final noLimit = f.zeroAllowed && (c.text.trim().isEmpty || num.tryParse(c.text.trim()) == 0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: ValueKey('vs-${f.key}'),
        controller: c,
        enabled: widget.canEdit,
        keyboardType: TextInputType.numberWithOptions(decimal: !f.wholeNumber),
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          // The unit sits in the field (suffixText), not in the label.
          labelText: sentenceCaseLabel(f.label),
          hintText: f.zeroAllowed ? 'No limit' : 'Default ${formatDispatchNumber(f.defaultValue)}',
          helperText: f.helper,
          helperMaxLines: 4,
          errorText: error,
          errorMaxLines: 3,
          suffixText: noLimit && c.text.trim().isNotEmpty ? 'No limit' : f.unit,
        ),
      ),
    );
  }

  static Color _parseHex(String hex) => Color(int.parse('FF${hex.substring(1)}', radix: 16));

  List<String> _toggle(List<String> l, String x) => l.contains(x) ? l.where((s) => s != x).toList() : [...l, x];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dispatchError = validateVehicleServiceDispatch(_dispatchText);
    return EditorBody(
      error: _error,
      saveLabel: widget.entry == null
          ? 'Add Vehicle Service'
          : _name.renaming
              ? renameSaveLabel(_name.places)
              : 'Save changes',
      // Not awaited: the button would spin behind the preview.
      onSave: widget.canEdit && _name.problem == null ? () => unawaited(_save()) : null,
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
        RenameNameField(
          controller: _name,
          label: 'Service name *',
          hint: 'Express',
          enabled: widget.canEdit,
          onReview: widget.canEdit ? () => unawaited(_save()) : null,
        ),
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
        const SectionLabel('Service type'),
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: Text(
            'The Service Settings types this vehicle belongs to (Car, Bike, …). Region rules and fares set for a type '
            'apply to it.',
          ),
        ),
        if (widget.serviceTypes.isEmpty)
          const Text('No record. Add services in Service Settings first.')
        else
          ListSearchFilter(
            count: widget.serviceTypes.length,
            hint: 'Search service types',
            builder: (context, q) => Wrap(spacing: 8, runSpacing: 4, children: [
            for (final o in widget.serviceTypes)
              if (q.isEmpty || searchSelectMatches(o, q) || _serviceTypes.contains(o))
                FilterChip(
                label: Text(o),
                selected: _serviceTypes.contains(o),
                onSelected: (_) => setState(() => _serviceTypes = _toggle(_serviceTypes, o)),
              ),
          ]),
          ),
        if (widget.parents.isNotEmpty) ...[
          const SectionLabel('Under'),
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              'The vehicle services this one sits under (Ride XL under Ride), to any depth. A region that switches '
              'one off switches off everything under it.',
            ),
          ),
          ListSearchFilter(
            count: widget.parents.length,
            hint: 'Search services',
            builder: (context, q) => Wrap(spacing: 8, runSpacing: 4, children: [
            for (final o in widget.parents)
              if (q.isEmpty || searchSelectMatches(o.name, q) || _parents.contains(o.id))
                FilterChip(
                key: ValueKey('vs-parent-${o.id}'),
                label: Text(o.name),
                selected: _parents.contains(o.id),
                onSelected: (_) => setState(() => _parents = _toggle(_parents, o.id)),
              ),
          ]),
          ),
        ],
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
                labelText: '${sentenceCaseLabel(f.label)}${f.required ? ' *' : ''}',
                hintText: '0',
                suffixText: f.suffix,
              ),
            ),
          ),
        // A freight size (0267): what it carries, shown to riders and drivers.
        // A courier vehicle (0268): the same load and size fields, its
        // weight and size limit; no closed body or goods-vehicle permit.
        if (isCourierTypes(_serviceTypes) && !isFreightTypes(_serviceTypes)) ...[
          const SectionLabel(
            'Courier',
            hint: 'The weight and size this vehicle carries. Senders only see it for parcels within its max load; '
                'the parcel sizes are in Courier settings.',
          ),
          for (final f in vehicleServiceFreightFields)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                key: ValueKey('vs-${f.key}'),
                controller: _freight[f.key],
                enabled: widget.canEdit,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: sentenceCaseLabel(f.label), suffixText: f.suffix),
              ),
            ),
        ] else if (isFreightTypes(_serviceTypes) ||
            _closedBody ||
            _refrigerated ||
            _permit.isNotEmpty ||
            _freight.values.any((c) => c.text.trim().isNotEmpty)) ...[
          const SectionLabel(
            'Freight',
            hint: 'Shown on the rider\'s Vehicle size list and the driver\'s request. Leave a field blank if it '
                'doesn\'t apply.',
          ),
          for (final f in vehicleServiceFreightFields)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                key: ValueKey('vs-${f.key}'),
                controller: _freight[f.key],
                enabled: widget.canEdit,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: sentenceCaseLabel(f.label), suffixText: f.suffix),
              ),
            ),
          SwitchListTile(
            key: const ValueKey('vs-closedBody'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Closed body'),
            subtitle: const Text('A covered van or lorry. Riders who ask for a closed body can only book these.'),
            value: _closedBody,
            onChanged: widget.canEdit ? (x) => setState(() => _closedBody = x) : null,
          ),
          SwitchListTile(
            key: const ValueKey('vs-refrigerated'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Refrigerated'),
            subtitle: const Text('A refrigerated van or lorry. Riders who ask for a cold truck can only book these, and '
                'only drivers of these see those requests.'),
            value: _refrigerated,
            onChanged: widget.canEdit ? (x) => setState(() => _refrigerated = x) : null,
          ),
          SearchableDropdownFormField<String>(
            key: const ValueKey('vs-goodsPermit'),
            isExpanded: true,
            initialValue: _permit,
            decoration: const InputDecoration(
              labelText: 'Goods-vehicle permit',
              helperText: 'The Permits type a driver\'s vehicle must hold, approved, to get these requests.',
              helperMaxLines: 3,
            ),
            items: [
              const DropdownMenuItem(value: '', child: Text('None')),
              for (final p in widget.permits) DropdownMenuItem(value: p.key, child: Text('${p.name} (${p.key})')),
              // A key kept from before, no longer a type.
              if (_permit.isNotEmpty && !widget.permits.any((p) => p.key == _permit))
                DropdownMenuItem(value: _permit, child: Text(_permit)),
            ],
            onChanged: widget.canEdit ? (x) => setState(() => _permit = x ?? '') : null,
          ),
          const SizedBox(height: 12),
        ],
        for (final section in [searchRadiusSection, myRideSection]) ...[
          SectionLabel(
            section,
            hint: section == searchRadiusSection
                ? 'How far the app looks for drivers for this service. Leave a field blank to use the default '
                    'shown in it.'
                : 'Riders can book their favourite drivers first. Leave a field blank to use the default shown in it.',
          ),
          for (final f in vehicleServiceDispatchFields)
            if (f.section == section) _dispatchField(f, dispatchError?.key == f.key ? dispatchError!.message : null),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Status'),
          subtitle: Text(_status ? 'Active' : 'Inactive'),
          value: _status,
          onChanged: (x) => setState(() => _status = x),
        ),
        if (widget.entry != null)
          RenameHistoryCard(category: vehicleServicesCategory, entryId: widget.entry!.id, canEdit: widget.canEdit),
      ],
    );
  }
}
