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
import '../../../data/live_tables.dart';

/// Everything the partner forms look up.
class PartnerFormData {
  const PartnerFormData({
    required this.typeValues,
    required this.vehicles,
    required this.geo,
    required this.requiredDocs,
  });
  final List<Map<String, dynamic>> typeValues;
  final List<Map<String, dynamic>> vehicles;
  final GeoOptions geo;
  final List<({String id, Map<String, dynamic> values})> requiredDocs;
}

final partnerFormDataProvider = FutureProvider.autoDispose<PartnerFormData>((ref) async {
  final repo = ref.watch(peopleRepositoryProvider);
  final types = await repo.partnerTypes();
  final vehicles = await repo.vehicles();
  final docs = await repo.requiredDocuments();
  final geo = await repo.geoOptions();
  return PartnerFormData(
    typeValues: [for (final t in types) t.values],
    vehicles: vehicles,
    geo: geo,
    requiredDocs: docs,
  );
});

/// Service area + partner types + vehicle (+ docs) block shared by the add
/// and edit forms, gated the same way the Expo forms are.
class _PartnerDetailsForm extends ConsumerWidget {
  const _PartnerDetailsForm({
    required this.data,
    required this.area,
    required this.types,
    required this.vehicle,
    required this.onArea,
    required this.onTypes,
    required this.onVehicle,
    required this.enabled,
    required this.docsBuilder,
  });
  final PartnerFormData data;
  final ServiceArea area;
  final List<String> types;
  final Map<String, dynamic>? vehicle;
  final ValueChanged<ServiceArea> onArea;
  final ValueChanged<List<String>> onTypes;
  final ValueChanged<Map<String, dynamic>?> onVehicle;
  final bool enabled;
  final Widget Function(List<RequiredDoc> docs, List<String>? docTypeIds) docsBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final geo = data.geo.including(area);
    final vehicleRequired = partnerTypesRequireVehicle(data.typeValues, types);
    final docTypeIds = partnerTypeDocTypeIds(data.typeValues, types);
    final docs = resolveRequiredDocs(
      data.requiredDocs,
      docTypeIds: docTypeIds,
      countries: area.countries,
      states: area.statePairs(),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Service Area'),
      Text('Select country, state and city of service', style: Theme.of(context).textTheme.bodySmall),
      ServiceAreaField(value: area, options: geo, onChanged: onArea, enabled: enabled),
      if (!area.complete)
        const Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text(
                'Pick at least one country, state and city above to continue with partner type and documents.'),
          ),
        )
      else ...[
        const SectionTitle('Partner Type'),
        PartnerTypeField(
            options: partnerTypeOptions(data.typeValues), value: types, onChanged: onTypes, enabled: enabled),
      ],
      if (area.complete && types.isNotEmpty && vehicleRequired) ...[
        SectionTitle('Vehicle',
            trailing: enabled
                ? TextButton.icon(
                    onPressed: () async {
                      await context.push('/admin/m/vehicle-add');
                      if (context.mounted) ref.invalidate(partnerFormDataProvider);
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add new'),
                  )
                : null),
        Text('Select from registered vehicles', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 6),
        VehicleSelector(vehicles: data.vehicles, selected: vehicle, onChanged: onVehicle, enabled: enabled),
      ],
      if (area.complete && types.isNotEmpty && (!vehicleRequired || vehicle != null)) docsBuilder(docs, docTypeIds),
    ]);
  }
}

void _leave(BuildContext context) => context.canPop() ? context.pop(true) : context.go('/admin/partners');

// ---- Add partner -----------------------------------------------------------

final _eligibleUsersProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  ref.watchAdminLive('profiles');
  ref.watchAdminLive('partners');
  final repo = ref.watch(peopleRepositoryProvider);
  final r = await Future.wait([repo.profiles(), repo.partners()]);
  return eligiblePartnerUsers(r[0], r[1]);
});

/// `admin-partner-add`: pick an existing user, set area/types/vehicle, then
/// upload the required documents for the new partner row.
class PartnerAddScreen extends ConsumerStatefulWidget {
  const PartnerAddScreen({super.key});
  static const page = 'admin-partner-add';

  @override
  ConsumerState<PartnerAddScreen> createState() => _PartnerAddScreenState();
}

class _PartnerAddScreenState extends ConsumerState<PartnerAddScreen> {
  Map<String, dynamic>? _user;
  String _query = '';
  ServiceArea _area = const ServiceArea();
  List<String> _types = const [];
  Map<String, dynamic>? _vehicle;
  bool _autoApprove = false;
  bool _saving = false;
  Map<String, dynamic>? _created;
  List<RequiredDoc> _createdDocs = const [];

