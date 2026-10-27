import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/screens/meterapp/pick_image.dart';
import '../../admin/screens/people/people_data.dart';
import '../../admin/screens/people/people_logic.dart';
import '../../admin/screens/people/people_widgets.dart';
import '../../core/app_display.dart' show partnerRegistrationPausedMessage, partnerRegistrationPausedTitle;
import '../../core/partner_doc_check.dart' show renewalWindowDays;
import '../../core/partner_onboarding.dart';
import '../../core/partner_registration.dart';
import '../../core/partner_type_rules.dart' show EffectiveTypeRules, partnerTypesAvailableIn;
import '../../core/vehicle_onboarding.dart';
import '../../data/app_display_repository.dart' show appDisplayProvider;
import '../../data/identity_repository.dart' show recordProfileSelfie;
import '../../data/live_tables.dart';
import '../../data/partner_onboarding_repository.dart';
import '../../data/vehicle_onboarding_repository.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/live_selfie.dart';
import '../../widgets/loading_skeleton.dart';
import '../../widgets/side_menu_host.dart';
import '../../widgets/net_image.dart';
import 'registration_parts.dart';
import 'registration_steps.dart';

typedef _Entries = List<({String id, Map<String, dynamic> values})>;

/// Where the form opens when asked for [wanted]: there when the partner has
/// reached it (or finished), else the first step still missing ([reached]),
/// which has to be done first. Pure.
OnboardingStep onboardingStartStep(OnboardingStep reached, OnboardingStep wanted) {
  if (wanted == OnboardingStep.done) return reached;
  final r = reached == OnboardingStep.done ? OnboardingStep.wizard.length : OnboardingStep.wizard.indexOf(reached);
  return OnboardingStep.wizard.indexOf(wanted) <= r ? wanted : reached;
}

/// The step a `/drive/onboarding?step=<key>` address asks for, by its stored
/// key ('requirements' for the service documents); null for none or an
/// unknown one.
OnboardingStep? onboardingStepFromQuery(String? key) {
  for (final s in OnboardingStep.wizard) {
    if (s.key == key) return s;
  }
  return null;
}

/// Becoming a partner (0288): profile photo (only when missing), service
/// area, Partner Service type, National ID, Check your details, then Your
/// company, Driver permit, Register vehicle and Vehicle documents where the
/// picked services need them, Service documents, and Pending admin approval
/// (partner and vehicle reviewed together). A returning partner lands on the
/// first step still missing; finished steps can be reopened from the header.
class PartnerOnboardingScreen extends ConsumerStatefulWidget {
  const PartnerOnboardingScreen({
    super.key,
    this.takeSelfie = takeLiveAvatar,
    this.pickPhoto = pickDocumentImage,
    this.startAt,
    this.onPhone,
    this.now,
  });

  /// The step to open on ("Update documents" asks for the documents), when
  /// it is reachable; an earlier step still missing comes first, as the
  /// steps go in order ([onboardingStartStep]).
  final OnboardingStep? startAt;

  /// The profile photo: a live selfie with the front camera, cut square
  /// (overridden in tests). On a phone it is only taken once the live check
  /// passes.
  final Future<LiveSelfie?> Function(BuildContext context) takeSelfie;

  /// The ID photo picker (overridden in tests).
  final Future<PickedImage?> Function(BuildContext context) pickPhoto;

  /// Whether the live check is required (a phone; overridden in tests).
  final bool? onPhone;

  /// The clock (tests).
  final DateTime? now;

  @override
  ConsumerState<PartnerOnboardingScreen> createState() => _PartnerOnboardingScreenState();
}

class _PartnerOnboardingScreenState extends ConsumerState<PartnerOnboardingScreen> implements RegHost {
  OnboardingState? _s;
  Object? _loadError;
  bool _busy = false;

  /// A step shown other than the first one missing: reopened from the
  /// header, or kept while it has more to do.
  OnboardingStep? _viewing;

  ServiceArea _area = const ServiceArea();
  bool _areaFromLocation = false;
  List<String> _types = const [];
  GeoOptions _geo = const GeoOptions();
  _Entries _typeEntries = const [];
  _Entries _requiredDocs = const [];
  Set<String> _vehicleTypeIds = const {};
  bool _docsComplete = false;
  bool _vehicleDocsComplete = false;

  /// The photo step is listed only when the photo was missing on opening.
  bool _photoStep = true;

