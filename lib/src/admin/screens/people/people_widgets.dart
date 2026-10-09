import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/document_ai.dart';
import '../../../core/partner_doc_check.dart';
import '../../../data/document_ai_repository.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/in_app_page.dart';
import '../../../widgets/loading_skeleton.dart';
import '../../widgets/admin_widgets.dart';
import 'doc_pdf.dart';
import 'people_data.dart';
import 'people_logic.dart';
import '../../../widgets/net_image.dart';

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
      content = Image.network(url!, fit: BoxFit.cover, frameBuilder: boneUntilPainted(), errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined));
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
      child: BusyListTile(
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

/// Partner document list with upload (Expo `RequiredDocsUploader`). Used by
/// the admin panel and by partners themselves; the partner's own documents
/// page adds the renewal lock and the action-needed summary.
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
    this.vehicleId,
    this.renewalLock = false,
    this.actionSummary = false,
    this.now,
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

  /// When set, these are the vehicle's documents (`vehicle_documents`,
  /// Expo `VehicleDocsUploader`) rather than the partner's own.
  final String? vehicleId;

  /// An approved document with an expiry date opens for replacement only in
  /// the [renewalWindowDays] before it expires (Expo
  /// `lockApprovedUntilExpiryWithinDays`); until then a tap shows the file.
  final bool renewalLock;

  /// Lists what still needs attention — missing, rejected, expired — above
  /// the documents (Expo's "Action needed" card).
  final bool actionSummary;

  /// Clock override for tests.
  final DateTime? now;

  @override
  ConsumerState<PartnerDocsUploader> createState() => _PartnerDocsUploaderState();
}

