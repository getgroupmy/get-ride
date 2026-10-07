import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'people_data.dart';
import 'people_logic.dart';
import 'people_widgets.dart';
import 'vehicle_drivers.dart';
import '../../../widgets/in_app_page.dart';

class VehicleFormData {
  const VehicleFormData({required this.partners, required this.geo, required this.requiredDocs, required this.vehicleDocTypeIds});
  final List<Map<String, dynamic>> partners;
  final GeoOptions geo;
  final List<({String id, Map<String, dynamic> values})> requiredDocs;
  final List<String> vehicleDocTypeIds;
}

final vehicleFormDataProvider = FutureProvider.autoDispose<VehicleFormData>((ref) async {
  final repo = ref.watch(peopleRepositoryProvider);
  final partners = await repo.partners();
  final docs = await repo.requiredDocuments();
  final types = await repo.documentTypes();
  final geo = await repo.geoOptions();
  return VehicleFormData(
    partners: partners,
    geo: geo,
    requiredDocs: docs,
    vehicleDocTypeIds: docTypeIdsNamed(types, 'Vehicle'),
  );
});

void _leave(BuildContext context) => context.canPop() ? context.pop(true) : context.go('/admin/vehicles');

/// Fields + owner + service area + checklist + permit/docs, shared by add and
/// edit (Expo `admin-vehicle-add` / `admin-vehicle-edit`).
class _VehicleForm extends ConsumerStatefulWidget {
  const _VehicleForm({required this.data, required this.page, this.row});
  final VehicleFormData data;
  final String page;
  final Map<String, dynamic>? row;

  @override
  ConsumerState<_VehicleForm> createState() => _VehicleFormState();
}

class _VehicleFormState extends ConsumerState<_VehicleForm> {
  Map<String, dynamic>? get r => widget.row;
  bool get _isEdit => r != null;
  String _s(String k) => '${r?[k] ?? ''}';

  late final _plate = TextEditingController(text: _s('plate'));
  late final _year = TextEditingController(text: _s('year'));
  late final _color = TextEditingController(text: _s('color'));
  late final _ownerName = TextEditingController(text: _s('owner_name'));
  late final _ownerPhone = TextEditingController(text: _s('owner_phone'));
  late final _partnerId = TextEditingController(text: _s('owner_partner_display_id'));
  late String? _ownerUuid = r?['owner_partner_id'] as String?;
  late MakeModel? _mm = r == null
      ? null
      : (vehicleType: _s('vehicle_type'), energyType: '', make: _s('make'), model: _s('model'), yearFrom: '', yearTo: '');
  late String _permit = r?['permit'] as String? ?? 'none';
  late String _status = r?['status'] as String? ?? 'unapproved';
  late bool _docsOk = r?['documents_ok'] == true;
  bool _autoApprove = false;
  late ServiceArea _area = ServiceArea.fromRow(r);
  bool _saving = false;
  bool _ownerFocused = false;

