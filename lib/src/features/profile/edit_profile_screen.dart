import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/screens/meterapp/pick_image.dart';
import '../../core/avatar.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

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
  bool _loaded = false;
  bool _busy = false;
  bool _uploading = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
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

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(profileProvider).value;
    if (!_loaded && p != null) {
      _name.text = p.name ?? '';
      _email.text = p.email ?? '';
      _loaded = true;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
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
              child: TextButton.icon(
                key: const ValueKey('profile-photo-change'),
                onPressed: _uploading || _busy ? null : _changePhoto,
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(p?.avatarUrl == null ? 'Add photo' : 'Change photo'),
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
            FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
          ]),
        ),
      ]),
    );
  }
}