  /// The vehicle registered in this application.
  Map<String, dynamic>? _vehicle;
  List<Map<String, dynamic>> _vehicleStatuses = const [];

  @override
  Uint8List? idFront;

  bool get _onPhone => widget.onPhone ?? liveSelfieOnPhone;

  PartnerOnboardingRepository get _repo => ref.read(partnerOnboardingRepositoryProvider);

  @override
  OnboardingState get state => _s!;

  @override
  bool get busy => _busy;

  @override
  Iterable<Map<String, dynamic>> get typeValues => _typeEntries.map((e) => e.values);

  @override
  List<String> get offeredTypes => partnerTypesAvailableIn(
        partnerTypeOptions(typeValues),
        typeValues,
        ServiceArea.fromRow(_s?.partner),
      );

  @override
  Future<PickedImage?> pickIdPhoto(BuildContext context) => widget.pickPhoto(context);

  RegistrationNeeds _needsFor(Map<String, dynamic> partner) => RegistrationNeeds.of(
        parseStringList(partner['partner_types']),
        typeValues,
        ServiceArea.fromRow(partner),
      );

  OnboardingStep _reached(OnboardingState s) =>
      firstIncompleteStep(s.profile, s.partner, needs: _needsFor(s.partner), onPhone: _onPhone);

  List<OnboardingStep> _stepsFor(OnboardingState s) =>
      // The photo step always counts, done or not, so "Step 2 of 6" means
      // the same from one visit to the next.
      OnboardingStep.stepsFor(_needsFor(s.partner));

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Set once loading has taken 10 s: the page offers Retry.
  bool _slow = false;
  Timer? _slowTimer;

