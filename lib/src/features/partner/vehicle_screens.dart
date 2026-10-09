import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/screens/people/people_data.dart';
import '../../admin/screens/people/people_logic.dart';
import '../../admin/screens/people/people_widgets.dart';
import '../../core/partner_onboarding.dart';
import '../../core/vehicle_onboarding.dart';
import '../../data/partner_onboarding_repository.dart';
import '../../data/vehicle_onboarding_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/loading_skeleton.dart';
import '../../widgets/side_menu_host.dart';

typedef _Entries = List<({String id, Map<String, dynamic> values})>;

Color _toneColor(VehicleApprovalTone t) => switch (t) {
      VehicleApprovalTone.approved => Colors.green,
      VehicleApprovalTone.rejected || VehicleApprovalTone.blocked => Colors.red,
      VehicleApprovalTone.pending => Colors.blue,
    };

String _vehicleTitle(Map<String, dynamic> v) {
  final name = '${v['make'] ?? ''} ${v['model'] ?? ''}'.trim();
  return name.isEmpty ? 'New vehicle' : name;
}

// ---- My vehicles -------------------------------------------------------------

/// The partner's vehicles (the Expo side menu's vehicle picker): each one's
/// review status, or the step it stopped at, and a way to add another.
class VehiclesScreen extends ConsumerStatefulWidget {
  const VehiclesScreen({super.key});

  @override
  ConsumerState<VehiclesScreen> createState() => _VehiclesScreenState();
}

class _VehiclesScreenState extends ConsumerState<VehiclesScreen> {
  late Future<List<Map<String, dynamic>>> _vehicles = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final s = await ref.read(partnerOnboardingRepositoryProvider).load();
    return ref.read(vehicleOnboardingRepositoryProvider).myVehicles(s.partnerId);
  }

  Future<void> _open(String location) async {
    await context.push(location);
    if (mounted) setState(() => _vehicles = _load());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(leading: sideMenuLeading(context), title: const Text('My vehicles')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _open('/drive/vehicles/new'),
          icon: const Icon(Icons.add),
          label: const Text('Add vehicle'),
        ),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _vehicles,
          builder: (context, snap) {
            if (snap.hasError) {
              return EmptyState(
                icon: Icons.cloud_off,
                title: 'Could not load your vehicles',
                message: errorText(snap.error!),
                action: FilledButton(
                    onPressed: () => setState(() => _vehicles = _load()), child: const Text('Try again')),
              );
            }
            if (!snap.hasData) return const LoadingSkeletonPage();
            final list = snap.data!;
            if (list.isEmpty) {
              return const EmptyState(
                icon: Icons.directions_car_outlined,
                title: 'No vehicles yet',
                message: 'Add the vehicle you will drive. An admin reviews it before you can use it.',
              );
            }
            return ResponsiveCenter(
              maxWidth: 640,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
                for (final v in list)
                  Builder(builder: (context) {
                    final step = firstVehicleStep(v);
                    final approval = vehicleApproval(v);
                    return Card(
                      child: ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.directions_car_outlined)),
                        title: Text('${v['plate'] ?? ''}'),
                        subtitle: Text(_vehicleTitle(v)),
                        trailing: step == VehicleStep.done
                            ? Chip(
                                label: Text(approval.label),
                                labelStyle: TextStyle(color: _toneColor(approval.tone), fontSize: 12),
                                visualDensity: VisualDensity.compact,
                              )
                            : Chip(
                                label: Text('Incomplete: ${step.label}'),
                                visualDensity: VisualDensity.compact,
                              ),
                        onTap: () => _open('/drive/vehicles/${v['id']}'),
                      ),
                    );
                  }),
              ]),
            );
          },
        ),
      );
}

// ---- The wizard ----------------------------------------------------------------

/// Registering a vehicle (Expo `app/vehicle-onboarding.tsx`): plate, make &
/// model, year & colour, four photos, owner and the vehicle documents, then
/// submitted for review. With [vehicleId] it resumes that vehicle, or shows
/// its review status once everything is in.
class VehicleOnboardingScreen extends ConsumerStatefulWidget {
  const VehicleOnboardingScreen({super.key, this.vehicleId});
  final String? vehicleId;

  @override
  ConsumerState<VehicleOnboardingScreen> createState() => _VehicleOnboardingScreenState();
}