  @override
  void dispose() {
    for (final c in [_plate, _year, _color, _ownerName, _ownerPhone, _partnerId]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Resolves the typed partner display id to the partner uuid (Expo looks
  /// it up with `resolvePartnerSupabaseId`).
  Future<String?> _resolveOwner() async {
    final typed = _partnerId.text.trim();
    if (typed.isEmpty) return null;
    for (final p in widget.data.partners) {
      if (p['display_id'] == typed) return p['id'] as String;
    }
    if (_ownerUuid != null && typed == _s('owner_partner_display_id')) return _ownerUuid;
    return ref.read(peopleRepositoryProvider).partnerIdForDisplayId(typed);
  }

  Future<void> _save() async {
    final err = validateVehicleForm(
      plate: _plate.text,
      make: _mm?.make,
      model: _mm?.model,
      ownerName: _ownerName.text,
      ownerPhone: _ownerPhone.text,
    );
    if (err != null) return showError(context, err);
    final repo = ref.read(peopleRepositoryProvider);

    if (_isEdit && _status == 'approved' && r!['status'] != 'approved') {
      List<Map<String, dynamic>>? docs;
      try {
        docs = await repo.vehicleDocuments(r!['id'] as String);
      } catch (_) {}
      if (!mounted) return;
      final check = docs == null ? null : vehicleDocsCheck(docs);
      final unknownBlocked = check == null && !_docsOk;
      final msg = check?.blockMessage(_s('plate')) ??
          (unknownBlocked ? '${_s('plate')} has documents that still need review. Approve them first.' : null);
      if (msg != null) {
        final review = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(check != null && !check.hasAny ? 'No documents uploaded' : 'Documents not fully approved'),
            content: Text(msg),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Review documents')),
            ],
          ),
        );
        if (review == true && mounted) context.go('/admin/documents?kind=vehicle');
        return;
      }
    }

    setState(() => _saving = true);
    final ok = await runAdminAction(context, () async {
      final owner = await _resolveOwner();
      final cols = vehicleColumns(
        plate: _plate.text,
        make: _mm!.make,
        model: _mm!.model,
        vehicleType: _mm!.vehicleType,
        year: _year.text,
        color: _color.text,
        ownerName: _ownerName.text,
        ownerPhone: _ownerPhone.text,
        partnerDisplayId: _partnerId.text,
        ownerPartnerUuid: owner,
        status: _isEdit
            ? _status
            : newVehicleStatus(autoApprove: _autoApprove, documentsOk: _docsOk, permit: _permit),
        permit: _permit,
        documentsOk: _docsOk,
        area: _area,
      );
      if (_isEdit) {
        await repo.updateVehicle(r!['id'] as String, cols);
      } else {
        await repo.addVehicle(cols);
      }
    }, success: _isEdit ? 'Vehicle has been updated.' : 'Vehicle added.');
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) _leave(context);
  }

  Future<void> _delete() async {
    if (!await confirm(context, 'Delete vehicle', 'Remove ${_s('plate')}?', ok: 'Delete')) return;
    if (!mounted) return;
    final ok = await runAdminAction(context, () => ref.read(peopleRepositoryProvider).deleteVehicle(r!['id'] as String),
        success: 'Vehicle deleted');
    if (ok && mounted) _leave(context);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(widget.page)) == AccessLevel.edit;
    final t = Theme.of(context);
    final suggestions = _ownerFocused ? partnerSuggestions(widget.data.partners, _ownerName.text) : const [];
    final docs = resolveRequiredDocs(
      widget.data.requiredDocs,
      docTypeIds: widget.data.vehicleDocTypeIds.isEmpty ? const ['__none__'] : widget.data.vehicleDocTypeIds,
      countries: _area.countries,
      states: _area.statePairs(),
    );
    return AdminPage(
      title: _isEdit ? 'Edit Vehicle' : 'Add Vehicle',
      page: widget.page,
      actions: [
        if (_isEdit && canEdit)
          BusyIconButton(tooltip: 'Delete vehicle', icon: const Icon(Icons.delete_outline), onPressed: _delete),
      ],
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: ResponsiveCenter(
          maxWidth: 820,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_isEdit)
              Text('${_s('plate')} • ${r!['display_id'] ?? r!['id']}', style: t.textTheme.bodySmall),
            const SectionTitle('Vehicle'),
            MakeModelField(value: _mm, enabled: canEdit, onChanged: (m) => setState(() => _mm = m)),
            FormColumns(children: [
              PeopleField(
                  controller: _plate,
                  label: 'Plate number',
                  hint: 'WPK 1234',
                  icon: Icons.tag,
                  capitalization: TextCapitalization.characters,
                  enabled: canEdit),
              PeopleField(
                  controller: _year,
                  label: 'Year',
                  hint: '2022',
                  icon: Icons.calendar_today_outlined,
                  keyboardType: TextInputType.number,
                  enabled: canEdit),
              PeopleField(controller: _color, label: 'Colour', hint: 'White', icon: Icons.palette_outlined, enabled: canEdit),
            ]),
            const SectionTitle('Owner'),
            Focus(
              onFocusChange: (f) => setState(() => _ownerFocused = f),
              child: PeopleField(
                controller: _ownerName,
                label: 'Owner name',
                hint: 'Ahmad Faizal',
                icon: Icons.person_outline,
                enabled: canEdit,
                onChanged: (_) => setState(() {}),
              ),
            ),
            for (final p in suggestions)
              ListTile(
                dense: true,
                leading: const Icon(Icons.person_search_outlined),
                title: Text('${p['name'] ?? ''}'),
                subtitle: Text('${p['display_id'] ?? ''} • ${p['phone'] ?? ''}'),
                onTap: () => setState(() {
                  _ownerName.text = '${p['name'] ?? ''}';
                  _ownerPhone.text = '${p['phone'] ?? ''}';
                  _partnerId.text = '${p['display_id'] ?? ''}';
                  _ownerUuid = p['id'] as String?;
                  _ownerFocused = false;
                }),
              ),
            FormColumns(children: [
              PeopleField(
                  controller: _ownerPhone,
                  label: 'Owner phone',
                  hint: '+60 12-345 6781',
                  icon: Icons.phone_outlined,
                  keyboardType: TextInputType.phone,
                  capitalization: TextCapitalization.none,
                  enabled: canEdit),
              PeopleField(
                  controller: _partnerId,
                  label: _isEdit ? 'Partner ID' : 'Partner ID (optional)',
                  hint: 'PR-123456',
                  icon: Icons.tag,
                  capitalization: TextCapitalization.characters,
                  enabled: canEdit),
            ]),
            const SectionTitle('Service Area'),
            ServiceAreaField(
                value: _area, options: widget.data.geo.including(_area), enabled: canEdit, onChanged: (a) => setState(() => _area = a)),
            const SectionTitle('Required documents'),
            RequiredDocsChecklist(
              docs: docs,
              hasContext: _area.countries.isNotEmpty || _area.states.isNotEmpty,
              subtitle: 'Resolved from service area · per-region compulsory rules',
            ),
            if (_isEdit) ...[
              _VehiclePhotos(row: r!, enabled: canEdit),
              _VehicleDocumentsList(vehicleId: r!['id'] as String),
              VehicleDriversSection(vehicleId: r!['id'] as String, canEdit: canEdit),
              const SectionTitle('Status'),
              ChoiceChips(
                  options: vehicleStatusOptions, value: _status, enabled: canEdit, onChanged: (s) => setState(() => _status = s)),
            ],
            const SectionTitle('Permit'),
            ChoiceChips(options: permitOptions, value: _permit, enabled: canEdit, onChanged: (p) => setState(() => _permit = p)),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mark vehicle documents as reviewed'),
              value: _docsOk,
              onChanged: canEdit ? (v) => setState(() => _docsOk = v ?? false) : null,
            ),
            if (!_isEdit)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Activate vehicle immediately'),
                value: _autoApprove,
                onChanged: canEdit ? (v) => setState(() => _autoApprove = v ?? false) : null,
              ),
            const SizedBox(height: 16),
            if (canEdit)
              BusyButton.filled(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_outlined),
                child: Text(_saving ? 'Saving…' : (_isEdit ? 'Save Changes' : 'Add Vehicle')),
              ),
            const SizedBox(height: 32),
          ]),
        ),
      ),
    );
  }
}

