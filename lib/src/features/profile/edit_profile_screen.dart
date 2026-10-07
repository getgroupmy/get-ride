import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/screens/meterapp/pick_image.dart';
import '../../core/avatar.dart';
import '../../core/profile_identity.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/side_menu_host.dart';

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key, this.pickPhoto = pickImage});

  /// Photo picker (overridden in tests).
  final Future<PickedImage?> Function() pickPhoto;

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
    if (email.isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      showInfo(context, 'Enter a valid email address.');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(accountRepositoryProvider).updateProfile(
            name: _name.text.trim(),
            email: email.isEmpty ? null : email,
            identity: identityPatch(country: _country, idNumber: _idNumber.text, address: _address.text),
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
      photo = await widget.pickPhoto();
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
      photo = await widget.pickPhoto();
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

  Future<void> _chooseCountry() async {
    final picked = await showModalBottomSheet<String>(
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
    return Scaffold(
      appBar: AppBar(leading: sideMenuLeading(context), title: const Text('Edit profile')),
      body: ListView(children: [
        ResponsiveCenter(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: CircleAvatar(
                key: const ValueKey('profile-photo'),
                radius: 44,
                backgroundImage: p?.avatarUrl != null ? NetworkImage(p!.avatarUrl!) : null,
                child: _uploading
                    ? const CircularProgressIndicator()
                    : p?.avatarUrl == null
                        ? const Icon(Icons.person, size: 44)
                        : null,
              ),
            ),
            Center(
              child: BusyButton.text(
                key: const ValueKey('profile-photo-change'),
                onPressed: _uploading || _busy ? null : _changePhoto,
                icon: const Icon(Icons.photo_camera_outlined),
                child: Text(p?.avatarUrl == null ? 'Add photo' : 'Change photo'),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Full name'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email (optional)'),
            ),
            const SizedBox(height: 16),
            TextField(
              enabled: false,
              controller: TextEditingController(text: p?.phone ?? ''),
              decoration: const InputDecoration(labelText: 'Mobile number'),
            ),
            const SizedBox(height: 24),
            Text('Identity', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              key: const ValueKey('profile-country'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.public),
              title: const Text('Country'),
              subtitle: Text(_country.isEmpty ? 'Select country' : _country),
              trailing: const Icon(Icons.chevron_right),
              onTap: _busy ? null : _chooseCountry,
            ),
            if (idImage != null && idImage.startsWith('http'))
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 1.6,
                  child: Image.network(
                    idImage,
                    key: const ValueKey('profile-id-image'),
                    fit: BoxFit.cover,
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
              controller: _idNumber,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Passport / ID number', hintText: 'As printed on your ID'),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('profile-address'),
              controller: _address,
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
