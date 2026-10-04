import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';
import 'people_data.dart';
import 'people_logic.dart';

/// Wide screens get a two-column form, phones one column.
class FormColumns extends StatelessWidget {
  const FormColumns({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        if (c.maxWidth < 640) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
        }
        return Wrap(spacing: 16, children: [
          for (final w in children) SizedBox(width: (c.maxWidth - 16) / 2, child: w),
        ]);
      });
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Row(children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
          ?trailing,
        ]),
      );
}

/// Standard labelled text field used across the forms.
class PeopleField extends StatelessWidget {
  const PeopleField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.icon,
    this.keyboardType,
    this.enabled = true,
    this.capitalization = TextCapitalization.words,
    this.onChanged,
  });
  final TextEditingController controller;
  final String label;
  final String? hint;
  final IconData? icon;
  final TextInputType? keyboardType;
  final bool enabled;
  final TextCapitalization capitalization;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: controller,
          enabled: enabled,
          keyboardType: keyboardType,
          textCapitalization: capitalization,
          onChanged: onChanged,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            prefixIcon: icon == null ? null : Icon(icon),
          ),
        ),
      );
}

/// Single-choice chips.
class ChoiceChips extends StatelessWidget {
  const ChoiceChips({super.key, required this.options, required this.value, required this.onChanged, this.enabled = true});
  final Map<String, String> options;
  final String? value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final e in options.entries)
          ChoiceChip(
            label: Text(e.value),
            selected: value == e.key,
            onSelected: enabled ? (_) => onChanged(e.key) : null,
          ),
      ]);
}

/// Shows a stored image URL (or a picked file) with a tap-to-replace action.
class ImageSlot extends StatelessWidget {
  const ImageSlot({
    super.key,
    required this.label,
    required this.url,
    required this.onPick,
    this.pending,
    this.busy = false,
    this.height = 140,
    this.width,
    this.enabled = true,
  });
  final String label;
  final String? url;
  final PickedPeopleFile? pending;
  final VoidCallback onPick;
  final bool busy;
  final double height;
  final double? width;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget content;
    if (pending != null && !isPdfUri(pending!.name)) {
      content = Image.memory(pending!.bytes, fit: BoxFit.cover);
    } else if (url != null && url!.startsWith('http') && !isPdfUri(url)) {
      content = Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined));
    } else if (url != null && url!.startsWith('data:image')) {
      content = const Center(child: Text('Embedded image'));
    } else if (pending != null || isPdfUri(url)) {
      content = const Center(child: Icon(Icons.picture_as_pdf_outlined, size: 36));
    } else {
      content = Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.add_a_photo_outlined, color: t.colorScheme.outline),
        const SizedBox(height: 4),
        Text(enabled ? 'Tap to upload' : 'No image', style: t.textTheme.bodySmall),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: t.textTheme.labelLarge),
      const SizedBox(height: 6),
      SizedBox(
        height: height,
        width: width,
        child: Material(
          color: t.colorScheme.surfaceContainerHighest,
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: enabled && !busy ? onPick : null,
            child: Stack(fit: StackFit.expand, children: [
              content,
              if (busy) const ColoredBox(color: Colors.black26, child: Center(child: CircularProgressIndicator())),
            ]),
          ),
        ),
      ),
    ]);
  }
}

// ---- Multi-select dialog ---------------------------------------------------

class SelectOption {
  const SelectOption(this.key, this.label, [this.subtitle]);
  final String key;
  final String label;
  final String? subtitle;
}

/// Searchable multi-select. [customKeys] turns a typed query into extra
/// keys the admin can add (e.g. a city missing from the geo tables).
Future<List<String>?> showMultiSelect(
  BuildContext context, {
  required String title,
  required List<SelectOption> options,
  required List<String> selected,
  List<SelectOption> Function(String query)? customKeys,
}) =>
    showDialog<List<String>>(
      context: context,
      builder: (ctx) => _MultiSelectDialog(title: title, options: options, selected: selected, customKeys: customKeys),
    );

class _MultiSelectDialog extends StatefulWidget {
  const _MultiSelectDialog({required this.title, required this.options, required this.selected, this.customKeys});
  final String title;
  final List<SelectOption> options;
  final List<String> selected;
  final List<SelectOption> Function(String query)? customKeys;

  @override
  State<_MultiSelectDialog> createState() => _MultiSelectDialogState();
}

