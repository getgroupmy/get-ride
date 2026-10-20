// The permit types of a country, the editor of one (names, issuer, vehicle
// or driver, partner types and services, fields, who uploads, shown to
// passengers, required), a country's plate colours, and the admin's upload
// of a vehicle permit (the PDF, its fields read by the AI from the type's
// own labels, checked and saved).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/document_ai.dart';
import '../../../core/permits.dart';
import '../../../data/document_ai_repository.dart';
import '../../../data/permits_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/date_boxes.dart';
import '../../../widgets/in_app_page.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/permit_views.dart';
import '../../../widgets/plate_chip.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'doc_pdf.dart';
import 'people_data.dart';
import 'vehicle_permits_screen.dart';

// ---- The list -----------------------------------------------------------------------------

class PermitTypesPage extends ConsumerWidget {
  const PermitTypesPage({super.key, required this.country});
  final String country;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final edit = ref.watch(pageAccessProvider(vehiclePermitsPage)) == AccessLevel.edit;
    final all = ref.watch(adminPermitTypesProvider);
    Future<void> open(PermitType? t) async {
      await Navigator.of(context).push(AppPageRoute<void>(
        id: 'vehicle-permits.permit-type',
        builder: (_) => PermitTypeEditorPage(country: country, type: t),
      ));
      ref.invalidate(adminPermitTypesProvider);
    }