class _PartnerDocsUploaderState extends ConsumerState<PartnerDocsUploader> {
  late Future<List<Map<String, dynamic>>> _uploads = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final repo = ref.read(peopleRepositoryProvider);
    final vehicleId = widget.vehicleId;
    final rows =
        vehicleId == null ? await repo.providerDocuments(widget.partnerId) : await repo.vehicleDocuments(vehicleId);
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
        vehicleId: widget.vehicleId,
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
          if (!snap.hasData) return const LoadingSkeleton(rows: 2, leading: false);
          final uploads = latestUploadByDoc(snap.data!);
          final p = uploadProgress(widget.docs, uploads);
          final now = widget.now ?? DateTime.now();
          final issues = widget.actionSummary ? partnerDocIssues(widget.docs, snap.data!, now: now) : const <DocIssue>[];
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (issues.isNotEmpty) _ActionNeeded(issues: issues),
            SectionTitle(widget.title),
            Text(widget.subtitle ?? '${p.uploaded} uploaded · ${p.compulsoryLeft} compulsory left',
                style: t.textTheme.bodySmall),
            if (widget.docs.isEmpty)
              const Padding(padding: EdgeInsets.all(12), child: Text('No required documents for the selected region.')),
            for (final d in widget.docs)
              Builder(builder: (context) {
                final u = uploads[d.id];
                final status = u == null ? null : docDisplayStatus(u, now: now);
                final opens = widget.renewalLock && u != null ? renewalOpensOn(u, now: now) : null;
                return Card(
                  child: ListTile(
                    leading: Icon(d.compulsory ? Icons.gpp_maybe_outlined : Icons.verified_user_outlined,
                        color: d.compulsory ? Colors.orange : Colors.green),
                    title: Text(d.name),
                    subtitle: Text([
                      if (d.description.isNotEmpty) d.description,
                      d.labels.join(' · '),
                      if (u?['expiry_date'] != null) 'Expires: ${u!['expiry_date']}',
                      if (opens != null)
                        'Renewal opens ${opens.year}-${'${opens.month}'.padLeft(2, '0')}-${'${opens.day}'.padLeft(2, '0')}',
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
                    onTap: widget.enabled && opens == null
                        ? () => _open(d, u)
                        : (u?['file_url'] != null ? () => openInApp(context, '${u!['file_url']}') : null),
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
  const DocUploadDialog({
    super.key,
    required this.partnerId,
    required this.doc,
    this.existing,
    this.authUserId,
    this.vehicleId,
  });
  final String partnerId;
  final RequiredDoc doc;
  final Map<String, dynamic>? existing;
  final String? authUserId;

  /// Upload as one of this vehicle's documents (`vehicle-documents` bucket,
  /// `vehicle_documents` table) instead of the partner's.
  final String? vehicleId;

  @override
  ConsumerState<DocUploadDialog> createState() => _DocUploadDialogState();
}

class _DocUploadDialogState extends ConsumerState<DocUploadDialog> {
  PickedPeopleFile? _front, _back;

  /// The front is a PDF's first page (see doc_pdf.dart): a single file, so
  /// no back is asked for.
  bool _frontIsPdf = false;
  bool _rasterizing = false;
  late final _number = TextEditingController(text: '${widget.existing?['document_number'] ?? ''}');
  late final _start = TextEditingController(text: '${widget.existing?['start_date'] ?? ''}');
  late final _expiry = TextEditingController(text: '${widget.existing?['expiry_date'] ?? ''}');
  late String? _insurerId = widget.existing?['insurance_provider_id'] as String?;
  late bool _pwd = widget.existing?['is_pwd'] == true;
  bool _busy = false;
  List<({String id, Map<String, dynamic> values})> _insurers = const [];

  // The AI check of the picked photo(s), run on the server.
  DocumentAiResult? _ai;
  bool _aiRunning = false;
  String? _aiUnavailable;
  List<String> _aiFilled = const [];
  int _aiRun = 0;

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
      frontIsPdf: _frontIsPdf,
      documentNumber: _number.text,
      startDate: _start.text,
      expiryDate: _expiry.text,
      insuranceProviderId: _insurerId,
    );
    if (err != null) return showError(context, err);
    setState(() => _busy = true);
    final repo = ref.read(peopleRepositoryProvider);
    final ok = await runAdminAction(context, () async {
      final vehicleId = widget.vehicleId;
      final bucket = vehicleId == null ? 'provider-documents' : 'vehicle-documents';
      final owner = vehicleId ?? widget.partnerId;
      final frontUrl =
          await repo.upload(bucket, docFilePath(owner, widget.doc.id, 'front', guessExt(_front!.name)), _front!);
      String? backUrl;
      if (f.requireFrontBack && !_frontIsPdf && _back != null) {
        backUrl = await repo.upload(bucket, docFilePath(owner, widget.doc.id, 'back', guessExt(_back!.name)), _back!);
      }
      final insurer = _insurers.where((e) => e.id == _insurerId).firstOrNull;
      final payload = providerDocPayload(
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
        aiVerification: _ai?.raw,
        issuanceCountry: _ai?.issuanceCountry,
        detectedDocumentName: _ai?.detectedDocumentName,
      );
      if (vehicleId == null) {
        await repo.saveProviderDocument(payload);
      } else {
        await repo.saveVehicleDocument({...payload, 'vehicle_id': vehicleId});
      }
    }, success: 'Document uploaded');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  Future<void> _pick(bool back) async {
    final file = await pickPeopleFile();
    if (file == null) return;
    setState(() {
      if (back) {
        _back = file;
      } else {
        _front = file;
        _frontIsPdf = false;
      }
    });
    unawaited(_runAi());
  }

  /// Uploads a PDF in place of the photos: its first page becomes the front.
  Future<void> _pickPdf() async {
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
    setState(() => _rasterizing = true);
    final png = await tools.firstPagePng(pdf.bytes);
    if (!mounted) return;
    setState(() => _rasterizing = false);
    if (png == null) return showError(context, "That PDF couldn't be opened. Upload a photo of the document instead.");
    setState(() {
      _front = (bytes: png, name: pdfPreviewName(pdf!.name));
      _frontIsPdf = true;
      _back = null;
    });
    unawaited(_runAi());
  }

  /// Sends the picked photo(s) to the AI check and fills in what the partner
  /// left blank. Never blocks the upload: without a verdict an admin reviews
  /// it, as before.
  Future<void> _runAi() async {
    final front = _front;
    if (front == null) return;
    final f = widget.doc.flags;
    final run = ++_aiRun;
    setState(() {
      _aiRunning = true;
      _aiUnavailable = null;
    });
    final repo = ref.read(documentAiRepositoryProvider);
    final frontUrl = await repo.prepare(front.bytes, front.name);
    final back = f.requireFrontBack && !_frontIsPdf ? _back : null;
    final backUrl = back == null ? null : await repo.prepare(back.bytes, back.name);
    ({DocumentAiResult? result, String? reason}) outcome;
    if (frontUrl == null || (back != null && backUrl == null)) {
      outcome = (result: null, reason: 'image_too_large');
    } else {
      final insurer = _insurers.where((e) => e.id == _insurerId).firstOrNull;
      outcome = await repo.verify(docAiRequestBody(
        frontDataUrl: frontUrl,
        backDataUrl: backUrl,
        docName: widget.doc.name,
        documentNumber: f.requireDocumentNumber ? _number.text : null,
        insuranceProviderName: insurer == null ? null : '${insurer.values['name'] ?? ''}',
        isPwd: f.isPwd && _pwd,
        startDate: f.requireStartDate ? _start.text : null,
        expiryDate: f.requireExpiryDate ? _expiry.text : null,
      ));
    }
    if (!mounted || run != _aiRun) return;
    final r = outcome.result;
    setState(() {
      _aiRunning = false;
      _ai = r;
      _aiUnavailable = r == null ? docAiUnavailableText(outcome.reason) : null;
      if (r == null) return;
      final fill = docAiAutofill(
        r,
        requireDocumentNumber: f.requireDocumentNumber,
        requireStartDate: f.requireStartDate,
        requireExpiryDate: f.requireExpiryDate,
        requireInsuranceProvider: f.requireInsuranceProvider,
        pwdFlag: f.isPwd,
        documentNumber: _number.text,
        startDate: _start.text,
        expiryDate: _expiry.text,
        insurerId: _insurerId,
        isPwd: _pwd,
        insurers: [for (final e in _insurers) (id: e.id, name: '${e.values['name'] ?? ''}')],
      );
      if (fill.documentNumber != null) _number.text = fill.documentNumber!;
      if (fill.startDate != null) _start.text = fill.startDate!;
      if (fill.expiryDate != null) _expiry.text = fill.expiryDate!;
      if (fill.insurerId != null) _insurerId = fill.insurerId;
      if (fill.isPwd != null) _pwd = fill.isPwd!;
      _aiFilled = fill.filled;
    });
  }

  Widget _aiCard(BuildContext context) {
    final t = Theme.of(context);
    final r = _ai;
    if (_aiRunning) {
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LinearProgressIndicator(),
          SizedBox(height: 4),
          Text('Checking the document…'),
        ]),
      );
    }
    if (r == null && _aiUnavailable == null) return const SizedBox.shrink();
    final passed = r?.matchesTitle == true;
    final color = r == null ? t.colorScheme.outline : (passed ? Colors.green : Colors.orange);
    return Card(
      key: const ValueKey('doc-ai-result'),
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(r == null ? Icons.info_outline : (passed ? Icons.verified : Icons.report_problem_outlined), color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                r == null
                    ? 'Not checked'
                    : '${passed ? 'Looks right' : 'Please check'} · ${(r.confidence * 100).round()}%',
                style: t.textTheme.titleSmall?.copyWith(color: color),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Text(r == null ? _aiUnavailable! : (r.reason.isEmpty ? 'No additional details.' : r.reason)),
          if (r != null && r.detectedTitle.isNotEmpty) Text('Detected: ${r.detectedTitle}', style: t.textTheme.bodySmall),
          if (r != null && !passed)
            Text('You can still upload it; an admin will review it.', style: t.textTheme.bodySmall),
          if (_aiFilled.isNotEmpty)
            Text('Filled in from the document: ${_aiFilled.join(', ')}. Check before saving.',
                style: t.textTheme.bodySmall),
          if (r != null && widget.doc.flags.requireDocumentNumber && r.candidateNumbers.length > 1)
            Wrap(spacing: 6, children: [
              for (final n in r.candidateNumbers)
                ActionChip(label: Text(n), onPressed: () => setState(() => _number.text = n)),
            ]),
        ]),
      ),
    );
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
              if (f.requireFrontBack && !_frontIsPdf) ...[
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
            if (f.allowPdfUpload)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: BusyButton.text(
                    key: const ValueKey('doc-upload-pdf'),
                    onPressed: _busy || _rasterizing ? null : _pickPdf,
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    child: Text(_frontIsPdf ? 'PDF first page added — choose another PDF' : 'Upload a PDF instead'),
                  ),
                ),
              ),
            _aiCard(context),
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
        BusyButton.filled(onPressed: _busy || _aiRunning ? null : _save, child: Text(_busy ? 'Uploading…' : 'Save')),
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

/// What still needs the partner's attention (Expo "Action needed"):
/// compulsory first, each with what to do about it.
class _ActionNeeded extends StatelessWidget {
  const _ActionNeeded({required this.issues});
  final List<DocIssue> issues;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final compulsory = issues.where((i) => i.compulsory).length;
    return Card(
      key: const ValueKey('docs-action-needed'),
      color: t.colorScheme.errorContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.gpp_bad_outlined, size: 18, color: t.colorScheme.error),
            const SizedBox(width: 6),
            Text('Action needed', style: t.textTheme.titleSmall),
          ]),
          const SizedBox(height: 4),
          Text(
            compulsory > 0
                ? '$compulsory compulsory document${compulsory == 1 ? '' : 's'} still need${compulsory == 1 ? 's' : ''} your attention.'
                : 'Some optional documents are missing or need re-upload.',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          for (final i in issues)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Icon(Icons.circle, size: 8, color: i.compulsory ? t.colorScheme.error : t.colorScheme.outline),
                const SizedBox(width: 8),
                Expanded(child: Text(i.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                Text(
                  switch (i.reason) {
                    DocIssueReason.missing => 'Not uploaded',
                    DocIssueReason.rejected => 'Rejected — re-upload',
                    DocIssueReason.expired => 'Expired — renew',
                  },
                  key: ValueKey('docs-issue-${i.id}'),
                  style: t.textTheme.labelSmall?.copyWith(
                    color: switch (i.reason) {
                      DocIssueReason.missing => t.colorScheme.primary,
                      DocIssueReason.rejected => Colors.red,
                      DocIssueReason.expired => Colors.orange.shade800,
                    },
                  ),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}