class _MultiSelectDialogState extends State<_MultiSelectDialog> {
  late final List<String> _sel = [...widget.selected];
  late final List<SelectOption> _all = [
    ...widget.options,
    for (final k in widget.selected)
      if (!widget.options.any((o) => o.key == k)) SelectOption(k, areaLabel(k), k.contains('|') ? k : null),
  ];
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = q.isEmpty
        ? _all
        : _all.where((o) => o.label.toLowerCase().contains(q) || (o.subtitle ?? '').toLowerCase().contains(q)).toList();
    final extra = q.isEmpty || widget.customKeys == null
        ? const <SelectOption>[]
        : widget.customKeys!(_q.trim()).where((o) => !_all.any((a) => a.key == o.key)).toList();
    return AlertDialog(
      title: Text('${widget.title} · ${_sel.length} selected'),
      content: SizedBox(
        width: 460,
        height: 480,
        child: Column(children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search', isDense: true),
            onChanged: (v) => setState(() => _q = v),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(children: [
              for (final o in extra)
                ListTile(
                  leading: const Icon(Icons.add),
                  title: Text('Add "${o.label}"'),
                  subtitle: o.subtitle == null ? null : Text(o.subtitle!),
                  onTap: () => setState(() {
                    _all.add(o);
                    _sel.add(o.key);
                  }),
                ),
              for (final o in list)
                CheckboxListTile(
                  dense: true,
                  value: _sel.contains(o.key),
                  title: Text(o.label),
                  subtitle: o.subtitle == null ? null : Text(o.subtitle!),
                  onChanged: (v) => setState(() => v == true ? _sel.add(o.key) : _sel.remove(o.key)),
                ),
              if (list.isEmpty && extra.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No matches'))),
            ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _sel), child: const Text('Done')),
      ],
    );
  }
}

// ---- Service area ----------------------------------------------------------

class ServiceAreaField extends StatelessWidget {
  const ServiceAreaField({super.key, required this.value, required this.options, required this.onChanged, this.enabled = true});
  final ServiceArea value;
  final GeoOptions options;
  final ValueChanged<ServiceArea> onChanged;
  final bool enabled;

  Future<void> _pick(BuildContext context, String level) async {
    switch (level) {
      case 'country':
        final next = await showMultiSelect(
          context,
          title: 'Countries',
          options: [for (final c in options.countries) SelectOption(c, c)],
          selected: value.countries,
          customKeys: (q) => [SelectOption(q, q)],
        );
        if (next == null) return;
        var a = value;
        for (final c in {...a.countries, ...next}) {
          if (a.countries.contains(c) != next.contains(c)) a = a.toggleCountry(c);
        }
        onChanged(a);
      case 'state':
        final next = await showMultiSelect(
          context,
          title: 'States',
          options: [for (final s in options.statesFor(value)) SelectOption(s, areaLabel(s), s.split('|').first)],
          selected: value.states,
          customKeys: (q) => [for (final c in value.countries) SelectOption('$c|$q', q, c)],
        );
        if (next == null) return;
        var a = value;
        for (final s in {...a.states, ...next}) {
          if (a.states.contains(s) != next.contains(s)) a = a.toggleState(s);
        }
        onChanged(a);
      case 'city':
        final next = await showMultiSelect(
          context,
          title: 'Cities',
          options: [
            for (final c in options.citiesFor(value))
              SelectOption(c, areaLabel(c), c.split('|').take(2).toList().reversed.join(', ')),
          ],
          selected: value.cities,
          customKeys: (q) => [
            for (final s in value.states) SelectOption('$s|$q', q, s.split('|').reversed.join(', ')),
          ],
        );
        if (next == null) return;
        var a = value;
        for (final c in {...a.cities, ...next}) {
          if (a.cities.contains(c) != next.contains(c)) a = a.toggleCity(c);
        }
        onChanged(a);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget row(IconData icon, String label, int count, bool disabled, String level) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon),
          title: Text(label),
          subtitle: Text(count == 0 ? 'None selected' : '$count selected'),
          trailing: const Icon(Icons.expand_more),
          enabled: enabled && !disabled,
          onTap: () => _pick(context, level),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      row(Icons.public, 'Countries', value.countries.length, false, 'country'),
      row(Icons.map_outlined, 'States', value.states.length, value.countries.isEmpty, 'state'),
      row(Icons.location_city, 'Cities', value.cities.length, value.states.isEmpty, 'city'),
      if (!value.isEmpty)
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final c in value.countries)
            InputChip(
                avatar: const Icon(Icons.public, size: 16),
                label: Text(c),
                onDeleted: enabled ? () => onChanged(value.toggleCountry(c)) : null),
          for (final s in value.states)
            InputChip(
                avatar: const Icon(Icons.map_outlined, size: 16),
                label: Text(areaLabel(s)),
                onDeleted: enabled ? () => onChanged(value.toggleState(s)) : null),
          for (final c in value.cities)
            InputChip(
                avatar: const Icon(Icons.location_city, size: 16),
                label: Text(areaLabel(c)),
                onDeleted: enabled ? () => onChanged(value.toggleCity(c)) : null),
        ]),
    ]);
  }
}