    return Scaffold(
      appBar: AppBar(title: Text('Permit types · $country')),
      floatingActionButton: edit
          ? FloatingActionButton.extended(
              key: const ValueKey('permit-type-add'),
              onPressed: () => open(null),
              icon: const Icon(Icons.add),
              label: const Text('Add permit type'),
            )
          : null,
      body: all.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(errorText(e))),
        data: (list) {
          final mine = [for (final t in list) if (t.country.toLowerCase() == country.toLowerCase()) t];
          if (mine.isEmpty) {
            return EmptyState(
              icon: Icons.badge_outlined,
              title: 'No permit types for $country',
              message: 'Add the permits a vehicle or its driver needs here.',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              for (final t in mine)
                Card(
                  child: ListTile(
                    key: ValueKey('permit-type-${t.key}'),
                    title: Text(t.name),
                    subtitle: Text([
                      if (t.nameLocal.isNotEmpty) t.nameLocal,
                      t.forDriver ? 'Driver' : 'Vehicle',
                      if (t.issuer.isNotEmpty) t.issuer,
                      t.uploader.label,
                      if (t.required) 'Required',
                      if (t.shownToPassengers) 'Shown to passengers',
                      if (!t.active) 'Off',
                    ].join(' · ')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => open(t),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ---- One type --------------------------------------------------------------------------------

class PermitTypeEditorPage extends ConsumerWidget {
  const PermitTypeEditorPage({super.key, required this.country, this.type});
  final String country;
  final PermitType? type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final edit = ref.watch(pageAccessProvider(vehiclePermitsPage)) == AccessLevel.edit;
    return Scaffold(
      appBar: AppBar(title: Text(type == null ? 'New permit type' : type!.name)),
      body: PermitTypeForm(
        country: country,
        type: type,
        edit: edit,
        partnerTypes: ref.watch(adminPartnerTypeNamesProvider).value ?? const [],
        services: ref.watch(adminVehicleServicesProvider).value ?? const [],
        documents: ref.watch(adminRequiredDocsProvider).value ?? const [],
        onSave: (t) async {
          final ok = await runAdminAction(context, () => ref.read(permitsRepositoryProvider).saveType(t), success: 'Permit type saved');
          if (ok && context.mounted) Navigator.pop(context);
        },
        onDelete: type?.id == null
            ? null
            : () async {
                if (!await confirm(context, 'Delete ${type!.name}?',
                    'Uploaded permits are kept as documents, but no longer count as this permit.', ok: 'Delete')) {
                  return;
                }
                if (!context.mounted) return;
                final ok = await runAdminAction(context, () => ref.read(permitsRepositoryProvider).deleteType(type!.id!),
                    success: 'Permit type deleted');
                if (ok && context.mounted) Navigator.pop(context);
              },
      ),
    );
  }
}

/// The type's form (tested on its own).
class PermitTypeForm extends StatefulWidget {
  const PermitTypeForm({
    super.key,
    required this.country,
    required this.onSave,
    this.type,
    this.edit = true,
    this.partnerTypes = const [],
    this.services = const [],
    this.documents = const [],
    this.onDelete,
  });

  final String country;
  final PermitType? type;
  final bool edit;
  final List<String> partnerTypes;
  final List<({String id, String name})> services;
  final List<({String id, String name})> documents;
  final ValueChanged<PermitType> onSave;
  final VoidCallback? onDelete;

  @override
  State<PermitTypeForm> createState() => _PermitTypeFormState();
}

class _PermitTypeFormState extends State<PermitTypeForm> {
  late final PermitType? _t = widget.type;
  late final _name = TextEditingController(text: _t?.name ?? '');
  late final _nameLocal = TextEditingController(text: _t?.nameLocal ?? '');
  late final _short = TextEditingController(text: _t?.shortName ?? '');
  late final _issuer = TextEditingController(text: _t?.issuer ?? '');
  late final _renewal = TextEditingController(text: _t?.renewalText ?? '');
  late bool _forDriver = _t?.forDriver ?? false;
  late PermitUploader _uploader = _t?.uploader ?? PermitUploader.admin;
  late bool _shown = _t?.shownToPassengers ?? true;
  late bool _required = _t?.required ?? false;
  late bool _active = _t?.active ?? true;
  late String? _documentId = _t?.documentId;
  late Set<String> _types = {...?_t?.partnerTypes};
  late Set<String> _services = {...?_t?.services};
  late List<PermitField> _fields = [...?_t?.fields];

  @override
  void dispose() {
    for (final c in [_name, _nameLocal, _short, _issuer, _renewal]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final t = PermitType(
      id: _t?.id,
      country: widget.country,
      key: _t?.key ?? permitTypeKey(_name.text),
      name: _name.text.trim(),
      nameLocal: _nameLocal.text.trim(),
      shortName: _short.text.trim(),
      issuer: _issuer.text.trim(),
      forDriver: _forDriver,
      partnerTypes: _types.toList(),
      services: _services.toList(),
      fields: _fields,
      uploader: _uploader,
      shownToPassengers: _shown,
      required: _required,
      documentId: _documentId,
      renewalText: _renewal.text.trim(),
      position: _t?.position ?? 0,
      active: _active,
    );
    final problem = permitTypeProblem(t);
    if (problem != null) return showError(context, problem);
    widget.onSave(t);
  }

  Future<void> _editField(int? index) async {
    final f = await showAppDialog<PermitField>(
      id: 'vehicle-permits.permit-field',
      context: context,
      builder: (_) => PermitFieldDialog(field: index == null ? null : _fields[index], taken: {
        for (final (i, f) in _fields.indexed)
          if (i != index) f.key,
      }),
    );
    if (f == null) return;
    setState(() {
      if (index == null) {
        _fields = [..._fields, f];
      } else {
        _fields = [..._fields]..[index] = f;
      }
    });
  }

  Future<void> _pickMany(String title, List<({String id, String name})> all, Set<String> chosen, ValueChanged<Set<String>> done) async {
    final picked = await showAppDialog<Set<String>>(
      id: 'vehicle-permits.pick-many',
      context: context,
      builder: (_) => _PickManyDialog(title: title, all: all, chosen: chosen),
    );
    if (picked != null) setState(() => done(picked));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final e = widget.edit;
    Widget text(TextEditingController c, String label, {String? helper, Key? key}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(key: key, controller: c, enabled: e, decoration: InputDecoration(labelText: label, helperText: helper)),
    );
    final typeChoices = [for (final n in {...widget.partnerTypes, ..._types}) (id: n, name: n)];
    return ListView(
      key: const ValueKey('permit-type-form'),
      padding: const EdgeInsets.all(16),
      children: [
        text(_name, 'Name (English)', key: const ValueKey('permit-type-name')),
        text(_nameLocal, 'Name in the local language', helper: 'Shown under the English name'),
        text(_short, 'Short name', helper: 'On the passenger\'s button, e.g. "Vehicle permit"'),
        text(_issuer, 'Issuer', helper: 'The authority that issues it'),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Vehicle'), icon: Icon(Icons.directions_car_outlined)),
            ButtonSegment(value: true, label: Text('Driver'), icon: Icon(Icons.person_outline)),
          ],
          selected: {_forDriver},
          onSelectionChanged: e ? (s) => setState(() => _forDriver = s.first) : null,
        ),
        const SizedBox(height: 12),
        SearchableDropdownFormField<PermitUploader>(
          key: const ValueKey('permit-type-uploader'),
          initialValue: _uploader,
          decoration: const InputDecoration(labelText: 'Who uploads it'),
          items: [for (final u in PermitUploader.values) DropdownMenuItem(value: u, child: Text(u.label))],
          onChanged: e ? (v) => setState(() => _uploader = v ?? _uploader) : null,
        ),
        if (_forDriver) ...[
          const SizedBox(height: 12),
          SearchableDropdownFormField<String>(
            key: const ValueKey('permit-type-document'),
            isExpanded: true,
            initialValue: widget.documents.any((d) => d.id == _documentId) ? _documentId : null,
            decoration: const InputDecoration(
              labelText: 'Uploaded as the document',
              helperText: 'The Required Document drivers upload this permit as',
            ),
            items: [for (final d in widget.documents) DropdownMenuItem(value: d.id, child: Text(d.name))],
            onChanged: e ? (v) => setState(() => _documentId = v) : null,
          ),
        ],
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('For partner types'),
          subtitle: Text(_types.isEmpty ? 'All' : _types.join(', ')),
          trailing: e ? const Icon(Icons.edit_outlined) : null,
          onTap: e ? () => _pickMany('Partner types', typeChoices, _types, (s) => _types = s) : null,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('For vehicle services'),
          subtitle: Text(_services.isEmpty
              ? 'All'
              : [for (final id in _services) widget.services.where((s) => s.id == id).firstOrNull?.name ?? id].join(', ')),
          trailing: e ? const Icon(Icons.edit_outlined) : null,
          onTap: e ? () => _pickMany('Vehicle services', widget.services, _services, (s) => _services = s) : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Shown to passengers'),
          subtitle: const Text('From the driver\'s acceptance to the end of the trip'),
          value: _shown,
          onChanged: e ? (v) => setState(() => _shown = v) : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Required'),
          subtitle: const Text('Counts when the country requires permits'),
          value: _required,
          onChanged: e ? (v) => setState(() => _required = v) : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('In use'),
          value: _active,
          onChanged: e ? (v) => setState(() => _active = v) : null,
        ),
        text(_renewal, 'Renewal note', helper: 'Told to drivers before it expires. {issuer} is the issuer.'),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: Text('Fields on the permit', style: t.textTheme.titleSmall)),
            if (e)
              TextButton.icon(
                key: const ValueKey('permit-field-add'),
                onPressed: () => _editField(null),
                icon: const Icon(Icons.add),
                label: const Text('Add field'),
              ),
          ],
        ),
        if (_fields.isEmpty) const Text('No fields yet.'),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: e,
          onReorderItem: (a, b) => setState(() {
            final list = [..._fields];
            final f = list.removeAt(a);
            list.insert(b, f);
            _fields = list;
          }),
          children: [
            for (final (i, f) in _fields.indexed)
              ListTile(
                key: ValueKey('permit-field-${f.key}'),
                title: Text(f.label),
                subtitle: Text([
                  if (f.labelLocal.isNotEmpty) f.labelLocal,
                  f.isDate ? 'Date' : 'Text',
                  if (f.role != PermitFieldRole.none) f.role.label,
                  if (f.passenger) 'Passengers see it',
                ].join(' · ')),
                onTap: e ? () => _editField(i) : null,
                trailing: e
                    ? IconButton(
                        tooltip: 'Remove ${f.label}',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() => _fields = [..._fields]..removeAt(i)),
                      )
                    : null,
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (e) ...[
          FilledButton(key: const ValueKey('permit-type-save'), onPressed: _save, child: const Text('Save')),
          if (widget.onDelete != null) ...[
            const SizedBox(height: 8),
            TextButton(onPressed: widget.onDelete, child: const Text('Delete permit type')),
          ],
        ],
      ],
    );
  }
}

class _PickManyDialog extends StatefulWidget {
  const _PickManyDialog({required this.title, required this.all, required this.chosen});
  final String title;
  final List<({String id, String name})> all;
  final Set<String> chosen;

  @override
  State<_PickManyDialog> createState() => _PickManyDialogState();
}

class _PickManyDialogState extends State<_PickManyDialog> {
  late final Set<String> _on = {...widget.chosen};

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 360,
      height: 400,
      child: ListSearchFilter(
        count: widget.all.length,
        builder: (context, q) => ListView(
          children: [
            for (final o in widget.all)
              if (q.isEmpty || searchSelectMatches(o.name, q))
                CheckboxListTile(
                  title: Text(o.name),
                  value: _on.contains(o.id),
                  onChanged: (v) => setState(() => v == true ? _on.add(o.id) : _on.remove(o.id)),
                ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => setState(_on.clear), child: const Text('All')),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, _on), child: const Text('Done')),
    ],
  );
}

/// One field: labels, text or date, what it is for, whether passengers see it.
class PermitFieldDialog extends StatefulWidget {
  const PermitFieldDialog({super.key, this.field, this.taken = const {}});
  final PermitField? field;
  final Set<String> taken;

