import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';
import 'catalogue_data.dart';
import 'catalogue_logic.dart';
import 'catalogue_widgets.dart';

const _page = 'admin-settings-vehicle-make-model';

const _levelTitles = ['Vehicle Types', 'Energy Types', 'Makes', 'Models'];
const _levelSubtitles = [
  'Bike, Car, Truck, Pick Up, etc.',
  'Petrol, Diesel, EV, Hybrid, etc.',
  'BMW, Proton, Perodua, etc.',
  'Wira, 530i, etc. with year range',
];
const _levelSingular = ['Vehicle Type', 'Energy Type', 'Make', 'Model'];
const _levelIcons = [Icons.directions_car_outlined, Icons.local_gas_station_outlined, Icons.factory_outlined, Icons.sell_outlined];

class VehicleMakeModelScreen extends ConsumerStatefulWidget {
  const VehicleMakeModelScreen({super.key});

  @override
  ConsumerState<VehicleMakeModelScreen> createState() => _VehicleMakeModelScreenState();
}

class _VehicleMakeModelScreenState extends ConsumerState<VehicleMakeModelScreen> {
  VmmPath _path = const VmmPath();
  final _search = TextEditingController();

  String get _query => _search.text;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _goTo(VmmPath p) => setState(() {
        _search.clear();
        _path = p;
      });

  void _refresh() => ref.invalidate(vehicleMakeModelsProvider);

  CatalogueRepository get _repo => ref.read(catalogueRepositoryProvider);

  // ---- categories ----------------------------------------------------------

  Future<void> _addCategory(List<VehicleMakeModel> all, int level) async {
    final res = await openEditor<_CategoryResult>(
      context,
      'Add ${_levelSingular[level]}',
      _CategoryEditor(all: all, level: level, parents: _path, canEdit: canEditPage(ref, _page)),
    );
    if (res == null || !mounted) return;
    if (res.openExisting != null) return _goTo(res.openExisting!);
    final row = vmmCategoryPlaceholder(level, res.name, res.parents, _repo.newId());
    if (await runAdminAction(context, () => _repo.upsertVehicleMakeModel(row), success: 'Added')) _refresh();
  }

  Future<void> _renameCategory(List<VehicleMakeModel> all, int level, String current) async {
    final res = await openEditor<_CategoryResult>(
      context,
      'Rename ${_levelSingular[level]}',
      _CategoryEditor(all: all, level: level, parents: _path, renameFrom: current, canEdit: canEditPage(ref, _page)),
    );
    if (res == null || !mounted || res.name == current) return;
    final ids = vmmCategoryRows(all, _path, level, current).map((r) => r.id).toList();
    if (await runAdminAction(context, () => _repo.renameVehicleMakeModels(ids, level, res.name), success: 'Renamed')) {
      setState(() => _path = _path.renamed(level, current, res.name));
      _refresh();
    }
  }

  Future<void> _deleteCategory(List<VehicleMakeModel> all, int level, String name) async {
    final label = ['vehicle type', 'energy type', 'make'][level];
    if (!await confirm(context, 'Delete $label', 'Remove "$name" and all entries under it?', ok: 'Delete') ||
        !mounted) {
      return;
    }
    final ids = vmmCategoryRows(all, _path, level, name).map((r) => r.id).toList();
    if (await runAdminAction(context, () => _repo.deleteVehicleMakeModels(ids), success: 'Deleted')) _refresh();
  }

  // ---- models --------------------------------------------------------------

  Future<void> _editModel(List<VehicleMakeModel> all, [VehicleMakeModel? m]) async {
    final row = await openEditor<Map<String, dynamic>>(
      context,
      m == null ? 'Add Model' : 'Edit Model',
      _ModelEditor(
        all: all,
        editing: m,
        initial: m == null
            ? ModelForm(vehicleType: _path.vehicleType ?? '', energyType: _path.energyType ?? '', make: _path.make ?? '')
            : ModelForm.fromRecord(m),
        newId: _repo.newId(),
        canEdit: canEditPage(ref, _page),
      ),
    );
    if (row == null || !mounted) return;
    if (await runAdminAction(context, () => _repo.upsertVehicleMakeModel(row), success: 'Saved')) _refresh();
  }

  Future<void> _deleteModel(VehicleMakeModel m) async {
    if (!await confirm(context, 'Delete model', 'Remove this model?', ok: 'Delete') || !mounted) return;
    if (await runAdminAction(context, () => _repo.deleteVehicleMakeModels([m.id]), success: 'Deleted')) _refresh();
  }