  Future<void> _submit(PartnerFormData data) async {
    final vehicleRequired = partnerTypesRequireVehicle(data.typeValues, _types);
    final err = validatePartnerForm(
      hasUser: _user != null,
      area: _area,
      partnerTypes: _types,
      vehicleRequired: vehicleRequired,
      hasVehicle: _vehicle != null,
    );
    if (err != null) return showError(context, err);
    setState(() => _saving = true);
    Map<String, dynamic>? row;
    await runAdminAction(context, () async {
      row = await ref.read(peopleRepositoryProvider).addPartner(
            user: _user!,
            vehicle: _vehicle,
            partnerTypes: _types,
            area: _area,
            autoApprove: _autoApprove,
          );
    });
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (row != null) {
        _created = row;
        _createdDocs = resolveRequiredDocs(
          data.requiredDocs,
          docTypeIds: partnerTypeDocTypeIds(data.typeValues, _types),
          countries: _area.countries,
          states: _area.statePairs(),
        );
      }
    });
  }

  String get _subtitle => _created != null
      ? 'Step 2 of 2 · Upload required documents'
      : _user != null
          ? 'Step 1 of 2 · Partner details'
          : 'Select a user to onboard as partner';

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(PartnerAddScreen.page)) == AccessLevel.edit;
    return AdminPage(
      title: 'Add Partner',
      page: PartnerAddScreen.page,
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(_subtitle, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        Expanded(
          child: _created != null
              ? _docsStep(canEdit)
              : _user == null
                  ? _userStep()
                  : _formStep(canEdit),
        ),
      ]),
    );
  }

  Widget _userStep() {
    final value = ref.watch(_eligibleUsersProvider);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: TextField(
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search), hintText: 'Search users by name, phone, email…', isDense: true),
          onChanged: (v) => setState(() => _query = v),
        ),
      ),
      Expanded(
        child: AsyncView(
          value: value,
          onRetry: () => ref.invalidate(_eligibleUsersProvider),
          data: (users) {
            final q = _query.trim().toLowerCase();
            final list = q.isEmpty
                ? users
                : users
                    .where((u) => ['name', 'phone', 'email', 'ic'].any((k) => '${u[k] ?? ''}'.toLowerCase().contains(q)))
                    .toList();
            return ResponsiveCenter(
              maxWidth: 820,
              child: ListView.separated(
                itemCount: list.length + 1,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        list.isEmpty
                            ? 'No eligible users. Partners are created from existing app users who are not already partners.'
                            : '${list.length} eligible user${list.length == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    );
                  }
                  final u = list[i - 1];
                  final name = '${u['name'] ?? ''}';
                  return ListTile(
                    leading: CircleAvatar(child: Text(name.isEmpty ? '?' : name[0].toUpperCase())),
                    title: Text(name.isEmpty ? '(no name)' : name),
                    subtitle: Text('${u['phone'] ?? ''} • ${u['email'] ?? ''}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => setState(() => _user = u),
                  );
                },
              ),
            );
          },
        ),
      ),
    ]);
  }

  Widget _formStep(bool canEdit) {
    final value = ref.watch(partnerFormDataProvider);
    final u = _user!;
    return AsyncView(
      value: value,
      onRetry: () => ref.invalidate(partnerFormDataProvider),
      data: (data) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: ResponsiveCenter(
          maxWidth: 820,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                title: Text('${u['name'] ?? ''}'),
                subtitle: Text(
                    [u['phone'], u['email'], if (u['ic'] != null) 'IC ${u['ic']}'].whereType<Object>().join(' • ')),
                trailing: TextButton(onPressed: () => setState(() => _user = null), child: const Text('Change')),
              ),
            ),
            _PartnerDetailsForm(
              data: data,
              area: _area,
              types: _types,
              vehicle: _vehicle,
              enabled: canEdit,
              onArea: (a) => setState(() => _area = a),
              onTypes: (t) => setState(() => _types = t),
              onVehicle: (v) => setState(() => _vehicle = v),
              docsBuilder: (docs, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionTitle('Required documents'),
                RequiredDocsChecklist(
                  docs: docs,
                  hasContext: true,
                  subtitle: "Preview — you'll be able to upload these in the next step after the partner is created",
                ),
              ]),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-approve'),
              subtitle: const Text('Skip approval queue and activate immediately'),
              value: _autoApprove,
              onChanged: canEdit ? (v) => setState(() => _autoApprove = v ?? false) : null,
            ),
            const SizedBox(height: 12),
            if (canEdit)
              BusyButton.filled(
                onPressed: _saving ? null : () => _submit(data),
                icon: const Icon(Icons.person_add_alt_1_outlined),
                child: Text(_saving ? 'Creating…' : 'Create partner & continue'),
              ),
            const SizedBox(height: 32),
          ]),
        ),
      ),
    );
  }

  Widget _docsStep(bool canEdit) {
    final c = _created!;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: ResponsiveCenter(
        maxWidth: 820,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: Text('${c['name']} created'),
              subtitle: Text('Partner ID: ${c['display_id']} · ${_autoApprove ? 'Approved' : 'Pending approval'}\n'
                  "Now upload the partner's required documents below."),
              isThreeLine: true,
            ),
          ),
          PartnerDocsUploader(
            adminView: true,
            partnerId: c['id'] as String,
            docs: _createdDocs,
            enabled: canEdit,
            subtitle: 'Filtered by the selected service area',
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => _leave(context), child: const Text('Done')),
          const SizedBox(height: 32),
        ]),
      ),
    );
  }
}