  @override
  State<PermitFieldDialog> createState() => _PermitFieldDialogState();
}

class _PermitFieldDialogState extends State<PermitFieldDialog> {
  late final _label = TextEditingController(text: widget.field?.label ?? '');
  late final _local = TextEditingController(text: widget.field?.labelLocal ?? '');
  late bool _date = widget.field?.isDate ?? false;
  late PermitFieldRole _role = widget.field?.role ?? PermitFieldRole.none;
  late bool _passenger = widget.field?.passenger ?? true;

  @override
  void dispose() {
    _label.dispose();
    _local.dispose();
    super.dispose();
  }

  void _done() {
    var key = widget.field?.key ?? permitFieldKey(_label.text);
    var n = 2;
    final base = key;
    while (widget.taken.contains(key)) {
      key = '${base.length > 36 ? base.substring(0, 36) : base}_${n++}';
    }
    final f = PermitField(
      key: key,
      label: _label.text.trim(),
      labelLocal: _local.text.trim(),
      isDate: _role == PermitFieldRole.validFrom || _role == PermitFieldRole.validUntil ? true : _date,
      role: _role,
      passenger: _passenger,
    );
    final problem = permitFieldsProblem([f]);
    if (problem != null) return showError(context, problem);
    Navigator.pop(context, f);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.field == null ? 'Add field' : 'Edit field'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('permit-field-label'),
            controller: _label,
            decoration: const InputDecoration(labelText: 'Label (English)'),
          ),
          TextField(
            key: const ValueKey('permit-field-label-local'),
            controller: _local,
            decoration: const InputDecoration(labelText: 'Label as printed (local language)'),
          ),
          const SizedBox(height: 8),
          SearchableDropdownFormField<PermitFieldRole>(
            key: const ValueKey('permit-field-role'),
            initialValue: _role,
            decoration: const InputDecoration(labelText: 'What it is'),
            items: [for (final r in PermitFieldRole.values) DropdownMenuItem(value: r, child: Text(r.label))],
            onChanged: (v) => setState(() => _role = v ?? PermitFieldRole.none),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('A date'),
            value: _date || _role == PermitFieldRole.validFrom || _role == PermitFieldRole.validUntil,
            onChanged: _role == PermitFieldRole.validFrom || _role == PermitFieldRole.validUntil
                ? null
                : (v) => setState(() => _date = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Passengers see it'),
            value: _passenger,
            onChanged: (v) => setState(() => _passenger = v),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(key: const ValueKey('permit-field-done'), onPressed: _done, child: const Text('Done')),
    ],
  );
}

// ---- Plate colours -------------------------------------------------------------------------

class PlateColoursPage extends ConsumerWidget {
  const PlateColoursPage({super.key, required this.country});
  final String country;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final edit = ref.watch(pageAccessProvider(vehiclePermitsPage)) == AccessLevel.edit;
    final rows = ref.watch(adminPermitSettingsProvider).value ?? const <PermitCountrySettings>[];
    final own = rows.where((r) => r.country.toLowerCase() == country.toLowerCase()).firstOrNull?.plateColours;
    final fallback = plateSettingsFor(rows, PermitCountrySettings.everyCountry);
    return Scaffold(
      appBar: AppBar(title: Text('Plate colours · $country')),
      body: PlateColoursEditor(
        initial: own ?? fallback,
        ownColours: own != null,
        edit: edit,
        partnerTypes: ref.watch(adminPartnerTypeNamesProvider).value ?? const [],
        onSave: (colours) async {
          final ok = await runAdminAction(
            context,
            () => ref.read(permitsRepositoryProvider).saveCountrySettings(country, {'plate_colours': colours?.toJson()}),
            success: 'Plate colours saved',
          );
          if (ok) ref.invalidate(adminPermitSettingsProvider);
        },
      ),
    );
  }
}