/// The four vehicle photos (`vehicle.image_*`), uploaded to the
/// `vehicle-documents` bucket under `<vehicleId>/photos/` and saved at once.
class _VehiclePhotos extends ConsumerStatefulWidget {
  const _VehiclePhotos({required this.row, required this.enabled});
  final Map<String, dynamic> row;
  final bool enabled;

  @override
  ConsumerState<_VehiclePhotos> createState() => _VehiclePhotosState();
}

class _VehiclePhotosState extends ConsumerState<_VehiclePhotos> {
  late final Map<String, String?> _urls = {
    for (final s in vehiclePhotoSlots) s: widget.row['image_$s'] as String?,
  };
  String? _busy;

  Future<void> _replace(String slot) async {
    final file = await pickPeopleFile();
    if (file == null || !mounted) return;
    setState(() => _busy = slot);
    final id = widget.row['id'] as String;
    String? url;
    await runAdminAction(context, () async {
      final repo = ref.read(peopleRepositoryProvider);
      url = await repo.upload('vehicle-documents', vehiclePhotoPath(id, slot, guessExt(file.name)), file);
      await repo.updateVehicle(id, {'image_$slot': url});
    }, success: 'Photo saved');
    if (!mounted) return;
    setState(() {
      _busy = null;
      if (url != null) _urls[slot] = url;
    });
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionTitle('Vehicle photos'),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth >= 640 ? 4 : 2;
          final w = (c.maxWidth - (cols - 1) * 12) / cols;
          return Wrap(spacing: 12, runSpacing: 12, children: [
            for (final s in vehiclePhotoSlots)
              SizedBox(
                width: w,
                child: ImageSlot(
                  label: '${s[0].toUpperCase()}${s.substring(1)}',
                  url: _urls[s],
                  height: 110,
                  busy: _busy == s,
                  enabled: widget.enabled,
                  onPick: () => _replace(s),
                ),
              ),
          ]);
        }),
      ]);
}

