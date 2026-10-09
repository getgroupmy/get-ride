import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/screens/meterapp/pick_image.dart';
import '../../core/avatar.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/net_image.dart';

/// Where a new account lands after sign-up: Driver opens the Drive tab, where
/// partner onboarding starts; Passenger (and anything unknown) the map.
String signupLanding(String? role) => role == 'driver' ? '/drive' : '/';

/// The optional sign-up photo step (Expo `profile-photo.tsx`): the photo
/// becomes the avatar. Skip goes on without one; it can be added later from
/// Edit profile.
class SignupPhotoScreen extends ConsumerStatefulWidget {
  const SignupPhotoScreen({super.key, required this.next, this.pickPhoto = pickImage});

  /// Where Continue and Skip go.
  final String next;

  /// Photo picker (overridden in tests).
  final Future<PickedImage?> Function() pickPhoto;

  @override
  ConsumerState<SignupPhotoScreen> createState() => _SignupPhotoScreenState();
}

class _SignupPhotoScreenState extends ConsumerState<SignupPhotoScreen> {
  bool _uploading = false;

  Future<void> _pick() async {
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
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _done() => context.go(widget.next);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = ref.watch(profileProvider).value;
    final url = p?.avatarUrl;
    final initial = (p?.name?.trim().isNotEmpty ?? false) ? p!.name!.trim()[0].toUpperCase() : '?';
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        actions: [TextButton(onPressed: _uploading ? null : _done, child: const Text('Skip'))],
      ),
      body: SingleChildScrollView(
        child: ResponsiveCenter(
          maxWidth: 440,
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Add a profile photo', style: t.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'Drivers and passengers see it on your trips. Good lighting, no hat or sunglasses, '
                'and fill the frame with your face.',
                style: t.textTheme.bodyLarge,
              ),
              const SizedBox(height: 32),
              Center(
                child: CircleAvatar(
                  radius: 64,
                  child: _uploading
                      ? const CircularProgressIndicator()
                      : url == null
                      ? Text(initial, style: t.textTheme.displaySmall)
                      : ClipOval(
                          child: Image.network(
                            url,
                            width: 128,
                            height: 128,
                            fit: BoxFit.cover,
                            frameBuilder: boneUntilPainted(width: 128, height: 128, circle: true),
                            errorBuilder: (_, _, _) => const Icon(Icons.person, size: 64),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 32),
              BusyButton.outlined(
                onPressed: _uploading ? null : _pick,
                icon: const Icon(Icons.photo_camera_outlined),
                child: Text(url == null ? 'Choose photo' : 'Change photo'),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: url == null || _uploading ? null : _done, child: const Text('Continue')),
            ],
          ),
        ),
      ),
    );
  }
}