/// The colour list: partner types (a taxi) first, then energies, then other.
class PlateColoursEditor extends StatefulWidget {
  const PlateColoursEditor({
    super.key,
    required this.initial,
    required this.onSave,
    this.ownColours = true,
    this.edit = true,
    this.partnerTypes = const [],
  });

  final PlateColourSettings initial;
  final bool ownColours;
  final bool edit;
  final List<String> partnerTypes;

  /// Null: use the default colours.
  final ValueChanged<PlateColourSettings?> onSave;

  @override
  State<PlateColoursEditor> createState() => _PlateColoursEditorState();
}

class _PlateColoursEditorState extends State<PlateColoursEditor> {
  late List<PlateColourRule> _types = [...widget.initial.types];
  late List<PlateColourRule> _energies = [...widget.initial.energies];
  late PlateColourRule _other = widget.initial.other ?? const PlateColourRule(match: '', bg: '#111111', fg: '#ffffff');
  late bool _own = widget.ownColours;

  PlateColourSettings get _settings => PlateColourSettings(types: _types, energies: _energies, other: _other);

  Future<PlateColourRule?> _edit(PlateColourRule? r, {required String what}) => showAppDialog<PlateColourRule>(
    id: 'vehicle-permits.plate-colour',
    context: context,
    builder: (_) => _PlateColourDialog(rule: r, what: what, suggestions: what == 'Partner type' ? widget.partnerTypes : const []),
  );