final _vehicleDocsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>(
    (ref, id) => ref.watch(peopleRepositoryProvider).vehicleDocuments(id));

class _VehicleDocumentsList extends ConsumerWidget {
  const _VehicleDocumentsList({required this.vehicleId});
  final String vehicleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(_vehicleDocsProvider(vehicleId));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('Uploaded documents',
          trailing: TextButton(
              onPressed: () => context.go('/admin/documents?kind=vehicle'), child: const Text('Review documents'))),
      value.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(errorText(e)),
        data: (rows) {
          if (rows.isEmpty) return const Text('No vehicle documents on file.');
          final check = vehicleDocsCheck(rows);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${check.approved}/${check.total} approved', style: Theme.of(context).textTheme.bodySmall),
            for (final d in rows)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.description_outlined),
                title: Text('${d['doc_name'] ?? d['doc_id']}'),
                subtitle: Text([
                  if (d['document_number'] != null) 'No. ${d['document_number']}',
                  if (d['expiry_date'] != null) 'Expires ${d['expiry_date']}',
                  'Uploaded ${dateText(d['uploaded_at'])}',
                ].join(' · ')),
                trailing: Builder(builder: (context) {
                  final s = docDisplayStatus(d);
                  return Text(s, style: TextStyle(color: docStatusColor(s), fontWeight: FontWeight.w600));
                }),
                onTap: d['file_url'] == null ? null : () => openInApp(context, '${d['file_url']}'),
              ),
          ]);
        },
      ),
    ]);
  }
}

/// `admin-vehicle-add`.
class VehicleAddScreen extends ConsumerWidget {
  const VehicleAddScreen({super.key});
  static const page = 'admin-vehicle-add';

  @override
  Widget build(BuildContext context, WidgetRef ref) => pagedAsync(
        title: 'Loading…',
        page: page,
        value: ref.watch(vehicleFormDataProvider),
        onRetry: () => ref.invalidate(vehicleFormDataProvider),
        data: (data) => _VehicleForm(data: data, page: page),
      );
}

final _vehicleProvider = FutureProvider.autoDispose.family<Map<String, dynamic>?, String>(
    (ref, id) => ref.watch(peopleRepositoryProvider).vehicle(id));

/// `admin-vehicle-edit`.
class VehicleEditScreen extends ConsumerWidget {
  const VehicleEditScreen({super.key, required this.id});
  final String id;
  static const page = 'admin-vehicle-edit';

  @override
  Widget build(BuildContext context, WidgetRef ref) => pagedAsync(
        title: 'Loading…',
        page: page,
        value: ref.watch(_vehicleProvider(id)),
        onRetry: () => ref.invalidate(_vehicleProvider(id)),
        data: (row) => row == null
            ? AdminPage(
                title: 'Vehicle not found',
                page: page,
                body: EmptyState(icon: Icons.no_crash_outlined, title: "We couldn't find a vehicle with ID $id."),
              )
            : pagedAsync(
                title: 'Loading…',
                page: page,
                value: ref.watch(vehicleFormDataProvider),
                onRetry: () => ref.invalidate(vehicleFormDataProvider),
                data: (data) => _VehicleForm(data: data, page: page, row: row),
              ),
      );
}