// ---- Partner types ---------------------------------------------------------

class PartnerTypeField extends StatelessWidget {
  const PartnerTypeField({super.key, required this.options, required this.value, required this.onChanged, this.enabled = true});
  final List<String> options;
  final List<String> value;
  final ValueChanged<List<String>> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final all = [...options, ...value.where((v) => !options.contains(v))];
    if (all.isEmpty) return const Text('No partner types configured (Settings → Partner Type).');
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final t in all)
        FilterChip(
          label: Text(t),
          selected: value.contains(t),
          onSelected: enabled
              ? (on) => onChanged(on ? [...value, t] : value.where((v) => v != t).toList())
              : null,
        ),
    ]);
  }
}

// ---- Vehicle selector ------------------------------------------------------

class VehicleSelector extends StatefulWidget {
  const VehicleSelector({
    super.key,
    required this.vehicles,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
  });
  final List<Map<String, dynamic>> vehicles;
  final Map<String, dynamic>? selected;
  final ValueChanged<Map<String, dynamic>?> onChanged;
  final bool enabled;

  @override
  State<VehicleSelector> createState() => _VehicleSelectorState();
}

class _VehicleSelectorState extends State<VehicleSelector> {
  String _q = '';

  Widget _tile(Map<String, dynamic> v, {Widget? trailing, VoidCallback? onTap}) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const CircleAvatar(child: Icon(Icons.directions_car_outlined)),
        title: Text('${v['make'] ?? ''} ${v['model'] ?? ''}'.trim()),
        subtitle: Text('${v['plate'] ?? ''} • ${v['owner_name'] ?? ''}'),
        trailing: trailing,
        onTap: onTap,
      );

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    if (sel != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _tile(sel,
              trailing: IconButton(
                tooltip: 'Clear vehicle',
                icon: const Icon(Icons.close),
                onPressed: widget.enabled ? () => widget.onChanged(null) : null,
              )),
        ),
      );
    }
    final list = searchVehicles(widget.vehicles, _q);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search), hintText: 'Search by plate, make, model or owner', isDense: true),
        onChanged: (v) => setState(() => _q = v),
      ),
      const SizedBox(height: 6),
      if (list.isEmpty)
        const Padding(padding: EdgeInsets.all(12), child: Text('No matching vehicles. Tap "Add new" to register one.'))
      else
        for (final v in list) _tile(v, onTap: widget.enabled ? () => widget.onChanged(v) : null),
    ]);
  }
}

// ---- Vehicle make/model ----------------------------------------------------

typedef MakeModel = ({String vehicleType, String energyType, String make, String model, String yearFrom, String yearTo});

MakeModel makeModelFromRow(Map<String, dynamic> r) => (
      vehicleType: '${r['vehicle_type'] ?? ''}'.trim(),
      energyType: '${r['energy_type'] ?? ''}'.trim(),
      make: '${r['make'] ?? ''}'.trim(),
      model: '${r['model'] ?? ''}'.trim(),
      yearFrom: '${r['year_from'] ?? ''}'.trim(),
      yearTo: '${r['year_to'] ?? ''}'.trim(),
    );

String makeModelLabel(MakeModel m) =>
    formatVehicleLabel(make: m.make, model: m.model, yearFrom: m.yearFrom, yearTo: m.yearTo);

