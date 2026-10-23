import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/screens/meterapp/pick_image.dart';
import '../../core/avatar.dart';
import '../../core/contact_phone.dart';
import '../../core/profile_identity.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/side_menu_host.dart';
import '../../widgets/net_image.dart';
import '../../widgets/storage_image.dart';
import '../../widgets/page_style_host.dart';

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key, this.pickPhoto = pickImage});

  /// Photo picker (overridden in tests).
  final Future<PickedImage?> Function(BuildContext context) pickPhoto;

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _idNumber = TextEditingController();
  final _address = TextEditingController();
  String _country = '';
  bool _loaded = false;
  bool _busy = false;
  bool _uploading = false;
  bool _uploadingId = false;
  String? _emailError;
  String? _idError;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _idNumber.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final email = _email.text.trim();
    // Both are checked every time, so a bad ID shows even when the email
    // is fine; the reason sits under its field.
    setState(() {
      _emailError = profileEmailProblem(email);
      _idError = _identityLocked ? null : idNumberProblem(_idNumber.text);
    });
    if (_emailError != null || _idError != null) return;
    setState(() => _busy = true);
    // An approved partner's name and ID are support's to change (0277): not sent.
    final locked = _identityLocked;
    try {
      await ref.read(accountRepositoryProvider).updateProfile(
            name: locked ? null : _name.text.trim(),
            email: email.isEmpty ? null : email,
            identity: identityPatch(country: _country, idNumber: _idNumber.text, address: _address.text)
              ..removeWhere((k, _) => locked && k == 'ic'),
          );
      ref.invalidate(profileProvider);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Picks a photo and saves it straight away, apart from the form: the
  /// name and email still need Save, the photo does not.
  Future<void> _changePhoto() async {
    final PickedImage? photo;
    try {
      photo = await widget.pickPhoto(context);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (photo == null || !mounted) return;
    final problem = avatarProblem(photo.bytes.length);
    if (problem != null) return showInfo(context, problem);
    setState(() => _uploading = true);
    try {
      await ref
          .read(accountRepositoryProvider)
          .uploadAvatar(photo.bytes, ext: photo.ext, contentType: photo.contentType);
      ref.invalidate(profileProvider);
      if (mounted) showInfo(context, 'Profile photo updated');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// Photographs the passport or ID and saves it straight away, like the
  /// profile photo; the number and address still need Save.
  Future<void> _changeIdPhoto() async {
    final PickedImage? photo;
    try {
      photo = await widget.pickPhoto(context);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (photo == null || !mounted) return;
    final problem = avatarProblem(photo.bytes.length);
    if (problem != null) return showInfo(context, problem);
    setState(() => _uploadingId = true);
    try {
      await ref
          .read(accountRepositoryProvider)
          .uploadIdImage(photo.bytes, ext: photo.ext, contentType: photo.contentType);
      ref.invalidate(profileProvider);
      if (mounted) showInfo(context, 'ID photo saved');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploadingId = false);
    }
  }

  /// An approved partner's name, ID number and photo are the person riders
  /// were shown; support changes them, and the change shows on both the
  /// profile and the partner record (0277).
  bool get _identityLocked => ref.read(partnerProvider).value?.approved ?? false;

  Future<void> _chooseCountry() async {
    final picked = await showAppSheet<String>(id: 'edit-profile.choose-country',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: _CountryPicker(selected: _country)),
    );
    if (picked != null && mounted) setState(() => _country = picked);
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(profileProvider).value;
    if (!_loaded && p != null) {
      _name.text = p.name ?? '';
      _email.text = p.email ?? '';
      _country = p.nationality ?? '';
      _idNumber.text = p.idNumber ?? '';
      _address.text = p.address ?? '';
      _loaded = true;
    }
    final t = Theme.of(context);
    final idImage = p?.idImage;
    final locked = ref.watch(partnerProvider).value?.approved ?? false;
    return Scaffold(
      appBar: AppBar(leading: sideMenuLeading(context), title: const Text('Edit profile')),
      body: ListView(children: [
        ResponsiveCenter(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: _uploading
                  ? const CircleAvatar(
                      key: ValueKey('profile-photo'),
                      radius: 44,
                      child: CircularProgressIndicator(),
                    )
                  : NetAvatar(
                      key: const ValueKey('profile-photo'),
                      url: p?.avatarUrl,
                      radius: 44,
                      fallback: const Icon(Icons.person, size: 44),
                    ),
            ),
            Center(
              child: BusyButton.text(
                key: const ValueKey('profile-photo-change'),
                onPressed: _uploading || _busy || locked ? null : _changePhoto,
                icon: const Icon(Icons.photo_camera_outlined),
                child: Text(p?.avatarUrl == null ? 'Add photo' : 'Change photo'),
              ),
            ),
            const SizedBox(height: 8),
            if (locked) ...[
              Card(
                key: const ValueKey('profile-identity-locked'),
                margin: EdgeInsets.zero,
                color: t.colorScheme.surfaceContainerHighest,
                child: const ListTile(
                  leading: Icon(Icons.lock_outline),
                  title: Text('Name, ID number and photo are locked'),
                  subtitle: Text('You are an approved partner. Contact support to change them.'),
                ),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              key: const ValueKey('profile-name'),
              enabled: !locked,
              textInputAction: TextInputAction.next,
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Full name'),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('profile-email'),
              textInputAction: TextInputAction.next,
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: InputDecoration(labelText: 'Email (optional)', errorText: _emailError),
              onChanged: (_) {
                if (_emailError != null) setState(() => _emailError = null);
              },
            ),
            const SizedBox(height: 16),
            TextField(
              enabled: false,
              key: const ValueKey('profile-phone'),
              controller: TextEditingController(text: formatPhoneDisplay(p?.phone)),
              decoration: const InputDecoration(labelText: 'Mobile number'),
            ),
            // The number is changed with an SMS check, on its own page.
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                key: const ValueKey('profile-change-phone'),
                onPressed: () => context.push('/account/settings/phone'),
                child: const Text('Change phone number'),
              ),
            ),
            const SizedBox(height: 16),
            Text('Identity', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            // A picker field like the fields around it: its label, the
            // country (or what to do), and the chevron that opens the list.
            Semantics(
              button: true,
              child: InkWell(
                key: const ValueKey('profile-country'),
                borderRadius: BorderRadius.circular(12),
                onTap: _busy ? null : _chooseCountry,
                child: InputDecorator(
                  isEmpty: _country.isEmpty,
                  decoration: InputDecoration(
                    labelText: 'Country',
                    hintText: 'Select country',
                    prefixIcon: const Icon(Icons.public),
                    suffixIcon: const Icon(Icons.expand_more),
                    enabled: !_busy,
                  ),
                  child: Text(_country, style: t.textTheme.bodyLarge),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (idImage != null && idImage.startsWith('http'))
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 1.6,
                  child: StorageImage(
                    idImage,
                    key: const ValueKey('profile-id-image'),
                    fit: BoxFit.cover,
                    frameBuilder: boneUntilPainted(),
                    errorBuilder: (_, _, _) => const ColoredBox(
                      color: Colors.black12,
                      child: Center(child: Icon(Icons.badge_outlined, size: 40)),
                    ),
                  ),
                ),
              ),
            BusyButton.outlined(
              key: const ValueKey('profile-id-photo'),
              onPressed: _uploadingId || _busy ? null : _changeIdPhoto,
              icon: const Icon(Icons.document_scanner_outlined),
              child: Text(idImage == null ? 'Photograph passport or ID' : 'Retake ID photo'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('profile-id-number'),
              enabled: !locked,
              textInputAction: TextInputAction.next,
              controller: _idNumber,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Passport / ID number',
                hintText: 'As printed on your ID',
                errorText: _idError,
                errorMaxLines: 2,
              ),
              onChanged: (_) {
                if (_idError != null) setState(() => _idError = null);
              },
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('profile-address'),
              controller: _address,
              textInputAction: TextInputAction.newline,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Address', hintText: 'As printed on your ID'),
            ),
            const SizedBox(height: 24),
            BusyButton.filled(onPressed: _busy ? null : _save, child: const Text('Save')),
          ]),
        ),
      ]),
    );
  }
}

/// Searchable country list (Expo's country picker).
class _CountryPicker extends StatefulWidget {
  const _CountryPicker({required this.selected});
  final String selected;

  @override
  State<_CountryPicker> createState() => _CountryPickerState();
}

class _CountryPickerState extends State<_CountryPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final countries = searchCountries(_query);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: TextField(
          key: const ValueKey('country-search'),
          autofocus: true,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search country'),
          onChanged: (v) => setState(() => _query = v),
        ),
      ),
      Expanded(
        child: countries.isEmpty
            ? Center(child: Text('No countries match "$_query".'))
            : ListView.builder(
                itemCount: countries.length,
                itemBuilder: (_, i) => ListTile(
                  key: ValueKey('country-${countries[i]}'),
                  title: Text(countries[i]),
                  trailing: countries[i] == widget.selected ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(context, countries[i]),
                ),
              ),
      ),
    ]);
  }
}
