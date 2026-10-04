import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/screens/meterapp/pick_image.dart';
import '../../admin/screens/people/people_data.dart';
import '../../admin/screens/people/people_logic.dart';
import '../../admin/screens/people/people_widgets.dart';
import '../../core/partner_onboarding.dart';
import '../../data/partner_onboarding_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

typedef _Entries = List<({String id, Map<String, dynamic> values})>;

/// Becoming a partner (Expo `app/partner-onboarding.tsx`): profile photo,
/// ID, address, service area, partner type and the required documents, then
/// submitted for an admin to review. A returning partner lands on the first
/// step still missing; finished steps can be reopened from the header.
class PartnerOnboardingScreen extends ConsumerStatefulWidget {
  const PartnerOnboardingScreen({super.key});

  @override
  ConsumerState<PartnerOnboardingScreen> createState() => _PartnerOnboardingScreenState();
}

class _PartnerOnboardingScreenState extends ConsumerState<PartnerOnboardingScreen> {
  OnboardingState? _s;
  Object? _loadError;
  bool _busy = false;

  /// A finished step reopened from the header; null shows the first
  /// incomplete one.
  OnboardingStep? _viewing;

  final _ic = TextEditingController();
  final _address = TextEditingController();
  ServiceArea _area = const ServiceArea();
  List<String> _types = const [];
  GeoOptions _geo = const GeoOptions();
  _Entries _typeEntries = const [];
  _Entries _requiredDocs = const [];
  bool _docsComplete = false;