class MakeModelField extends ConsumerWidget {
  const MakeModelField({super.key, required this.value, required this.onChanged, this.enabled = true});
  final MakeModel? value;
  final ValueChanged<MakeModel> onChanged;
  final bool enabled;

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final rows = await ref.read(peopleRepositoryProvider).makeModels();
    if (!context.mounted) return;
    final picked = await showDialog<MakeModel>(
      context: context,
      builder: (ctx) {
        var q = '';
        return StatefulBuilder(builder: (ctx, setState) {
          final all = rows.map(makeModelFromRow).where((m) => m.make.isNotEmpty && m.model.isNotEmpty).toList();
          final list = all
              .where((m) => '${m.make} ${m.model} ${m.vehicleType} ${m.energyType}'.toLowerCase().contains(q.toLowerCase()))
              .toList();
          return AlertDialog(
            title: const Text('Select vehicle'),
            content: SizedBox(
              width: 460,
              height: 480,
              child: Column(children: [
                TextField(
                  autofocus: true,
                  decoration:
                      const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search make, model, type', isDense: true),
                  onChanged: (v) => setState(() => q = v),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: list.isEmpty
                      ? const Center(child: Text('No vehicle models (Settings → Vehicle Make & Model).'))
                      : ListView(children: [
                          for (final m in list)
                            ListTile(
                              title: Text(makeModelLabel(m)),
                              subtitle: Text([m.vehicleType, m.energyType].where((s) => s.isNotEmpty).join(' • ')),
                              onTap: () => Navigator.pop(ctx, m),
                            ),
                        ]),
                ),
              ]),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
          );
        });
      },
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = value;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: const Icon(Icons.directions_car_filled_outlined),
        title: Text(v == null || v.make.isEmpty ? 'Select make & model' : makeModelLabel(v)),
        subtitle: v == null ? null : Text([v.vehicleType, v.energyType].where((s) => s.isNotEmpty).join(' • ')),
        trailing: const Icon(Icons.expand_more),
        enabled: enabled,
        onTap: () => _pick(context, ref),
      ),
    );
  }
}

// ---- Required documents ----------------------------------------------------

Color docStatusColor(String s) => switch (s) {
      'Approved' => Colors.green,
      'Rejected' => Colors.red,
      'Expired' => Colors.orange,
      _ => Colors.blue,
    };

/// Read-only preview of the documents that apply (Expo `RequiredDocsChecklist`).
class RequiredDocsChecklist extends StatelessWidget {
  const RequiredDocsChecklist({super.key, required this.docs, required this.hasContext, this.subtitle});
  final List<RequiredDoc> docs;
  final bool hasContext;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final compulsory = docs.where((d) => d.compulsory).length;
    final optional = docs.length - compulsory;
    final sub = subtitle ??
        (hasContext
            ? '$compulsory compulsory · $optional optional for the selected region'
            : docs.isNotEmpty
                ? '$compulsory compulsory · $optional optional (preview — select a region to filter)'
                : 'No active documents configured');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(sub, style: Theme.of(context).textTheme.bodySmall),
      for (final d in docs)
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(d.compulsory ? Icons.gpp_maybe_outlined : Icons.verified_user_outlined,
              color: d.compulsory ? Colors.orange : Colors.green),
          title: Text(d.name),
          subtitle: Text([if (d.description.isNotEmpty) d.description, d.labels.join(' · ')].join('\n')),
          trailing: Text(d.compulsory ? 'Compulsory' : 'Optional', style: Theme.of(context).textTheme.labelSmall),
        ),
    ]);
  }
}

/// Partner document list with upload (Expo `RequiredDocsUploader`: no AI
/// verification, no renewal lock). Used by the admin panel and by partners
/// themselves during onboarding.
class PartnerDocsUploader extends ConsumerStatefulWidget {
  const PartnerDocsUploader({
    super.key,
    required this.partnerId,
    required this.docs,
    this.title = 'Required documents',
    this.subtitle,
    this.enabled = true,
    this.authUserId,
    this.onUploads,
  });
  final String partnerId;
  final List<RequiredDoc> docs;
  final String title;
  final String? subtitle;
  final bool enabled;

  /// Stored on each upload when a partner uploads their own documents; the
  /// admin panel leaves it null.
  final String? authUserId;

  /// The newest upload per document, each time the list loads.
  final ValueChanged<Map<String, Map<String, dynamic>>>? onUploads;

  @override
  ConsumerState<PartnerDocsUploader> createState() => _PartnerDocsUploaderState();
}