  Widget _row(PlateColourRule r, String label, {VoidCallback? onTap, VoidCallback? onRemove, Key? key}) {
    final c = plateColoursFor(PlateColourSettings(other: r));
    return ListTile(
      key: key,
      leading: PlateChip(plate: 'ABC 123', fontSize: 12, colours: c),
      title: Text(label),
      subtitle: Text('${r.bg} / ${r.fg}'),
      onTap: widget.edit && _own ? onTap : null,
      trailing: onRemove != null && widget.edit && _own
          ? IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: onRemove)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListView(
      key: const ValueKey('plate-colours'),
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          key: const ValueKey('plate-colours-own'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Colours of its own'),
          subtitle: const Text('Off: the default colours'),
          value: _own,
          onChanged: widget.edit ? (v) => setState(() => _own = v) : null,
        ),
        Text('By partner type (first match wins)', style: t.textTheme.titleSmall),
        for (final (i, r) in _types.indexed)
          _row(r, r.match,
              key: ValueKey('plate-type-${r.match}'),
              onTap: () async {
                final n = await _edit(r, what: 'Partner type');
                if (n != null) setState(() => _types = [..._types]..[i] = n);
              },
              onRemove: () => setState(() => _types = [..._types]..removeAt(i))),
        if (widget.edit && _own)
          TextButton.icon(
            key: const ValueKey('plate-type-add'),
            onPressed: () async {
              final n = await _edit(null, what: 'Partner type');
              if (n != null) setState(() => _types = [..._types, n]);
            },
            icon: const Icon(Icons.add),
            label: const Text('Add partner type'),
          ),
        const SizedBox(height: 8),
        Text('By energy', style: t.textTheme.titleSmall),
        for (final (i, r) in _energies.indexed)
          _row(r, r.match,
              key: ValueKey('plate-energy-${r.match}'),
              onTap: () async {
                final n = await _edit(r, what: 'Energy');
                if (n != null) setState(() => _energies = [..._energies]..[i] = n);
              },
              onRemove: () => setState(() => _energies = [..._energies]..removeAt(i))),
        if (widget.edit && _own)
          TextButton.icon(
            key: const ValueKey('plate-energy-add'),
            onPressed: () async {
              final n = await _edit(null, what: 'Energy');
              if (n != null) setState(() => _energies = [..._energies, n]);
            },
            icon: const Icon(Icons.add),
            label: const Text('Add energy'),
          ),
        const SizedBox(height: 8),
        Text('Any other vehicle', style: t.textTheme.titleSmall),
        _row(_other, 'Other', key: const ValueKey('plate-other'), onTap: () async {
          final n = await _edit(_other, what: 'Other');
          if (n != null) setState(() => _other = n);
        }),
        const SizedBox(height: 16),
        if (widget.edit)
          FilledButton(
            key: const ValueKey('plate-colours-save'),
            onPressed: () => widget.onSave(_own ? _settings : null),
            child: const Text('Save'),
          ),
      ],
    );
  }
}

