import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/screens/people/people_data.dart';
import '../../admin/screens/people/people_logic.dart';
import '../../admin/screens/people/people_widgets.dart';
import '../../core/partner_onboarding.dart';
import '../../core/partner_registration.dart';
import '../../core/saved_drafts.dart';
import '../../core/vehicle_onboarding.dart';
import '../../data/partner_doc_check.dart' show partnerTypeEntriesProvider;
import '../../data/live_tables.dart';
import '../../data/partner_onboarding_repository.dart';
import '../../data/ride_draft_store.dart';
import '../../data/vehicle_onboarding_repository.dart';
import '../../providers.dart' show currentUserIdProvider;
import '../../widgets/busy.dart';
import '../../widgets/page_add_action.dart';
import '../../widgets/common.dart';
import '../../widgets/loading_skeleton.dart';
import '../../widgets/back_or_go_button.dart';
import '../../widgets/side_menu_host.dart';
import '../../widgets/page_style_host.dart';
import 'vehicle_service_parts.dart';

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
    if (mounted) _reload();
  }

  /// Reads the list again (a block body: setState must not be handed the
  /// Future an arrow returning the assignment would give it).
  void _reload() => setState(() {
    _vehicles = _load();
  });

  /// Removes the draft [v] once the owner confirms. The server decides:
  /// a vehicle submitted or put to use since can't be removed any more.
  Future<void> _remove(Map<String, dynamic> v) async {
    final plate = '${v['plate'] ?? ''}'.trim();
    final ok = await showAppDialog<bool>(id: 'vehicles.remove-draft',
      context: context,
      builder: (c) => AlertDialog(
        title: Text(plate.isEmpty ? 'Remove this draft?' : 'Remove $plate?'),
        content: const Text('This draft vehicle and what you entered for it will be removed. You can add it again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(
            key: const ValueKey('vehicle-remove-confirm'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(64, 40),
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final removed = await ref.read(vehicleOnboardingRepositoryProvider).removeDraft('${v['id']}');
      if (!mounted) return;
      showInfo(
        context,
        removed
            ? (plate.isEmpty ? 'Draft removed.' : '$plate removed.')
            : "This vehicle can't be removed any more: it has been sent for review or is in use. "
                  'Contact support if it should go.',
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    // An admin's decision on a vehicle shows here at once.
    ref.listenLive(const ['vehicle', 'vehicle_documents'], _reload);
    return _scaffold(context);
  }

  /// A floating Add on a phone; beside the title from 600 wide.
  late final _add = PageAddAction(onPressed: () => _open('/drive/vehicles/new'), label: const Text('Add vehicle'));

  Widget _scaffold(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: sideMenuLeading(context),
          title: const Text('My vehicles'),
          actions: pageAddActions(context, _add),
        ),
        floatingActionButton: pageAddFab(context, _add),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _vehicles,
          builder: (context, snap) {
            if (snap.hasError) {
              return EmptyState(
                icon: Icons.cloud_off,
                title: 'Could not load your vehicles',
                message: errorText(snap.error!),
                action: FilledButton(
                    onPressed: _reload, child: const Text('Try again')),
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
              child: ListView(padding: EdgeInsets.fromLTRB(16, 16, 16, addActionListBottomPadding(context)), children: [
                for (final v in list)
                  Builder(builder: (context) {
                    final step = firstVehicleStep(v);
                    final approval = vehicleApproval(v);
                    return Card(
                      child: ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.directions_car_outlined)),
                        title: Text('${v['plate'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        // The status under the name, so a long one ("Incomplete:
                        // Make & model") never squeezes the plate and name into a
                        // sliver beside it.
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_vehicleTitle(v), maxLines: 1, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 6),
                            step == VehicleStep.done
                                // Read as "Status: Approved", not a tick box.
                                ? Semantics(
                                    container: true,
                                    label: 'Status: ${approval.label}',
                                    excludeSemantics: true,
                                    child: Chip(
                                      label: Text(approval.label),
                                      labelStyle: TextStyle(color: _toneColor(approval.tone), fontSize: 12),
                                      visualDensity: VisualDensity.compact,
                                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                  )
                                // Not submitted yet: a draft, resumed from its next step.
                                : Chip(
                                    key: ValueKey('vehicle-draft-${v['id']}'),
                                    // Short, and free to wrap: beside a delete
                                    // button and a chevron at large text, a
                                    // one-line label was clipped.
                                    label: Text('Draft · ${step.label} next', softWrap: true, maxLines: 4),
                                    visualDensity: VisualDensity.compact,
                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                          ],
                        ),
                        trailing: vehicleLooksLikeDraft(v)
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    key: ValueKey('vehicle-remove-${v['id']}'),
                                    tooltip: 'Remove draft ${v['plate'] ?? ''}'.trim(),
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _remove(v),
                                  ),
                                  const Icon(Icons.chevron_right),
                                ],
                              )
                            : const Icon(Icons.chevron_right),
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
  String? _plateError;
  final _year = TextEditingController();
  final _color = TextEditingController();
  final _ownerName = TextEditingController();
  final _ownerPhone = TextEditingController();
  final _ownerIc = TextEditingController();
  MakeModel? _makeModel;

  /// The service the driver chose (0249), when the make & model maps none;
  /// [_serviceError] once they tried to go on without one.
  String _serviceId = '';
  String? _serviceError;

  /// Vehicle Make & Model, for the service GET.ride set per make & model.
  List<Map<String, dynamic>> _catalogue = const [];
  bool? _ownVehicle;

  _Entries _requiredDocs = const [];
  Set<String> _vehicleTypeIds = const {};
  bool _docsComplete = false;

  VehicleOnboardingRepository get _repo => ref.read(vehicleOnboardingRepositoryProvider);

  @override
  void initState() {
    super.initState();
    try {
      _uid = ref.read(currentUserIdProvider);
    } catch (_) {}
    _saver = DraftSaver(SavedDraftKind.vehicle, ref.read(rideDraftStoreProvider), () => _uid);
    _load();
  }

  @override
  void dispose() {
    _saver.dispose();
    for (final c in [_plate, _year, _color, _ownerName, _ownerPhone, _ownerIc]) {
      c.dispose();
    }
    super.dispose();
  }

  // ---- Welcome back (saved_drafts.dart) ----
  /// A vehicle being added is kept on the server as it goes; the phone only
  /// remembers which one and how far it got, to offer it again on Drive.
  late final DraftSaver _saver;
  String? _uid;

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _saver.changed(_saved());
  }

  Map<String, Object?>? _saved() {
    final v = _v;
    final id = v?['id'];
    if (v == null || id is! String) return null;
    final step = firstVehicleStep(v);
    if (step == VehicleStep.done) return null;
    final plate = '${v['plate'] ?? ''}'.trim();
    return {'id': id, if (plate.isNotEmpty) 'plate': plate, 'next': step.label};
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
      var catalogue = const <Map<String, dynamic>>[];
      try {
        catalogue = await people.makeModels();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _ctx = ctx;
        _catalogue = catalogue;
        _requiredDocs = settled[0] as _Entries;
        _vehicleTypeIds = vehicleDocTypeIds(settled[1] as _Entries);
        _hydrate(v);
        _loaded = true;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  /// An admin changed the required documents or decided on this vehicle:
  /// read them again, keeping what is being typed.
  Future<void> _refresh() async {
    if (!_loaded || _busy) return;
    try {
      final people = ref.read(peopleRepositoryProvider);
      final id = _v?['id'] as String? ?? widget.vehicleId;
      final settled = await Future.wait<Object?>([
        people.requiredDocuments(),
        people.documentTypes(),
        if (id != null) _repo.vehicle(id),
      ]);
      if (!mounted || _busy) return;
      setState(() {
        _requiredDocs = settled[0] as _Entries;
        _vehicleTypeIds = vehicleDocTypeIds(settled[1] as _Entries);
        if (id != null && settled[2] != null) _v = settled[2] as Map<String, dynamic>;
      });
    } catch (_) {}
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
    // The vehicle's service_id may be the driver's choice: what the make &
    // model sets is looked up in the list (_mapped).
    if (t('make').isNotEmpty) _makeModel = makeModelFromRow({...v, 'service_id': null});
    _serviceId = t('service_id');
  }

  /// The service the make & model has ('' when the list sets none).
  String get _mapped {
    final m = _makeModel;
    if (m == null) return '';
    return m.serviceId.isNotEmpty ? m.serviceId : makeModelService(_catalogue, m.make, m.model);
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
    setState(() => _plateError = plate.isEmpty ? 'Enter the plate number' : null);
    if (plate.isEmpty) return;
    await _save(() => _repo.startWithPlate(plate, _ctx!.partner));
  }

  Future<void> _saveMakeModel() async {
    final m = _makeModel;
    if (m == null || m.make.isEmpty) return showError(context, 'Please select the make and model.');
    // Its service: the make & model's, else the driver's choice (0249).
    final service = vehicleServiceChoice(
      mapped: _mapped,
      chosen: _serviceId,
      canChoose: (ref.read(vehicleServiceOptionsProvider).value ?? const []).isNotEmpty,
    );
    if (service.problem != null) {
      setState(() => _serviceError = service.problem);
      return showError(context, service.problem!);
    }
    await _save(() => _repo.patch(_v!, {
          'make': m.make,
          'model': m.model,
          'vehicle_type': m.vehicleType.isEmpty ? null : m.vehicleType,
          'service_id': service.serviceId,
        }));
  }

  Future<void> _saveYearColor() async {
    final year = _year.text.trim(), color = _color.text.trim();
    // Too old for a service: that service is paused for this vehicle once
    // submitted (0301), never refused; the documents step shows which.
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

  /// How each of the partner's vehicle services stands with this vehicle
  /// (registration's vehicleServiceStatuses): its types (its own, else the
  /// partner's) in its registration region (its service area, else the
  /// partner's), by the year made. The server works out the same on submit
  /// (0301).
  List<VehicleServiceStatus> _statuses(Iterable<Map<String, dynamic>> entries) {
    final v = _v;
    final own = v != null && (v['service_countries'] is List) && (v['service_countries'] as List).isNotEmpty;
    final ownTypes = v == null ? const <String>[] : parseStringList(v['partner_types']);
    final types = ownTypes.isNotEmpty ? ownTypes : parseStringList(_ctx?.partner['partner_types']);
    return vehicleServiceStatuses(
      services: vehicleServicesOf(types, entries),
      entries: entries,
      area: ServiceArea.fromRow(own ? v : _ctx?.partner),
      registered: _registered,
    );
  }

  /// When the vehicle was registered: its registration date, else 1 January
  /// of the year made.
  DateTime? get _registered {
    final v = _v;
    final day = DateTime.tryParse('${v?['registration_date'] ?? ''}');
    if (day != null) return day;
    final year = int.tryParse(RegExp(r'\d{4}').firstMatch('${v?['year'] ?? ''}')?.group(0) ?? '');
    return year == null ? null : DateTime(year);
  }

  Future<void> _submit() async {
    if (!_docsComplete) return showError(context, 'Please upload every compulsory document before submitting.');
    await _save(() => _repo.patch(_v!, {'documents_ok': true}));
  }

  /// Leaves the wizard: an approved vehicle goes to the Drive tab, read
  /// fresh so an approval made while the screen was open counts.
  Future<void> _finish() async {
    _saver.forget(null);
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
    ref.listenLive(const ['required_document', 'document_type', 'vehicle', 'vehicle_documents'], () {
      unawaited(_refresh());
    });
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
    return Scaffold(
      appBar: AppBar(
        leading: const BackOrGoButton(fallback: '/drive/vehicles'),
        title: Text(plate.isEmpty ? 'Add vehicle' : plate),
      ),
      body: body,
    );
  }

  Widget _header(VehicleStep reached, VehicleStep showing) {
    final t = Theme.of(context);
    final steps = VehicleStep.wizard;
    final reachedIndex = reached == VehicleStep.done ? steps.length : steps.indexOf(reached);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Said once, by the bar below.
      ExcludeSemantics(
        child: Text(reached == VehicleStep.done ? 'All steps complete' : 'Step ${reachedIndex + 1} of ${steps.length}',
            style: t.textTheme.labelLarge),
      ),
      const SizedBox(height: 8),
      // As the step line counts: full on the last step.
      // Read as "Step 1 of 6", with the share done as its value.
      LinearProgressIndicator(
        value: ((reachedIndex + 1) / steps.length).clamp(0.0, 1.0),
        semanticsLabel: reached == VehicleStep.done ? 'All steps complete' : 'Step ${reachedIndex + 1} of ${steps.length}',
        semanticsValue: '${(((reachedIndex + 1) / steps.length).clamp(0.0, 1.0) * 100).round()}%',
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (i, step) in steps.indexed)
          ChoiceChip(
            avatar: i < reachedIndex ? const Icon(Icons.check, size: 16) : null,
            // Ticks only on finished steps; the open one is filled, no tick.
            showCheckmark: false,
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

  Widget _field(
    TextEditingController c,
    String label, {
    TextInputType? keyboard,
    List<TextInputFormatter>? formatters,
    TextInputAction action = TextInputAction.next,
    ValueChanged<String>? onSubmitted,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          enabled: !_busy,
          keyboardType: keyboard,
          textInputAction: action,
          onSubmitted: onSubmitted,
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
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Plate number',
                  border: const OutlineInputBorder(),
                  errorText: _plateError,
                ),
                onChanged: (_) {
                  if (_plateError != null) setState(() => _plateError = null);
                },
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
              if (_makeModel != null)
                VehicleServiceField(
                  key: const ValueKey('vehicle-service'),
                  mapped: _mapped,
                  value: _serviceId,
                  enabled: !_busy,
                  errorText: _serviceError,
                  onChanged: (v) => setState(() {
                    _serviceId = v;
                    _serviceError = null;
                  }),
                ),
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
              _field(_color, 'Colour', action: TextInputAction.done, onSubmitted: (_) => _saveYearColor()),
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
          _field(_ownerIc, "Owner's ID number", action: TextInputAction.done),
          _continue(_saveOwner, label: _ownVehicle == null ? 'Select an option to continue' : 'Save and continue'),
        ],
      );

  Widget _documentsStep() {
    final docs = _docs();
    final v = _v!;
    final entries = ref.watch(partnerTypeEntriesProvider).value;
    final made = _registered;
    return _section(
      title: 'Vehicle documents',
      subtitle: 'Tap each document to upload it. Every compulsory one is needed before you can submit.',
      children: [
        // Before "Submit for review": how each service stands with this
        // vehicle, as registration shows it.
        if (entries != null)
          VehicleServiceStatusBlocks(
            key: const ValueKey('vehicle-service-checks'),
            statuses: _statuses([for (final e in entries) e.values]),
            regLabel: made == null ? 'Vehicle age' : 'Made ${made.year}',
            registered: made,
          ),
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
      // Vehicles > [plate] > Permit: the vehicle's permits, uploaded by GET.ride (0254).
      Card(
        child: ListTile(
          key: const ValueKey('vehicle-permit-link'),
          leading: const Icon(Icons.verified_user_outlined),
          title: const Text('Permit'),
          subtitle: const Text('The permits for this vehicle, to show when asked'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/drive/vehicles/${v['id']}/permit'),
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