class _PartnerDocsUploaderState extends ConsumerState<PartnerDocsUploader> {
  late Future<List<Map<String, dynamic>>> _uploads = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final rows = await ref.read(peopleRepositoryProvider).providerDocuments(widget.partnerId);
    widget.onUploads?.call(latestUploadByDoc(rows));
    return rows;
  }

  Future<void> _open(RequiredDoc d, Map<String, dynamic>? existing) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => DocUploadDialog(
        partnerId: widget.partnerId,
        doc: d,
        existing: existing,
        authUserId: widget.authUserId,
      ),
    );
    if (saved == true && mounted) setState(() => _uploads = _load());
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
        future: _uploads,
        builder: (context, snap) {
          final t = Theme.of(context);
          if (snap.hasError) return Text(errorText(snap.error!));
          if (!snap.hasData) return const LinearProgressIndicator();
          final uploads = latestUploadByDoc(snap.data!);
          final p = uploadProgress(widget.docs, uploads);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SectionTitle(widget.title),
            Text(widget.subtitle ?? '${p.uploaded} uploaded · ${p.compulsoryLeft} compulsory left',
                style: t.textTheme.bodySmall),
            if (widget.docs.isEmpty)
              const Padding(padding: EdgeInsets.all(12), child: Text('No required documents for the selected region.')),
            for (final d in widget.docs)
              Builder(builder: (context) {
                final u = uploads[d.id];
                final status = u == null ? null : docDisplayStatus(u);
                return Card(
                  child: ListTile(
                    leading: Icon(d.compulsory ? Icons.gpp_maybe_outlined : Icons.verified_user_outlined,
                        color: d.compulsory ? Colors.orange : Colors.green),
                    title: Text(d.name),
                    subtitle: Text([
                      if (d.description.isNotEmpty) d.description,
                      d.labels.join(' · '),
                      if (u?['expiry_date'] != null) 'Expires: ${u!['expiry_date']}',
                      d.compulsory ? 'Compulsory' : 'Optional',
                    ].join('\n')),
                    isThreeLine: true,
                    trailing: status == null
                        ? Text(widget.enabled ? 'Tap to upload' : 'Not uploaded', style: t.textTheme.labelSmall)
                        : Chip(
                            label: Text(status),
                            labelStyle: TextStyle(color: docStatusColor(status), fontSize: 12),
                            visualDensity: VisualDensity.compact,
                          ),
                    onTap: widget.enabled ? () => _open(d, u) : (u?['file_url'] != null ? () => launchUrl(Uri.parse('${u!['file_url']}')) : null),
                  ),
                );
              }),
          ]);
        },
      );
}

/// Upload form for one provider document (front/back image + the fields the
/// requirement asks for). Saves to `provider-documents` storage and upserts
/// `provider_documents` with status Pending Review.
class DocUploadDialog extends ConsumerStatefulWidget {
  const DocUploadDialog({super.key, required this.partnerId, required this.doc, this.existing, this.authUserId});
  final String partnerId;
  final RequiredDoc doc;
  final Map<String, dynamic>? existing;
  final String? authUserId;

  @override
  ConsumerState<DocUploadDialog> createState() => _DocUploadDialogState();
}

class _DocUploadDialogState extends ConsumerState<DocUploadDialog> {
  PickedPeopleFile? _front, _back;
  late final _number = TextEditingController(text: '${widget.existing?['document_number'] ?? ''}');
  late final _start = TextEditingController(text: '${widget.existing?['start_date'] ?? ''}');
  late final _expiry = TextEditingController(text: '${widget.existing?['expiry_date'] ?? ''}');
  late String? _insurerId = widget.existing?['insurance_provider_id'] as String?;
  late bool _pwd = widget.existing?['is_pwd'] == true;
  bool _busy = false;
  List<({String id, Map<String, dynamic> values})> _insurers = const [];

  @override
  void initState() {
    super.initState();
    if (widget.doc.flags.requireInsuranceProvider) {
      ref.read(peopleRepositoryProvider).insuranceProviders().then((v) {
        if (mounted) setState(() => _insurers = v);
      }, onError: (_) {});
    }
  }