  Future<void> _addPicker(List<VehicleMakeModel> all) async {
    final level = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var l = 0; l < 4; l++)
            ListTile(
              leading: Icon(_levelIcons[l]),
              title: Text('Add ${_levelSingular[l]}'),
              onTap: () => Navigator.pop(ctx, l),
            ),
        ]),
      ),
    );
    if (level == null || !mounted) return;
    level == 3 ? await _editModel(all) : await _addCategory(all, level);
  }

  // ---- rendering -----------------------------------------------------------

  Widget _modelTile(List<VehicleMakeModel> all, VehicleMakeModel m, bool canEdit) => Card(
        child: ListTile(
          onTap: () => _editModel(all, m),
          leading: StoredImage(m.iconUri, fallback: Icons.directions_car_outlined),
          title: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('${m.model} ${formatYearRange(m.yearFrom, m.yearTo)}'.trim()),
            StatusChip(m.status ? 'Active' : 'Inactive'),
          ]),
          subtitle: Text('${m.make} • ${m.energyType} • ${m.vehicleType}'),
          trailing: canEdit
              ? IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete', onPressed: () => _deleteModel(m))
              : null,
        ),
      );

  List<Widget> _breadcrumbs() {
    final items = <(String, VmmPath?)>[
      ('Vehicle Types', _path.level == 0 ? null : const VmmPath()),
      if (_path.vehicleType != null) (_path.vehicleType!, _path.level == 1 ? null : VmmPath(vehicleType: _path.vehicleType)),
      if (_path.energyType != null)
        (
          _path.energyType!,
          _path.level == 2 ? null : VmmPath(vehicleType: _path.vehicleType, energyType: _path.energyType)
        ),
      if (_path.make != null) (_path.make!, null),
    ];
    return [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) const Icon(Icons.chevron_right, size: 16),
        ActionChip(
          avatar: i == 0 ? const Icon(Icons.home_outlined, size: 16) : null,
          label: Text(items[i].$1),
          onPressed: items[i].$2 == null ? null : () => _goTo(items[i].$2!),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = canEditPage(ref, _page);
    final data = ref.watch(vehicleMakeModelsProvider);
    final level = _path.level;
    return PopScope(
      canPop: level == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goTo(_path.parent);
      },
      child: AdminPage(
        title: _levelTitles[level],
        page: _page,
        actions: [
          if (level > 0)
            IconButton(tooltip: 'Up one level', icon: const Icon(Icons.arrow_upward), onPressed: () => _goTo(_path.parent)),
        ],
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _addPicker(data.value ?? []),
          icon: const Icon(Icons.add),
          label: const Text('Add'),
        ),
        body: AsyncView(
          value: data,
          onRetry: _refresh,
          data: (all) {
            final searching = _query.trim().isNotEmpty;
            final List<Widget> tiles;
            String emptyTitle;
            String emptyDesc;
            if (searching && level < 3) {
              final matches = vmmGlobalSearch(all, _path, _query);
              tiles = [for (final m in matches) _modelTile(all, m, canEdit)];
              emptyTitle = 'No matching models';
              emptyDesc = 'No vehicles match "${_query.trim()}".';
            } else if (level < 3) {
              final cats = vmmCategories(all, _path, query: _query);
              final unit = ['energy type', 'make', 'model'][level];
              tiles = [
                for (final c in cats)
                  Card(
                    child: ListTile(
                      onTap: () => _goTo(_path.child(c.name)),
                      leading: Icon(_levelIcons[level]),
                      title: Text(c.name),
                      subtitle: Text('${c.count} $unit${c.count == 1 ? '' : 's'}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (canEdit) ...[
                          IconButton(
                            tooltip: 'Rename',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _renameCategory(all, level, c.name),
                          ),
                          IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _deleteCategory(all, level, c.name),
                          ),
                        ],
                        const Icon(Icons.chevron_right),
                      ]),
                    ),
                  ),
              ];
              emptyTitle = 'No ${_levelTitles[level].toLowerCase()}';
              emptyDesc = [
                'Add a vehicle type like Car, Bike, Truck, or Pick Up.',
                'Add an energy type like Petrol, Diesel, or EV.',
                'Add a make like BMW, Proton, or Perodua.',
              ][level];
            } else {
              tiles = [for (final m in vmmModels(all, _path, query: _query)) _modelTile(all, m, canEdit)];
              emptyTitle = 'No models';
              emptyDesc = 'Add a model like WIRA (1993 - 2009).';
            }
            return ResponsiveCenter(
              maxWidth: 820,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_levelSubtitles[level], style: Theme.of(context).textTheme.bodySmall),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: _breadcrumbs()),
                ),
                CatalogueSearch(controller: _search, onChanged: (_) => setState(() {})),
                Expanded(
                  child: tiles.isEmpty
                      ? EmptyState(
                          icon: Icons.inbox_outlined,
                          title: emptyTitle,
                          message: emptyDesc,
                          action: canEdit && !searching
                              ? FilledButton.icon(
                                  onPressed: () => level == 3 ? _editModel(all) : _addCategory(all, level),
                                  icon: const Icon(Icons.add),
                                  label: Text('Add ${_levelSingular[level]}'),
                                )
                              : null,
                        )
                      : ListView(padding: const EdgeInsets.only(bottom: 96), children: tiles),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

class _CategoryResult {
  const _CategoryResult({this.name = '', this.parents = const VmmPath(), this.openExisting});
  final String name;
  final VmmPath parents;
  final VmmPath? openExisting;
}

class _CategoryEditor extends StatefulWidget {
  const _CategoryEditor({
    required this.all,
    required this.level,
    required this.parents,
    this.renameFrom,
    required this.canEdit,
  });
  final List<VehicleMakeModel> all;
  final int level;
  final VmmPath parents;
  final String? renameFrom;
  final bool canEdit;

  @override
  State<_CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends State<_CategoryEditor> {
  late final _name = TextEditingController(text: widget.renameFrom ?? '');
  late final _vt = TextEditingController(text: widget.parents.vehicleType ?? '');
  late final _et = TextEditingController(text: widget.parents.energyType ?? '');
  String? _error;

  bool get _renaming => widget.renameFrom != null;

  VmmPath get _parents => VmmPath(vehicleType: _vt.text.trim(), energyType: _et.text.trim());

  @override
  void dispose() {
    _name.dispose();
    _vt.dispose();
    _et.dispose();
    super.dispose();
  }

  void _save() {
    // Renames act within the current path; adds use the chosen parents.
    final parents = _renaming ? widget.parents : _parents;
    final err = vmmCategoryError(widget.all,
        level: widget.level, name: _name.text, parents: parents, renameFrom: widget.renameFrom);
    if (err != null) return setState(() => _error = err);
    Navigator.pop(context, _CategoryResult(name: _name.text.trim(), parents: parents));
  }

  Widget _chips(List<String> options, String selected, ValueChanged<String> onPick) => Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final o in options) ChoiceChip(label: Text(o), selected: o == selected, onSelected: (_) => onPick(o)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final l = widget.level;
    final parents = _renaming ? widget.parents : _parents;
    final suggestions = vmmCategorySuggestions(widget.all, l, parents, _name.text);
    return EditorBody(
      error: _error,
      saveLabel: _renaming ? 'Save changes' : 'Add',
      onSave: widget.canEdit ? _save : null,
      children: [
        if (!_renaming && l >= 1) ...[
          TextField(
            controller: _vt,
            decoration: const InputDecoration(labelText: 'Vehicle Type *', hintText: 'e.g. Car'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          _chips(vmmCategorySuggestions(widget.all, 0, const VmmPath(), ''), _vt.text,
              (o) => setState(() => _vt.text = o)),
          const SizedBox(height: 12),
        ],
        if (!_renaming && l >= 2) ...[
          TextField(
            controller: _et,
            decoration: const InputDecoration(labelText: 'Energy Type *', hintText: 'e.g. Petrol'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          _chips(vmmCategorySuggestions(widget.all, 1, _parents, ''), _et.text, (o) => setState(() => _et.text = o)),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _name,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '${_levelSingular[l]} Name *',
            hintText: ['e.g. Car', 'e.g. Petrol', 'e.g. BMW'][l],
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (suggestions.isNotEmpty) ...[
          SectionLabel(_renaming ? 'Existing at this level' : 'Already exists — tap to open instead of duplicating'),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final s in suggestions)
              ActionChip(
                label: Text(s),
                onPressed: () {
                  if (_renaming) {
                    setState(() => _name.text = s);
                  } else {
                    final p = _parents;
                    Navigator.pop(
                      context,
                      _CategoryResult(
                        openExisting: switch (l) {
                          0 => VmmPath(vehicleType: s),
                          1 => VmmPath(vehicleType: p.vehicleType, energyType: s),
                          _ => VmmPath(vehicleType: p.vehicleType, energyType: p.energyType, make: s),
                        },
                      ),
                    );
                  }
                },
              ),
          ]),
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}

class _ModelEditor extends StatefulWidget {
  const _ModelEditor({required this.all, this.editing, required this.initial, required this.newId, required this.canEdit});
  final List<VehicleMakeModel> all;
  final VehicleMakeModel? editing;
  final ModelForm initial;
  final String newId;
  final bool canEdit;

  @override
  State<_ModelEditor> createState() => _ModelEditorState();
}

class _ModelEditorState extends State<_ModelEditor> {
  late final f = widget.initial;
  late final _vt = TextEditingController(text: f.vehicleType);
  late final _et = TextEditingController(text: f.energyType);
  late final _make = TextEditingController(text: f.make);
  late final _model = TextEditingController(text: f.model);
  late final _from = TextEditingController(text: f.yearFrom);
  late final _to = TextEditingController(text: f.yearTo);
  String? _error;

  @override
  void dispose() {
    for (final c in [_vt, _et, _make, _model, _from, _to]) {
      c.dispose();
    }
    super.dispose();
  }

  void _sync() {
    f
      ..vehicleType = _vt.text
      ..energyType = _et.text
      ..make = _make.text
      ..model = _model.text
      ..yearFrom = _from.text
      ..yearTo = _to.text;
  }

  void _save() {
    _sync();
    final r = buildModelRow(widget.all, f, editing: _editing, newId: widget.newId);
    if (r.error != null) return setState(() => _error = r.error);
    Navigator.pop(context, r.row);
  }

  Widget _field(TextEditingController c, String label, String hint, List<String> suggestions) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: c,
          decoration: InputDecoration(labelText: label, hintText: hint),
          onChanged: (_) => setState(_sync),
        ),
        if (suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 6, runSpacing: 4, children: [
              for (final s in suggestions)
                ChoiceChip(
                  label: Text(s),
                  selected: s.toLowerCase() == c.text.trim().toLowerCase(),
                  onSelected: (_) => setState(() {
                    c.text = s;
                    _sync();
                  }),
                ),
            ]),
          ),
        const SizedBox(height: 12),
      ]);

  @override
  Widget build(BuildContext context) {
    final all = widget.all;
    final vtPath = VmmPath(vehicleType: _vt.text.trim());
    final etPath = VmmPath(vehicleType: _vt.text.trim(), energyType: _et.text.trim());
    // Existing models under the typed make: tap one to edit it instead.
    final existing = vmmModels(
      all,
      VmmPath(vehicleType: _vt.text.trim(), energyType: _et.text.trim(), make: _make.text.trim()),
      query: _model.text,
    ).where((m) => m.id != _editing?.id).take(12).toList();
    return EditorBody(
      error: _error,
      saveLabel: _editing == null ? 'Add Model' : 'Save changes',
      onSave: widget.canEdit ? _save : null,
      children: [
        DataUrlImageField(label: 'Icon', value: f.iconUri, onChanged: (u) => setState(() => f.iconUri = u)),
        _field(_vt, 'Vehicle Type *', 'e.g. Car', vmmCategorySuggestions(all, 0, const VmmPath(), _vt.text)),
        _field(_et, 'Energy Type *', 'e.g. Petrol', vmmCategorySuggestions(all, 1, vtPath, _et.text)),
        _field(_make, 'Make *', 'e.g. Proton', vmmCategorySuggestions(all, 2, etPath, _make.text)),
        TextField(
          controller: _model,
          decoration: const InputDecoration(labelText: 'Model *', hintText: 'e.g. Wira'),
          onChanged: (_) => setState(_sync),
        ),
        if (existing.isNotEmpty) ...[
          const SectionLabel('Existing models — tap to edit instead'),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final m in existing)
              ActionChip(
                label: Text('${m.model} ${formatYearRange(m.yearFrom, m.yearTo)}'.trim()),
                onPressed: () => setState(() {
                  // Switch this form to editing the existing row.
                  final g = ModelForm.fromRecord(m);
                  _vt.text = g.vehicleType;
                  _et.text = g.energyType;
                  _make.text = g.make;
                  _model.text = g.model;
                  _from.text = g.yearFrom;
                  _to.text = g.yearTo;
                  f
                    ..ongoing = g.ongoing
                    ..iconUri = g.iconUri
                    ..status = g.status;
                  _sync();
                  _editingOverride = m;
                }),
              ),
          ]),
        ],
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _from,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Year From', hintText: '1993'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _to,
              enabled: !f.ongoing,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Year To', hintText: '2009'),
            ),
          ),
        ]),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Ongoing (~)'),
          value: f.ongoing,
          onChanged: (x) => setState(() => f.ongoing = x ?? false),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Status'),
          subtitle: Text(f.status ? 'Active' : 'Inactive'),
          value: f.status,
          onChanged: (x) => setState(() => f.status = x),
        ),
      ],
    );
  }

  VehicleMakeModel? _editingOverride;
  VehicleMakeModel? get _editing => _editingOverride ?? widget.editing;
}