class _PlateColourDialog extends StatefulWidget {
  const _PlateColourDialog({required this.what, this.rule, this.suggestions = const []});
  final String what;
  final PlateColourRule? rule;
  final List<String> suggestions;

  @override
  State<_PlateColourDialog> createState() => _PlateColourDialogState();
}

class _PlateColourDialogState extends State<_PlateColourDialog> {
  late final _match = TextEditingController(text: widget.rule?.match ?? '');
  late final _bg = TextEditingController(text: widget.rule?.bg ?? '#111111');
  late final _fg = TextEditingController(text: widget.rule?.fg ?? '#ffffff');

  @override
  void dispose() {
    _match.dispose();
    _bg.dispose();
    _fg.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = parseHexColour(_bg.text), fg = parseHexColour(_fg.text);
    return AlertDialog(
      title: Text(widget.what),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.what != 'Other')
            TextField(
              key: const ValueKey('plate-colour-match'),
              controller: _match,
              decoration: InputDecoration(
                labelText: widget.what == 'Energy' ? 'Energy, as in the make & model list' : 'Partner type',
                helperText: widget.suggestions.isEmpty ? null : widget.suggestions.join(', '),
              ),
            ),
          TextField(
            key: const ValueKey('plate-colour-bg'),
            controller: _bg,
            decoration: const InputDecoration(labelText: 'Plate colour', hintText: '#111111'),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            key: const ValueKey('plate-colour-fg'),
            controller: _fg,
            decoration: const InputDecoration(labelText: 'Letters colour', hintText: '#ffffff'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          if (bg != null && fg != null) PlateChip(plate: 'ABC 123', colours: (bg: bg, fg: fg)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('plate-colour-done'),
          onPressed: bg == null || fg == null || (widget.what != 'Other' && _match.text.trim().isEmpty)
              ? null
              : () => Navigator.pop(context, PlateColourRule(match: _match.text.trim(), bg: hexOf(bg), fg: hexOf(fg))),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

// ---- Uploading a vehicle permit ---------------------------------------------------------------

/// The admin uploads [type] for [vehicle]: the PDF, its fields (read by the
/// AI from the type's own labels, then checked) and saves. True when saved.
Future<bool?> showPermitUploadDialog(
  BuildContext context, {
  required VehiclePermits vehicle,
  required PermitType type,
  PermitItem? existing,
}) => showAppDialog<bool>(
  id: 'vehicle-permits.upload',
  context: context,
  builder: (_) => PermitUploadDialog(vehicle: vehicle, type: type, existing: existing),
);

class PermitUploadDialog extends ConsumerStatefulWidget {
  const PermitUploadDialog({super.key, required this.vehicle, required this.type, this.existing});
  final VehiclePermits vehicle;
  final PermitType type;
  final PermitItem? existing;

  @override
  ConsumerState<PermitUploadDialog> createState() => _PermitUploadDialogState();
}

class _PermitUploadDialogState extends ConsumerState<PermitUploadDialog> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _values = {
    for (final f in widget.type.fields)
      f.key: TextEditingController(
          text: widget.existing?.fields.where((v) => v.field.key == f.key).firstOrNull?.value ?? ''),
  };
  PickedPeopleFile? _pdf;
  bool _reading = false;
  bool _busy = false;
  String? _aiNote;
  DocumentAiResult? _ai;

  @override
  void dispose() {
    for (final c in _values.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick() async {
    final tools = ref.read(docPdfToolsProvider);
    final PickedPeopleFile? pdf;
    try {
      pdf = await tools.pick();
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (pdf == null || !mounted) return;
    final problem = docPdfProblem(pdf.name, pdf.bytes.length);
    if (problem != null) return showError(context, problem);
    setState(() {
      _pdf = pdf;
      _reading = true;
      _aiNote = null;
    });
    final png = await tools.firstPagePng(pdf.bytes);
    if (!mounted) return;
    if (png == null) {
      setState(() {
        _reading = false;
        _aiNote = "The PDF couldn't be read automatically. Enter the fields below.";
      });
      return;
    }
    final repo = ref.read(documentAiRepositoryProvider);
    final front = await repo.prepare(png, pdfPreviewName(pdf.name));
    final outcome = front == null
        ? (result: null, reason: 'image_too_large')
        : await repo.verify(docAiRequestBody(
            frontDataUrl: front,
            docName: widget.type.name,
            permitFields: [
              for (final f in widget.type.fields) (key: f.key, label: f.label, labelLocal: f.labelLocal, isDate: f.isDate),
            ],
          ));
    if (!mounted) return;
    final read = outcome.result?.permitFields ?? const <String, String?>{};
    setState(() {
      _reading = false;
      _ai = outcome.result;
      var filled = 0;
      for (final e in read.entries) {
        final c = _values[e.key];
        if (c != null && (e.value ?? '').isNotEmpty) {
          c.text = e.value!;
          filled++;
        }
      }
      _aiNote = outcome.result == null
          ? docAiUnavailableText(outcome.reason)
          : (filled == 0 ? 'Nothing could be read from the PDF. Enter the fields below.' : 'Read from the PDF; check the fields and save.');
    });
  }

  Future<void> _save() async {
    if (_form.currentState?.validate() == false) return;
    final pdf = _pdf;
    final existingLink = widget.existing == null ? null : permitFileLink(widget.existing!);
    if (pdf == null && existingLink == null) return showError(context, 'Choose the permit PDF.');
    final vehicleId = widget.vehicle.vehicleId!;
    setState(() => _busy = true);
    final ok = await runAdminAction(context, () async {
      var url = widget.existing?.fileUrl ?? existingLink!;
      if (pdf != null) {
        url = await ref.read(peopleRepositoryProvider).upload(
          'vehicle-documents',
          '$vehicleId/permits/${widget.type.key}-${DateTime.now().millisecondsSinceEpoch}.pdf',
          pdf,
        );
      }
      await ref.read(permitsRepositoryProvider).saveVehiclePermit(
        vehicleId: vehicleId,
        type: widget.type,
        fileUrl: url,
        values: {for (final e in _values.entries) e.key: e.value.text},
        ai: _ai?.raw,
      );
    }, success: '${widget.type.name} saved');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final plateField = widget.type.fields.where((f) => f.role == PermitFieldRole.plate).firstOrNull;
    final match = plateField == null ? null : platesMatch(_values[plateField.key]!.text, widget.vehicle.plate);
    final existingLink = widget.existing == null ? null : permitFileLink(widget.existing!);
    return AlertDialog(
      title: Text(widget.type.name),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PermitVehicleLine(plate: widget.vehicle.plate, colours: widget.vehicle.colours, label: widget.vehicle.label),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      key: const ValueKey('permit-pick-pdf'),
                      onPressed: _busy || _reading ? null : _pick,
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: Text(_pdf == null ? 'Choose PDF${widget.type.issuer.isEmpty ? '' : ' from ${widget.type.issuer}'}' : _pdf!.name),
                    ),
                    if (existingLink != null)
                      OutlinedButton(
                        onPressed: () => openStoredFile(context, existingLink, title: widget.type.name),
                        child: const Text('View current'),
                      ),
                  ],
                ),
                if (_reading) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
                if (_aiNote != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_aiNote!, key: const ValueKey('permit-ai-note'), style: t.textTheme.bodySmall),
                  ),
                const SizedBox(height: 12),
                for (final f in widget.type.fields)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: f.isDate
                        ? DateBoxesField(
                            key: ValueKey('permit-input-${f.key}'),
                            label: f.label,
                            controller: _values[f.key],
                            isRequired: f.role == PermitFieldRole.validUntil,
                            lastDate: f.role == PermitFieldRole.validFrom ? DateTime.now() : null,
                            helperText: f.labelLocal.isEmpty ? null : f.labelLocal,
                          )
                        : TextFormField(
                            key: ValueKey('permit-input-${f.key}'),
                            controller: _values[f.key],
                            decoration: InputDecoration(labelText: f.label, helperText: f.labelLocal.isEmpty ? null : f.labelLocal),
                            onChanged: (_) => setState(() {}),
                          ),
                  ),
                if (match != null)
                  Text(
                    match ? 'Plate on permit matches the vehicle' : 'Plate on permit is not ${widget.vehicle.plate}',
                    key: const ValueKey('permit-plate-check'),
                    style: t.textTheme.bodySmall?.copyWith(
                      color: match ? permitToneColours(PermitBadgeTone.ok, t.brightness).fg : t.colorScheme.error,
                    ),
                  ),
                if (widget.existing?.validUntil != null)
                  Text('Current permit valid until ${formatDateForUser(widget.existing!.validUntil)}', style: t.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('permit-save'),
          onPressed: _busy || _reading ? null : _save,
          child: const Text('Save permit'),
        ),
      ],
    );
  }
}