  @override
  void dispose() {
    _slowTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loadError = null;
      _slow = false;
    });
    _slowTimer?.cancel();
    _slowTimer = Timer(const Duration(seconds: 10), () {
      if (mounted && _s == null && _loadError == null) setState(() => _slow = true);
    });
    try {
      // A new application only while Admin → Display allows new drivers;
      // one already started may be finished. Unreadable settings: let the
      // server decide.
      var mayStart = true;
      try {
        mayStart = (await ref.read(appDisplayProvider.future).timeout(const Duration(seconds: 5))).driverSignUpOpen;
      } catch (_) {}
      final s = await _repo.load(mayStart: mayStart);
      final people = ref.read(peopleRepositoryProvider);
      var area = ServiceArea.fromRow(s.partner);
      final settled = await Future.wait<Object>([
        people.geoOptions(inUse: [area]),
        people.partnerTypes(),
        people.requiredDocuments(),
        people.documentTypes(),
      ]);
      final geo = settled[0] as GeoOptions;
      // A new application: the area is filled in from where the phone is.
      var fromLocation = false;
      if (area.isEmpty) {
        try {
          final here = await ref.read(registrationLocatorProvider)().timeout(const Duration(seconds: 15));
          final found = here == null
              ? null
              : areaFromPlace(country: here.country, state: here.state, city: here.city, options: geo);
          if (found != null) {
            area = found;
            fromLocation = true;
          }
        } catch (_) {}
      }
      final vehicle = await _loadVehicle(s.partner);
      if (!mounted) return;
      setState(() {
        _typeEntries = settled[1] as _Entries;
        _s = s.copyWith(needs: _needsFor(s.partner));
        _photoStep = !photoStepDone(s.profile, s.partner, onPhone: _onPhone);
        // Opened for one step (`?step=`): there, unless an earlier one is
        // still missing. Only on the first load.
        if (_viewing == null && widget.startAt != null) {
          final reached = _reached(_s!);
          final start = onboardingStartStep(reached, widget.startAt!);
          _viewing = start == reached ? null : start;
        }
        _area = area;
        _areaFromLocation = fromLocation;
        _types = parseStringList(s.partner['partner_types']);
        _geo = geo;
        _requiredDocs = settled[2] as _Entries;
        _vehicleTypeIds = vehicleDocTypeIds(settled[3] as _Entries);
        _vehicle = vehicle.vehicle;
        _vehicleStatuses = vehicle.statuses;
      });
      ref.invalidate(partnerProvider);
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  Future<({Map<String, dynamic>? vehicle, List<Map<String, dynamic>> statuses})> _loadVehicle(
    Map<String, dynamic> partner,
  ) async {
    final id = '${partner['registration_vehicle_id'] ?? ''}';
    if (id.isEmpty) return (vehicle: null, statuses: const <Map<String, dynamic>>[]);
    try {
      final repo = ref.read(vehicleOnboardingRepositoryProvider);
      final v = await repo.vehicle(id);
      final st = v == null ? const <Map<String, dynamic>>[] : await repo.serviceStatuses(id);
      return (vehicle: v, statuses: st);
    } catch (_) {
      return (vehicle: null, statuses: const <Map<String, dynamic>>[]);
    }
  }

  /// An admin changed what this form is built from (areas, partner types,
  /// required documents) or decided on this application: read it all again,
  /// keeping what is being typed and picked.
  Future<void> _refresh() async {
    if (_s == null || _busy) return;
    try {
      final s = await _repo.load();
      final people = ref.read(peopleRepositoryProvider);
      final settled = await Future.wait<Object>([
        people.geoOptions(inUse: [_area]),
        people.partnerTypes(),
        people.requiredDocuments(),
        people.documentTypes(),
      ]);
      final vehicle = await _loadVehicle(s.partner);
      if (!mounted || _busy) return;
      setState(() {
        _typeEntries = settled[1] as _Entries;
        _s = s.copyWith(needs: _needsFor(s.partner));
        _geo = settled[0] as GeoOptions;
        _requiredDocs = settled[2] as _Entries;
        _vehicleTypeIds = vehicleDocTypeIds(settled[3] as _Entries);
        _vehicle = vehicle.vehicle ?? _vehicle;
        _vehicleStatuses = vehicle.statuses;
      });
    } catch (_) {}
  }

  @override
  Future<bool> save(Future<OnboardingState> Function(OnboardingState s) action, {OnboardingStep? stayOn}) async {
    final s = _s;
    if (s == null || _busy) return false;
    setState(() => _busy = true);
    try {
      final next = await action(s.copyWith(needs: _needsFor(s.partner)));
      if (!mounted) return false;
      setState(() {
        _s = next.copyWith(needs: _needsFor(next.partner));
        _viewing = stayOn;
      });
      ref.invalidate(partnerProvider);
      // A fix from "Changes needed" (0289): once the step is saved, back to
      // the list of what the admin asked for.
      if (widget.startAt != null && stayOn == null && '${next.partner['status']}' == 'changes-needed') {
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/drive');
        }
      }
      return true;
    } catch (e) {
      if (mounted) await showErrorNotice(context, e);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void goTo(OnboardingStep step) => setState(() => _viewing = step);

  Future<OnboardingState> _patchBoth(OnboardingState s, Map<String, dynamic> patch) async {
    final profile = await _repo.patchProfile(patch);
    final withProfile = s.copyWith(profile: profile);
    return withProfile.copyWith(partner: await _repo.patchPartner(withProfile, patch));
  }

  // ---- Steps -----------------------------------------------------------------

  Future<void> _pickAvatar() async {
    final selfie = await widget.takeSelfie(context);
    if (selfie == null || !mounted) return;
    await save((s) async {
      final url = await _repo.uploadAvatar(s, selfie.bytes, selfie.name);
      // How it was taken first, so the partner row reads it with the photo.
      await recordProfileSelfie(ref, url, selfie);
      return _patchBoth(s, {'avatar_url': url});
    });
  }

  Future<void> _saveArea() async {
    if (!_area.complete) {
      return showNotice(context, message: 'Please select at least one country, state and city you will serve.');
    }
    await save((s) async => s.copyWith(partner: await _repo.patchPartner(s, _area.toRow())));
  }

  Future<void> _saveTypes() async {
    if (_types.isEmpty) return showNotice(context, message: 'Please select at least one Partner Service type.');
    final unavailable =
        _types.where((t) => !EffectiveTypeRules.of(t, typeValues).availableIn(ServiceArea.fromRow(_s!.partner))).toList();
    if (unavailable.isNotEmpty) {
      return showNotice(context, message: '${unavailable.join(', ')} is not offered in your service area.');
    }
    await save((s) async {
      try {
        return s.copyWith(partner: await _repo.patchPartner(s, partnerTypeColumns(_types)));
      } catch (e) {
        // An approved partner's types are locked (0299): say so plainly.
        final locked = partnerTypesLockedMessage(e);
        if (locked != null) throw StateError(locked);
        rethrow;
      }
    });
  }

  Future<void> _vehicleDocsDone() async {
    if (!_vehicleDocsComplete) {
      return showNotice(context, message: 'Please upload every compulsory vehicle document first.');
    }
    await save((s) async => s.copyWith(partner: await _repo.patchPartner(s, withRegistrationStep(s.partner, regStepVehicleDocs))));
  }

  /// Partner and vehicle are sent for review together.
  Future<void> _submit() async {
    if (!_docsComplete) {
      return showNotice(context, message: 'Please upload every compulsory document before submitting.');
    }
    await save((s) async {
      final v = _vehicle;
      if (v != null && _needsFor(s.partner).vehicle && v['documents_ok'] != true) {
        final vehicles = ref.read(vehicleOnboardingRepositoryProvider);
        _vehicle = await vehicles.update(v['id'] as String, {'documents_ok': true, 'onboarding_step': 'done'});
      }
      return s.copyWith(partner: await _repo.patchPartner(s, {'documents_ok': true}));
    });
  }

  List<RequiredDoc> _docsFor(OnboardingState s) => serviceDocsAfterPermitStep(
        requiredDocsFor(
          requiredDocuments: _requiredDocs,
          partnerTypeValues: typeValues,
          partnerTypes: parseStringList(s.partner['partner_types']),
          area: ServiceArea.fromRow(s.partner),
          vehicleTypeIds: _vehicleTypeIds,
        ),
        permitStep: _needsFor(s.partner).driverPermit,
      );

  List<String> _docNamesFor(String type) => [
        for (final d in serviceDocsAfterPermitStep(
          requiredDocsFor(
            requiredDocuments: _requiredDocs,
            partnerTypeValues: typeValues,
            partnerTypes: [type],
            area: _area,
            vehicleTypeIds: _vehicleTypeIds,
          ),
          permitStep: false,
        ))
          if (d.compulsory) d.name,
      ];

  List<RequiredDoc> _vehicleDocs(OnboardingState s) => vehicleRequiredDocs(
        requiredDocuments: _requiredDocs,
        vehicleTypeIds: _vehicleTypeIds,
        partnerTypes: parseStringList(s.partner['partner_types']),
        area: ServiceArea.fromRow(s.partner),
      );

  // ---- Layout ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    ref.listenLive(const [
      ...liveRegionTables,
      'required_document',
      'document_type',
      'partners',
      'provider_documents',
      'vehicle_service_status',
    ], () => unawaited(_refresh()));
    final s = _s;
    Widget body;
    if (_loadError is PartnerRegistrationPaused) {
      // Driver sign-up closed and no application started: no wizard.
      body = const EmptyState(
        key: ValueKey('partner-registration-paused'),
        icon: Icons.pause_circle_outline,
        title: partnerRegistrationPausedTitle,
        message: partnerRegistrationPausedMessage,
      );
    } else if (_loadError != null) {
      body = EmptyState(
        icon: Icons.cloud_off,
        title: 'Could not load your partner profile',
        message: errorText(_loadError!),
        action: BusyButton.filled(onPressed: _load, child: const Text('Try again')),
      );
    } else if (s == null) {
      // Said in words, and after 10 s a way to try again.
      body = Column(children: [
        const Expanded(child: LoadingSkeletonPage()),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              'Loading your application…',
              key: const ValueKey('onboarding-loading'),
              textAlign: TextAlign.center,
              style: TextStyle(color: mutedTextColor(Theme.of(context))),
            ),
            if (_slow) ...[
              const SizedBox(height: 8),
              Text(
                'This is taking longer than usual.',
                textAlign: TextAlign.center,
                style: TextStyle(color: mutedTextColor(Theme.of(context))),
              ),
              TextButton(key: const ValueKey('onboarding-retry'), onPressed: _load, child: const Text('Retry')),
            ],
          ]),
        ),
      ]);
    } else {
      final reached = _reached(s);
      final step = _viewing ?? reached;
      body = ResponsiveCenter(
        maxWidth: 640,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (step != OnboardingStep.done || reached != OnboardingStep.done) ...[
            _header(s, reached, step),
            const SizedBox(height: 16),
          ],
          if (_busy) const LinearProgressIndicator(),
          KeyedSubtree(key: ValueKey('step-${step.key}'), child: _stepBody(s, step)),
        ]),
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: sideMenuLeading(context),
        title: Text(s != null && _reached(s) == OnboardingStep.done ? 'Partner application' : 'Become a partner'),
      ),
      body: body,
    );
  }

  Widget _header(OnboardingState s, OnboardingStep reached, OnboardingStep showing) {
    final t = Theme.of(context);
    final steps = _stepsFor(s);
    final reachedIndex = reached == OnboardingStep.done ? steps.length : steps.indexOf(reached).clamp(0, steps.length);
    final showingIndex = steps.indexOf(showing);
    final label = reached == OnboardingStep.done
        ? 'All steps complete'
        : 'Step ${(showingIndex < 0 ? reachedIndex : showingIndex) + 1} of ${steps.length} · ${showing.label}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, key: const ValueKey('onboarding-progress'), style: t.textTheme.labelLarge),
      const SizedBox(height: 8),
      // Counted as the step on screen says: full on the last step.
      LinearProgressIndicator(value: ((reachedIndex + 1) / steps.length).clamp(0.0, 1.0)),
      const SizedBox(height: 12),
      // The steps go in order (each opens once the one before is saved):
      // finished steps and the current one are chips that open them; later
      // steps are plain locked labels, not buttons.
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final (i, step) in steps.indexed)
          if (i <= reachedIndex)
            // Read as "Service area, done" or "National ID, current step":
            // the chip's own selected state read as a ticked box on the
            // current step and an unticked one on finished steps.
            Semantics(
              container: true,
              button: true,
              label: '${step.label}, ${i < reachedIndex ? 'done' : 'current step'}',
              excludeSemantics: true,
              onTap: !_busy ? () => setState(() => _viewing = step == reached ? null : step) : null,
              child: ChoiceChip(
              key: ValueKey('onboarding-step-${step.key}'),
              avatar: i < reachedIndex ? const Icon(Icons.check, size: 16) : null,
              // Ticks only on finished steps; the open one is filled, no
              // tick (the chip's own checkmark put one on the current step).
              showCheckmark: false,
              label: Text(step.label),
              tooltip: i < reachedIndex ? 'Done: open to review' : 'Current step',
              selected: step == showing,
              onSelected: !_busy ? (_) => setState(() => _viewing = step == reached ? null : step) : null,
            ),
            )
          else
            _LockedStep(key: ValueKey('onboarding-step-${step.key}'), label: step.label, next: i == reachedIndex + 1),
      ]),
    ]);
  }

  Widget _stepBody(OnboardingState s, OnboardingStep step) => switch (step) {
        OnboardingStep.avatar => _avatarStep(s),
        OnboardingStep.serviceArea => _section(
            title: 'Where will you work?',
            subtitle: 'Choose every country, state and city you will take jobs in. Your service area decides which '
                'services you can join on the next screen.',
            children: [
              if (_areaFromLocation)
                const RegNotice(
                  key: ValueKey('area-from-location'),
                  icon: Icons.my_location,
                  tone: NoticeTone.done,
                  children: [Text('Filled in from your current location. Change it if you will work somewhere else.')],
                ),
              ServiceAreaField(value: _area, options: _geo, enabled: !_busy, onChanged: (a) => setState(() => _area = a)),
              const SizedBox(height: 16),
              _continue(_saveArea, label: 'Continue'),
            ],
          ),
        OnboardingStep.partnerType => _section(
            title: 'Choose your Partner Service type',
            subtitle: 'Offered in ${_areaText(ServiceArea.fromRow(s.partner))}. Pick every service you will offer. '
                'Services marked Vehicle service add the vehicle steps.',
            children: [
              // Nothing offered where they chose: say so, and the way back,
              // rather than a Continue that can only refuse.
              if (offeredTypes.isEmpty)
                Card(
                  key: const ValueKey('partner-type-none'),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(children: [
                      Icon(Icons.explore_off_outlined, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(height: 8),
                      Text(
                        'No services offered in ${_areaText(ServiceArea.fromRow(s.partner))} yet',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      const Text('Pick another area to see what you can drive for there.', textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(
                        key: const ValueKey('partner-type-change-area'),
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                        onPressed: _busy ? null : () => goTo(OnboardingStep.serviceArea),
                        child: const Text('Change area'),
                      ),
                    ]),
                  ),
                )
              else ...[
              CitizensNotice(offered: offeredTypes, entries: typeValues, area: ServiceArea.fromRow(s.partner)),
              ServiceTypeCards(
                // Only types offered in the chosen service area (Admin →
                // Partner Service type → Service availability; the server agrees).
                options: offeredTypes,
                value: _types,
                entries: typeValues,
                area: ServiceArea.fromRow(s.partner),
                docsFor: _docNamesFor,
                enabled: !_busy,
                onChanged: (v) => setState(() => _types = v),
              ),
              const SizedBox(height: 16),
              _continue(_saveTypes, label: 'Continue'),
              ],
            ],
          ),
        OnboardingStep.id => NationalIdStep(host: this),
        OnboardingStep.details => DetailsStep(host: this),
        OnboardingStep.company => CompanyStep(host: this),
        OnboardingStep.driverPermit => DriverPermitStep(host: this, now: widget.now),
        OnboardingStep.vehicle => VehicleRegistrationStep(
            host: this,
            vehicle: _vehicle,
            now: widget.now,
            onVehicle: (v) => setState(() => _vehicle = v),
          ),
        OnboardingStep.vehicleDocs => _vehicleDocsStep(s),
        OnboardingStep.requirements => _requirementsStep(s),
        OnboardingStep.done => _doneStep(s),
      };

  String _areaText(ServiceArea a) {
    final names = [...a.cities.map(areaLabel)];
    if (names.isEmpty) names.addAll(a.states.map(areaLabel));
    if (names.isEmpty) names.addAll(a.countries);
    return names.isEmpty ? 'your area' : names.join(', ');
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

  Widget _continue(BusyAction onPressed, {String label = 'Save and continue'}) =>
      BusyButton.filled(onPressed: _busy ? null : onPressed, child: Text(label));

  Widget _avatarStep(OnboardingState s) {
    final url = [s.partner['avatar_url'], s.profile?['avatar_url'], s.profile?['profile_image']]
        .map((v) => '${v ?? ''}'.trim())
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    final needsLive = url.isNotEmpty && _onPhone && s.partner['selfie_liveness'] != 'passed';
    return _section(
      title: 'Add a profile photo',
      subtitle: needsLive
          ? 'Partners need a live selfie: the photo is taken when you blink or turn your head. Riders see it before pickup.'
          : 'Partners need a clear photo of their face. Riders see it before pickup.',
      children: [
        Center(
          child: NetAvatar(url: url, radius: 56, fallback: const Icon(Icons.person, size: 56)),
        ),
        const SizedBox(height: 16),
        BusyButton.filled(
          onPressed: _busy ? null : _pickAvatar,
          icon: const Icon(Icons.photo_camera_outlined),
          child: Text(url.isEmpty ? 'Take a selfie' : 'Take a new selfie'),
        ),
        if (url.isNotEmpty && !needsLive && _viewing == OnboardingStep.avatar) ...[
          const SizedBox(height: 8),
          OutlinedButton(onPressed: () => setState(() => _viewing = null), child: const Text('Keep this photo')),
        ],
      ],
    );
  }

  Widget _vehicleDocsStep(OnboardingState s) {
    final v = _vehicle;
    if (v == null) {
      return _section(
        title: 'Upload vehicle documents',
        subtitle: 'Register your vehicle first.',
        children: [OutlinedButton(onPressed: () => goTo(OnboardingStep.vehicle), child: const Text('Register vehicle'))],
      );
    }
    final docs = _vehicleDocs(s);
    return _section(
      title: 'Upload vehicle documents',
      subtitle: 'For ${v['plate'] ?? 'your vehicle'}. Tap each document to upload it.',
      children: [
        PartnerDocsUploader(
          key: ValueKey('veh:${v['id']}:${docs.map((d) => d.id).join(',')}'),
          partnerId: s.partnerId,
          vehicleId: v['id'] as String,
          docs: docs,
          authUserId: s.partner['auth_user_id'] as String?,
          title: 'Vehicle documents',
          onUploads: (uploads) {
            final complete = compulsoryDocsComplete(docs, uploads);
            if (mounted && complete != _vehicleDocsComplete) setState(() => _vehicleDocsComplete = complete);
          },
        ),
        const SizedBox(height: 16),
        _continue(_vehicleDocsDone, label: _vehicleDocsComplete ? 'Continue' : 'Upload every compulsory document'),
      ],
    );
  }

  Widget _requirementsStep(OnboardingState s) {
    final docs = _docsFor(s);
    final types = parseStringList(s.partner['partner_types']);
    return _section(
      title: 'Upload service documents',
      subtitle: 'What your chosen services need: ${types.join(', ')}.'
          '${docs.isEmpty ? ' Nothing is set up for these services yet, so you can submit straight away.' : ''}',
      children: [
        PartnerDocsUploader(
          key: ValueKey('${s.partnerId}:${docs.map((d) => d.id).join(',')}'),
          partnerId: s.partnerId,
          docs: docs,
          authUserId: s.partner['auth_user_id'] as String?,
          title: 'Service documents',
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

  Widget _doneStep(OnboardingState s) {
    final t = Theme.of(context);
    final status = '${s.partner['status'] ?? 'unapproved'}';
    final docs = _docsFor(s);
    final steps = [
      for (final st in _stepsFor(s))
        if (st != OnboardingStep.avatar || _photoStep) st,
    ];
    final paused = [for (final r in _vehicleStatuses) if (r['status'] == 'paused_age') r];
    final waiting = [for (final r in _vehicleStatuses) if (r['status'] == 'waiting_permit') r];
    final hasVehicle = _needsFor(s.partner).vehicle;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        key: const ValueKey('pending-approval'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 6, children: [
            Icon(Icons.hourglass_top, size: 30, color: t.colorScheme.primary),
            Text(
              switch (status) {
                'unapproved' => 'Pending admin approval',
                'changes-needed' => 'Changes needed',
                _ => 'Application submitted',
              },
              style: t.textTheme.titleLarge,
            ),
            Text(switch (status) {
              'unapproved' =>
                'An admin is checking your ID, documents${hasVehicle ? ' and vehicle' : ''}. We will notify you when it is done.',
              'changes-needed' => 'An admin asked for some changes. Go back to Drive to see each one and fix it.',
              _ => 'Account status: $status.',
            }),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 6, children: [
            for (final st in steps) CheckLine(ok: true, text: st.label),
          ]),
        ),
      ),
      for (final r in paused)
        Card(
          key: ValueKey('pending-paused-${r['service']}'),
          child: ListTile(
            leading: Icon(Icons.pause_circle, color: t.colorScheme.error),
            title: Text('${r['service']} not active'),
            subtitle: Text('Your vehicle is over the ${r['max_age_years'] ?? ''}-year limit. Add a newer vehicle any time '
                'from My vehicles to turn it on.'),
          ),
        ),
      for (final r in waiting)
        Card(
          key: ValueKey('pending-permit-${r['service']}'),
          child: ListTile(
            leading: Icon(Icons.hourglass_top, color: t.colorScheme.tertiary),
            title: Text('${r['permit_name'] ?? 'Vehicle permit'} for ${r['service']}'),
            subtitle: Text('GET.ride uploads it for your vehicle after approval. ${r['service']} turns on once it is in.'),
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Drive stays locked until approved. '
          '${hasVehicle ? 'Partner and vehicle are reviewed together.' : 'No vehicle needed for these services.'}',
          style: t.textTheme.bodyMedium,
        ),
      ),
      PartnerDocsUploader(
        key: ValueKey('done:${s.partnerId}:${docs.map((d) => d.id).join(',')}'),
        partnerId: s.partnerId,
        docs: docs,
        authUserId: s.partner['auth_user_id'] as String?,
        title: 'Your documents',
        renewalLock: true,
        actionSummary: true,
      ),
      const SizedBox(height: 8),
      Text(
        "You can update any document that isn't approved. Approved documents with an expiry date can be renewed "
        'in the $renewalWindowDays days before they expire; uploading a new file moves it back to Pending Review.',
        style: t.textTheme.bodySmall,
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: () => context.push('/drive/vehicles'),
        icon: const Icon(Icons.directions_car_outlined),
        label: const Text('Add or manage your vehicles'),
      ),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: () => context.go('/drive'), child: const Text('Back to Drive')),
    ]);
  }
}

/// A step not reached yet: a plain muted label with a lock, not a chip, so
/// it doesn't read as a button. The next one up says "Next".
class _LockedStep extends StatelessWidget {
  const _LockedStep({super.key, required this.label, required this.next});

  final String label;
  final bool next;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    return Semantics(
      container: true,
      label: '$label, ${next ? 'next' : 'locked'}. Opens once the steps before it are done',
      excludeSemantics: true,
      child: Padding(
        // About a chip's height, so the row lines up.
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock_outline, size: 14, color: muted),
          const SizedBox(width: 4),
          Flexible(child: Text(next ? '$label · next' : label, style: t.textTheme.labelLarge?.copyWith(color: muted))),
        ]),
      ),
    );
  }
}