class _VehicleOnboardingScreenState extends ConsumerState<VehicleOnboardingScreen> {
  OnboardingState? _ctx;
  Map<String, dynamic>? _v;
  Object? _loadError;
  bool _loaded = false;
  bool _busy = false;
  String? _uploadingSlot;
  VehicleStep? _viewing;

  final _plate = TextEditingController();
  final _year = TextEditingController();
  final _color = TextEditingController();
  final _ownerName = TextEditingController();
  final _ownerPhone = TextEditingController();
  final _ownerIc = TextEditingController();
  MakeModel? _makeModel;
  bool? _ownVehicle;

  _Entries _requiredDocs = const [];
  Set<String> _vehicleTypeIds = const {};
  bool _docsComplete = false;

  VehicleOnboardingRepository get _repo => ref.read(vehicleOnboardingRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_plate, _year, _color, _ownerName, _ownerPhone, _ownerIc]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final ctx = await ref.read(partnerOnboardingRepositoryProvider).load();
      final people = ref.read(peopleRepositoryProvider);
      final id = widget.vehicleId;
      final settled = await Future.wait<Object?>([
        people.requiredDocuments(),
        people.documentTypes(),
        if (id != null) _repo.vehicle(id),
      ]);
      final v = id == null ? null : settled[2] as Map<String, dynamic>?;
      if (id != null && v == null) throw StateError('This vehicle was not found.');
      if (!mounted) return;
      setState(() {
        _ctx = ctx;
        _requiredDocs = settled[0] as _Entries;
        _vehicleTypeIds = vehicleDocTypeIds(settled[1] as _Entries);
        _hydrate(v);
        _loaded = true;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _hydrate(Map<String, dynamic>? v) {
    _v = v;
    if (v == null) return;
    String t(String k) => '${v[k] ?? ''}';
    _plate.text = t('plate');
    _year.text = t('year');
    _color.text = t('color');
    _ownerName.text = t('owner_name');
    _ownerPhone.text = t('owner_phone');
    _ownerIc.text = t('owner_ic');
    if (t('make').isNotEmpty) _makeModel = makeModelFromRow(v);
  }

  Future<void> _save(Future<Map<String, dynamic>> Function() action, {VehicleStep? stayOn}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final v = await action();
      if (!mounted) return;
      setState(() {
        _hydrate(v);
        _viewing = stayOn;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- Steps -----------------------------------------------------------------

  Future<void> _savePlate() async {
    final plate = normalizePlate(_plate.text);
    if (plate.isEmpty) return showError(context, 'Please enter the plate number.');
    await _save(() => _repo.startWithPlate(plate, _ctx!.partner));
  }

  Future<void> _saveMakeModel() async {
    final m = _makeModel;
    if (m == null || m.make.isEmpty) return showError(context, 'Please select the make and model.');
    await _save(() => _repo.patch(_v!, {
          'make': m.make,
          'model': m.model,
          'vehicle_type': m.vehicleType.isEmpty ? null : m.vehicleType,
        }));
  }

  Future<void> _saveYearColor() async {
    final year = _year.text.trim(), color = _color.text.trim();
    final problem = vehicleYearColorProblem(year, color);
    if (problem != null) return showError(context, problem);
    await _save(() => _repo.patch(_v!, {'year': year, 'color': color}));
  }

  Future<void> _uploadPhoto(String slot) async {
    final file = await pickPeopleFile(context);
    if (file == null || !mounted) return;
    setState(() => _uploadingSlot = slot);
    // Stay on the photos step while they are being added, even once the
    // fourth one completes it.
    await _save(() async {
      final url = await _repo.uploadPhoto(_v!['id'] as String, slot, file.bytes, file.name);
      return _repo.patch(_v!, {'image_$slot': url});
    }, stayOn: VehicleStep.photos);
    if (mounted) setState(() => _uploadingSlot = null);
  }

  void _chooseOwn(bool own) {
    setState(() {
      _ownVehicle = own;
      final d = own ? ownOwnerDetails(_ctx?.partner, _ctx?.profile) : (name: '', phone: '', ic: '');
      _ownerName.text = d.name;
      _ownerPhone.text = d.phone;
      _ownerIc.text = d.ic;
    });
  }

  Future<void> _saveOwner() async {
    final name = _ownerName.text.trim(), phone = _ownerPhone.text.trim(), ic = _ownerIc.text.trim();
    final problem = vehicleOwnerProblem(ownVehicle: _ownVehicle, name: name, phone: phone, ic: ic);
    if (problem != null) return showError(context, problem);
    await _save(() => _repo.patch(_v!, {'owner_name': name, 'owner_phone': phone, 'owner_ic': ic}));
  }

  Future<void> _submit() async {
    if (!_docsComplete) return showError(context, 'Please upload every compulsory document before submitting.');
    await _save(() => _repo.patch(_v!, {'documents_ok': true}));
  }

  /// Leaves the wizard: an approved vehicle goes to the Drive tab, read
  /// fresh so an approval made while the screen was open counts.
  Future<void> _finish() async {
    var v = _v!;
    try {
      v = await _repo.vehicle(v['id'] as String) ?? v;
    } catch (_) {}
    if (!mounted) return;
    final route = vehicleFinishRoute(v);
    if (route != null) {
      context.go(route);
    } else if (context.canPop()) {
      context.pop();
    } else {
      context.go('/drive/vehicles');
    }
  }

  List<RequiredDoc> _docs() => vehicleRequiredDocs(
        requiredDocuments: _requiredDocs,
        vehicleTypeIds: _vehicleTypeIds,
        partnerTypes: parseStringList(_ctx?.partner['partner_types']),
        area: ServiceArea.fromRow(_ctx?.partner),
      );

  // ---- Layout ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_loadError != null) {
      body = EmptyState(
        icon: Icons.cloud_off,
        title: 'Could not load the vehicle',
        message: errorText(_loadError!),
        action: BusyButton.filled(onPressed: _load, child: const Text('Try again')),
      );
    } else if (!_loaded) {
      body = const LoadingSkeletonPage();
    } else {
      final reached = firstVehicleStep(_v);
      final step = _viewing ?? reached;
      body = ResponsiveCenter(
        maxWidth: 640,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          _header(reached, step),
          const SizedBox(height: 16),
          if (_busy) const LinearProgressIndicator(),
          _stepBody(step),
        ]),
      );
    }
    final plate = '${_v?['plate'] ?? ''}';
    return Scaffold(appBar: AppBar(title: Text(plate.isEmpty ? 'Add vehicle' : plate)), body: body);
  }

  Widget _header(VehicleStep reached, VehicleStep showing) {
    final t = Theme.of(context);
    final steps = VehicleStep.wizard;
    final reachedIndex = reached == VehicleStep.done ? steps.length : steps.indexOf(reached);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(reached == VehicleStep.done ? 'All steps complete' : 'Step ${reachedIndex + 1} of ${steps.length}',
          style: t.textTheme.labelLarge),
      const SizedBox(height: 8),
      LinearProgressIndicator(value: reachedIndex / steps.length),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (i, step) in steps.indexed)
          ChoiceChip(
            avatar: i < reachedIndex ? const Icon(Icons.check, size: 16) : null,
            label: Text(step.label),
            selected: step == showing,
            // The plate is fixed once the vehicle exists; other finished
            // steps can be reopened.
            onSelected: i <= reachedIndex && !_busy && step != VehicleStep.plate
                ? (_) => setState(() => _viewing = step == reached ? null : step)
                : null,
          ),
      ]),
    ]);
  }

  Widget _section({required String title, required String subtitle, required List<Widget> children}) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: t.textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(subtitle, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 16),
      ...children,
    ]);
  }

  Widget _continue(BusyAction? onPressed, {String label = 'Save and continue'}) =>
      BusyButton.filled(onPressed: _busy ? null : onPressed, child: Text(label));

  Widget _field(TextEditingController c, String label, {TextInputType? keyboard, List<TextInputFormatter>? formatters}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          enabled: !_busy,
          keyboardType: keyboard,
          inputFormatters: formatters,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );

  Widget _stepBody(VehicleStep step) => switch (step) {
        VehicleStep.plate => _section(
            title: "What's the plate number?",
            subtitle: 'If you started registering this vehicle before, you will carry on where you stopped.',
            children: [
              TextField(
                controller: _plate,
                enabled: !_busy,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Plate number', border: OutlineInputBorder()),
                onSubmitted: (_) => _savePlate(),
              ),
              const SizedBox(height: 16),
              _continue(_savePlate, label: 'Continue'),
            ],
          ),
        VehicleStep.makeModel => _section(
            title: 'Make and model',
            subtitle: 'Choose your vehicle from the list.',
            children: [
              MakeModelField(value: _makeModel, enabled: !_busy, onChanged: (m) => setState(() => _makeModel = m)),
              _continue(_saveMakeModel),
            ],
          ),
        VehicleStep.yearColor => _section(
            title: 'Year and colour',
            subtitle: 'As shown on the registration card.',
            children: [
              _field(_year, 'Year', keyboard: TextInputType.number, formatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ]),
              _field(_color, 'Colour'),
              _continue(_saveYearColor),
            ],
          ),
        VehicleStep.photos => _photosStep(),
        VehicleStep.owner => _ownerStep(),
        VehicleStep.documents => _documentsStep(),
        VehicleStep.done => _doneStep(),
      };

  Widget _photosStep() {
    final v = _v!;
    final complete = vehiclePhotoSlots.every((s) => '${v['image_$s'] ?? ''}'.trim().isNotEmpty);
    return _section(
      title: 'Photos of the vehicle',
      subtitle: 'One from each side: front, left, right and back, with the plate readable at the front or back.',
      children: [
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth >= 520 ? 4 : 2;
          final w = (c.maxWidth - (cols - 1) * 12) / cols;
          return Wrap(spacing: 12, runSpacing: 12, children: [
            for (final s in vehiclePhotoSlots)
              SizedBox(
                width: w,
                child: ImageSlot(
                  label: '${s[0].toUpperCase()}${s.substring(1)}',
                  url: v['image_$s'] as String?,
                  height: 110,
                  busy: _uploadingSlot == s,
                  enabled: !_busy,
                  onPick: () => _uploadPhoto(s),
                ),
              ),
          ]);
        }),
        const SizedBox(height: 16),
        _continue(
          complete ? () => setState(() => _viewing = null) : null,
          label: complete ? 'Continue' : 'Add all four photos',
        ),
      ],
    );
  }

  Widget _ownerStep() => _section(
        title: 'Who owns the vehicle?',
        subtitle: 'The registered owner, as on the registration card.',
        children: [
          Text('Is this your own vehicle?', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            ChoiceChip(
              label: const Text("It's my own vehicle"),
              selected: _ownVehicle == true,
              onSelected: _busy ? null : (_) => _chooseOwn(true),
            ),
            ChoiceChip(
              label: const Text("It's someone else's"),
              selected: _ownVehicle == false,
              onSelected: _busy ? null : (_) => _chooseOwn(false),
            ),
          ]),
          const SizedBox(height: 16),
          _field(_ownerName, "Owner's name"),
          _field(_ownerPhone, "Owner's phone", keyboard: TextInputType.phone),
          _field(_ownerIc, "Owner's ID number"),
          _continue(_saveOwner, label: _ownVehicle == null ? 'Select an option to continue' : 'Save and continue'),
        ],
      );

  Widget _documentsStep() {
    final docs = _docs();
    final v = _v!;
    return _section(
      title: 'Vehicle documents',
      subtitle: 'Tap each document to upload it. Every compulsory one is needed before you can submit.',
      children: [
        PartnerDocsUploader(
          key: ValueKey('${v['id']}:${docs.map((d) => d.id).join(',')}'),
          partnerId: _ctx!.partnerId,
          vehicleId: v['id'] as String,
          docs: docs,
          authUserId: _ctx!.partner['auth_user_id'] as String?,
          title: 'Required vehicle documents',
          onUploads: (uploads) {
            final complete = compulsoryDocsComplete(docs, uploads);
            if (mounted && complete != _docsComplete) setState(() => _docsComplete = complete);
          },
        ),
        const SizedBox(height: 16),
        _continue(_submit, label: _docsComplete ? 'Submit for review' : 'Upload every compulsory document'),
      ],
    );
  }

  Widget _doneStep() {
    final v = _v!;
    final a = vehicleApproval(v);
    final docs = _docs();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        child: ListTile(
          leading: Icon(Icons.directions_car, color: _toneColor(a.tone)),
          title: Text('${_vehicleTitle(v)} · ${a.label}'),
          subtitle: Text(a.description),
        ),
      ),
      const SizedBox(height: 16),
      PartnerDocsUploader(
        key: ValueKey('done:${v['id']}:${docs.map((d) => d.id).join(',')}'),
        partnerId: _ctx!.partnerId,
        vehicleId: v['id'] as String,
        docs: docs,
        authUserId: _ctx!.partner['auth_user_id'] as String?,
        title: 'Vehicle documents',
      ),
      const SizedBox(height: 8),
      Text('A rejected or expired document can be uploaded again here.', style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 16),
      BusyButton.outlined(onPressed: _busy ? null : _finish, child: const Text('Done')),
    ]);
  }
}