  @override
  void dispose() {
    _number.dispose();
    _start.dispose();
    _expiry.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final f = widget.doc.flags;
    final err = validateDocUpload(
      f,
      hasFront: _front != null,
      hasBack: _back != null,
      frontIsPdf: false,
      documentNumber: _number.text,
      startDate: _start.text,
      expiryDate: _expiry.text,
      insuranceProviderId: _insurerId,
    );
    if (err != null) return showError(context, err);
    setState(() => _busy = true);
    final repo = ref.read(peopleRepositoryProvider);
    final ok = await runAdminAction(context, () async {
      final frontUrl = await repo.upload('provider-documents',
          docFilePath(widget.partnerId, widget.doc.id, 'front', guessExt(_front!.name)), _front!);
      String? backUrl;
      if (f.requireFrontBack && _back != null) {
        backUrl = await repo.upload(
            'provider-documents', docFilePath(widget.partnerId, widget.doc.id, 'back', guessExt(_back!.name)), _back!);
      }
      final insurer = _insurers.where((e) => e.id == _insurerId).firstOrNull;
      await repo.saveProviderDocument(providerDocPayload(
        partnerId: widget.partnerId,
        authUserId: widget.authUserId,
        docId: widget.doc.id,
        docName: widget.doc.name,
        flags: f,
        documentNumber: _number.text,
        insuranceProviderId: _insurerId,
        insuranceProviderName: insurer == null ? null : '${insurer.values['name'] ?? ''}',
        isPwd: _pwd,
        startDate: _start.text,
        expiryDate: _expiry.text,
        fileUrl: frontUrl,
        fileUrlBack: backUrl,
        uploadedAt: DateTime.now().toUtc().toIso8601String(),
      ));
    }, success: 'Document uploaded');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  Future<void> _pick(bool back) async {
    final file = await pickPeopleFile();
    if (file != null) setState(() => back ? _back = file : _front = file);
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.doc.flags;
    final dateFormatter = [FilteringTextInputFormatter.allow(RegExp(r'[0-9-]'))];
    return AlertDialog(
      title: Text(widget.doc.name),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.existing != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('Current status: ${docDisplayStatus(widget.existing!)}. A new upload resets it to Pending Review.'),
              ),
            Row(children: [
              Expanded(
                child: ImageSlot(
                  label: f.requireFrontBack ? 'Front' : 'Document image',
                  url: widget.existing?['file_url'] as String?,
                  pending: _front,
                  onPick: () => _pick(false),
                ),
              ),
              if (f.requireFrontBack) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: ImageSlot(
                    label: 'Back',
                    url: widget.existing?['file_url_back'] as String?,
                    pending: _back,
                    onPick: () => _pick(true),
                  ),
                ),
              ],
            ]),
            const SizedBox(height: 12),
            if (f.requireDocumentNumber)
              PeopleField(controller: _number, label: 'Document number', capitalization: TextCapitalization.characters),
            if (f.requireStartDate)
              PeopleField(controller: _start, label: 'Start date', hint: 'YYYY-MM-DD', keyboardType: TextInputType.datetime),
            if (f.requireExpiryDate)
              TextField(
                controller: _expiry,
                inputFormatters: dateFormatter,
                decoration: const InputDecoration(labelText: 'Expiry date', hintText: 'YYYY-MM-DD'),
              ),
            if (f.requireInsuranceProvider) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _insurers.any((e) => e.id == _insurerId) ? _insurerId : null,
                decoration: const InputDecoration(labelText: 'Insurance provider'),
                items: [
                  for (final e in _insurers) DropdownMenuItem(value: e.id, child: Text('${e.values['name'] ?? e.id}')),
                ],
                onChanged: (v) => setState(() => _insurerId = v),
              ),
            ],
            if (f.isPwd)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Person with disability (PWD)'),
                value: _pwd,
                onChanged: (v) => setState(() => _pwd = v),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Uploading…' : 'Save')),
      ],
    );
  }
}

/// Loading / error states inside an [AdminPage]; the loaded data builds its
/// own page (with its own actions).
Widget pagedAsync<T>({
  required String title,
  required String page,
  required AsyncValue<T> value,
  required VoidCallback onRetry,
  required Widget Function(T data) data,
}) =>
    value.hasValue && !value.isLoading
        ? data(value.requireValue)
        : AdminPage(
            title: title,
            page: page,
            body: AsyncView(value: value, onRetry: onRetry, data: (_) => const SizedBox.shrink()),
          );