  PartnerOnboardingRepository get _repo => ref.read(partnerOnboardingRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ic.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final s = await _repo.load();
      final people = ref.read(peopleRepositoryProvider);
      final area = ServiceArea.fromRow(s.partner);
      final settled = await Future.wait<Object>([
        people.geoOptions(inUse: [area]),
        people.partnerTypes(),
        people.requiredDocuments(),
      ]);
      if (!mounted) return;
      setState(() {
        _s = s;
        _ic.text = '${s.partner['ic'] ?? s.profile?['ic'] ?? ''}';
        _address.text = '${s.partner['address'] ?? s.profile?['address'] ?? ''}';
        _area = area;
        _types = parseStringList(s.partner['partner_types']);
        _geo = settled[0] as GeoOptions;
        _typeEntries = settled[1] as _Entries;
        _requiredDocs = settled[2] as _Entries;
      });
      ref.invalidate(partnerProvider);
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  /// Runs one save, then shows the next step still missing.
  Future<void> _save(Future<OnboardingState> Function(OnboardingState s) action) async {
    final s = _s;
    if (s == null || _busy) return;
    setState(() => _busy = true);
    try {
      final next = await action(s);
      if (!mounted) return;
      setState(() {
        _s = next;
        _viewing = null;
      });
      ref.invalidate(partnerProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<OnboardingState> _patchBoth(OnboardingState s, Map<String, dynamic> patch) async {
    final profile = await _repo.patchProfile(patch);
    final withProfile = s.copyWith(profile: profile);
    return withProfile.copyWith(partner: await _repo.patchPartner(withProfile, patch));
  }

  // ---- Steps -----------------------------------------------------------------

  Future<void> _pickAvatar() async {
    final img = await pickImage();
    if (img == null) return;
    await _save((s) async {
      final url = await _repo.uploadAvatar(s, img.bytes, img.name);
      return _patchBoth(s, {'avatar_url': url});
    });
  }

  Future<void> _saveId() async {
    final ic = _ic.text.trim();
    if (ic.isEmpty) return showError(context, 'Please enter your ID number.');
    await _save((s) => _patchBoth(s, {'ic': ic}));
  }

  Future<void> _uploadIdImage() async {
    final img = await pickImage();
    if (img == null) return;
    final s = _s;
    if (s == null) return;
    setState(() => _busy = true);
    try {
      final url = await _repo.uploadIdImage(s, _ic.text.trim(), img.bytes, img.name);
      final profile = await _repo.patchProfile({'id_image': url});
      if (!mounted) return;
      setState(() => _s = s.copyWith(profile: profile));
      showInfo(context, 'ID image saved');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAddress() async {
    final address = _address.text.trim();
    if (address.isEmpty) return showError(context, 'Please enter your address.');
    await _save((s) => _patchBoth(s, {'address': address}));
  }

  Future<void> _saveArea() async {
    if (!_area.complete) {
      return showError(context, 'Please select at least one country, state and city you will serve.');
    }
    await _save((s) async => s.copyWith(partner: await _repo.patchPartner(s, _area.toRow())));
  }

  Future<void> _saveTypes() async {
    if (_types.isEmpty) return showError(context, 'Please select at least one partner type.');
    await _save((s) async => s.copyWith(partner: await _repo.patchPartner(s, partnerTypeColumns(_types))));
  }

  Future<void> _submit() async {
    if (!_docsComplete) {
      return showError(context, 'Please upload every compulsory document before submitting.');
    }
    await _save((s) async => s.copyWith(partner: await _repo.patchPartner(s, {'documents_ok': true})));
  }

  List<RequiredDoc> _docsFor(OnboardingState s) => requiredDocsFor(
        requiredDocuments: _requiredDocs,
        partnerTypeValues: _typeEntries.map((e) => e.values),
        partnerTypes: parseStringList(s.partner['partner_types']),
        area: ServiceArea.fromRow(s.partner),
      );

  // ---- Layout ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final s = _s;
    Widget body;
    if (_loadError != null) {
      body = EmptyState(
        icon: Icons.cloud_off,
        title: 'Could not load your partner profile',
        message: errorText(_loadError!),
        action: FilledButton(onPressed: _load, child: const Text('Try again')),
      );
    } else if (s == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final step = _viewing ?? s.step;
      body = ResponsiveCenter(
        maxWidth: 640,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          _header(s.step, step),
          const SizedBox(height: 16),
          if (_busy) const LinearProgressIndicator(),
          _stepBody(s, step),
        ]),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(s?.step == OnboardingStep.done ? 'Partner application' : 'Become a partner')),
      body: body,
    );
  }

  Widget _header(OnboardingStep reached, OnboardingStep showing) {
    final t = Theme.of(context);
    final reachedIndex = reached == OnboardingStep.done ? OnboardingStep.wizard.length : OnboardingStep.wizard.indexOf(reached);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        reached == OnboardingStep.done
            ? 'All steps complete'
            : 'Step ${reachedIndex + 1} of ${OnboardingStep.wizard.length}',
        style: t.textTheme.labelLarge,
      ),
      const SizedBox(height: 8),
      LinearProgressIndicator(value: reachedIndex / OnboardingStep.wizard.length),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (i, step) in OnboardingStep.wizard.indexed)
          ChoiceChip(
            avatar: i < reachedIndex ? const Icon(Icons.check, size: 16) : null,
            label: Text(step.label),
            selected: step == showing,
            // Finished steps can be reopened; later ones wait their turn.
            onSelected: i <= reachedIndex && !_busy
                ? (_) => setState(() => _viewing = step == reached ? null : step)
                : null,
          ),
      ]),
    ]);
  }

  Widget _stepBody(OnboardingState s, OnboardingStep step) => switch (step) {
        OnboardingStep.avatar => _avatarStep(s),
        OnboardingStep.id => _idStep(s),
        OnboardingStep.address => _textStep(
            title: 'Your address',
            subtitle: 'Where you live. It is kept private and only used to verify your account.',
            controller: _address,
            label: 'Address',
            maxLines: 3,
            onSave: _saveAddress,
          ),
        OnboardingStep.serviceArea => _section(
            title: 'Where will you drive?',
            subtitle: 'Choose every country, state and city you will take jobs in. '
                'This also decides which documents you need.',
            children: [
              ServiceAreaField(value: _area, options: _geo, enabled: !_busy, onChanged: (a) => setState(() => _area = a)),
              const SizedBox(height: 16),
              _continue(_saveArea),
            ],
          ),
        OnboardingStep.partnerType => _section(
            title: 'What kind of partner are you?',
            subtitle: 'Pick every service you will offer.',
            children: [
              PartnerTypeField(
                options: partnerTypeOptions(_typeEntries.map((e) => e.values)),
                value: _types,
                enabled: !_busy,
                onChanged: (v) => setState(() => _types = v),
              ),
              const SizedBox(height: 16),
              _continue(_saveTypes),
            ],
          ),
        OnboardingStep.requirements => _requirementsStep(s),
        OnboardingStep.done => _doneStep(s),
      };

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

  Widget _continue(VoidCallback onPressed, {String label = 'Save and continue'}) =>
      FilledButton(onPressed: _busy ? null : onPressed, child: Text(label));

  Widget _avatarStep(OnboardingState s) {
    final url = [s.partner['avatar_url'], s.profile?['avatar_url'], s.profile?['profile_image']]
        .map((v) => '${v ?? ''}'.trim())
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    return _section(
      title: 'Add a profile photo',
      subtitle: 'Riders see this on every trip. Use a clear photo of your face.',
      children: [
        Center(
          child: CircleAvatar(
            radius: 56,
            backgroundImage: url.isEmpty ? null : NetworkImage(url),
            child: url.isEmpty ? const Icon(Icons.person, size: 56) : null,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _pickAvatar,
          icon: const Icon(Icons.photo_camera_outlined),
          label: Text(url.isEmpty ? 'Choose photo' : 'Change photo'),
        ),
        if (url.isNotEmpty && _viewing == OnboardingStep.avatar) ...[
          const SizedBox(height: 8),
          OutlinedButton(onPressed: () => setState(() => _viewing = null), child: const Text('Keep this photo')),
        ],
      ],
    );
  }

  Widget _idStep(OnboardingState s) {
    final idImage = '${s.profile?['id_image'] ?? ''}'.trim();
    return _section(
      title: 'Your ID',
      subtitle: 'Your MyKad or passport number. A photo of the document helps an admin approve you sooner.',
      children: [
        TextField(
          controller: _ic,
          enabled: !_busy,
          decoration: const InputDecoration(labelText: 'ID number', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : _uploadIdImage,
          icon: Icon(idImage.isEmpty ? Icons.upload_file : Icons.check_circle_outline),
          label: Text(idImage.isEmpty ? 'Upload a photo of your ID (optional)' : 'ID photo saved — replace'),
        ),
        const SizedBox(height: 16),
        _continue(_saveId),
      ],
    );
  }

  Widget _textStep({
    required String title,
    required String subtitle,
    required TextEditingController controller,
    required String label,
    required VoidCallback onSave,
    int maxLines = 1,
  }) =>
      _section(title: title, subtitle: subtitle, children: [
        TextField(
          controller: controller,
          enabled: !_busy,
          maxLines: maxLines,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        _continue(onSave),
      ]);

  Widget _requirementsStep(OnboardingState s) {
    final docs = _docsFor(s);
    return _section(
      title: 'Upload your documents',
      subtitle: 'Tap each document to upload it. Every compulsory one is needed before you can submit; '
          'an admin then reviews them.',
      children: [
        PartnerDocsUploader(
          key: ValueKey('${s.partnerId}:${docs.map((d) => d.id).join(',')}'),
          partnerId: s.partnerId,
          docs: docs,
          authUserId: s.partner['auth_user_id'] as String?,
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
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        child: ListTile(
          leading: Icon(Icons.verified_outlined, color: t.colorScheme.primary),
          title: const Text('Application submitted'),
          subtitle: Text(status == 'unapproved'
              ? 'An admin will review your details and documents. You can take jobs from the Drive tab once '
                  'your account is approved.'
              : 'Account status: $status.'),
        ),
      ),
      const SizedBox(height: 16),
      PartnerDocsUploader(
        key: ValueKey('done:${s.partnerId}:${docs.map((d) => d.id).join(',')}'),
        partnerId: s.partnerId,
        docs: docs,
        authUserId: s.partner['auth_user_id'] as String?,
        title: 'Your documents',
      ),
      const SizedBox(height: 8),
      Text('A rejected or expired document can be uploaded again here.', style: t.textTheme.bodySmall),
      const SizedBox(height: 16),
      FilledButton(onPressed: () => context.go('/drive'), child: const Text('Back to Drive')),
    ]);
  }
}