// ---- Edit partner ----------------------------------------------------------

final _partnerProvider = FutureProvider.autoDispose.family<Map<String, dynamic>?, String>(
    (ref, id) => ref.watch(peopleRepositoryProvider).partner(id));

/// `admin-partner-edit`: service area, partner types, vehicle and documents.
class PartnerEditScreen extends ConsumerWidget {
  const PartnerEditScreen({super.key, required this.id});
  final String id;
  static const page = 'admin-partner-edit';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(_partnerProvider(id));
    final d = ref.watch(partnerFormDataProvider);
    return pagedAsync(
      title: 'Loading…',
      page: page,
      value: p,
      onRetry: () => ref.invalidate(_partnerProvider(id)),
      data: (partner) => partner == null
          ? AdminPage(
              title: 'Partner not found',
              page: page,
              body: EmptyState(icon: Icons.person_off_outlined, title: "We couldn't find a partner with ID $id."),
            )
          : pagedAsync(
              title: 'Loading…',
              page: page,
              value: d,
              onRetry: () => ref.invalidate(partnerFormDataProvider),
              data: (data) => _PartnerEditForm(partner: partner, data: data),
            ),
    );
  }
}

class _PartnerEditForm extends ConsumerStatefulWidget {
  const _PartnerEditForm({required this.partner, required this.data});
  final Map<String, dynamic> partner;
  final PartnerFormData data;

  @override
  ConsumerState<_PartnerEditForm> createState() => _PartnerEditFormState();
}

class _PartnerEditFormState extends ConsumerState<_PartnerEditForm> {
  Map<String, dynamic> get p => widget.partner;
  late ServiceArea _area = ServiceArea.fromRow(p);
  late List<String> _types = () {
    final list = parseStringList(p['partner_types']);
    if (list.isNotEmpty) return list;
    return '${p['partner_type'] ?? ''}'.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }();
  late Map<String, dynamic>? _vehicle = vehicleForPlate(widget.data.vehicles, p['plate']);
  bool _saving = false;

  Future<void> _save() async {
    final err = validatePartnerForm(
      hasUser: true,
      area: _area,
      partnerTypes: _types,
      vehicleRequired: partnerTypesRequireVehicle(widget.data.typeValues, _types),
      hasVehicle: _vehicle != null,
    );
    if (err != null) return showError(context, err);
    setState(() => _saving = true);
    final ok = await runAdminAction(
      context,
      () => ref.read(peopleRepositoryProvider).updatePartner(p['id'] as String, {
        ...partnerVehicleColumns(_vehicle),
        ...partnerTypeColumns(_types),
        ..._area.toRow(),
      }),
      success: 'Partner has been updated.',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref.invalidate(_partnerProvider(p['id'] as String));
      _leave(context);
    }
  }

  Future<void> _delete() async {
    if (!await confirm(context, 'Delete partner', 'Remove ${p['name']}?', ok: 'Delete')) return;
    if (!mounted) return;
    final ok = await runAdminAction(context, () => ref.read(peopleRepositoryProvider).deletePartner(p['id'] as String),
        success: 'Partner deleted');
    if (ok && mounted) _leave(context);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(PartnerEditScreen.page)) == AccessLevel.edit;
    final name = '${p['name'] ?? ''}';
    return AdminPage(
      title: 'Edit Partner',
      page: PartnerEditScreen.page,
      actions: [
        if (canEdit) BusyIconButton(tooltip: 'Delete partner', icon: const Icon(Icons.delete_outline), onPressed: _delete),
      ],
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: ResponsiveCenter(
          maxWidth: 820,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    CircleAvatar(child: Text(name.isEmpty ? '?' : name[0].toUpperCase())),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('$name • ${p['display_id'] ?? p['id']}', style: Theme.of(context).textTheme.titleMedium),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 6, children: [for (final t in _types) Chip(label: Text(t))]),
                  Text([p['phone'], p['email'], if (p['ic'] != null) 'IC ${p['ic']}'].whereType<Object>().join(' • ')),
                ]),
              ),
            ),
            _PartnerDetailsForm(
              data: widget.data,
              area: _area,
              types: _types,
              vehicle: _vehicle,
              enabled: canEdit,
              onArea: (a) => setState(() => _area = a),
              onTypes: (t) => setState(() => _types = t),
              onVehicle: (v) => setState(() => _vehicle = v),
              docsBuilder: (docs, _) => PartnerDocsUploader(
                adminView: true,
                key: ValueKey(docs.map((d) => d.id).join(',')),
                partnerId: p['id'] as String,
                docs: docs,
                enabled: canEdit,
                subtitle: 'Review, approve, or re-upload partner documents below.',
              ),
            ),
            const SizedBox(height: 16),
            if (canEdit)
              BusyButton.filled(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_outlined),
                child: Text(_saving ? 'Saving…' : 'Save changes'),
              ),
            const SizedBox(height: 32),
          ]),
        ),
      ),
    );
  }
}
