import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/avatar.dart';
import '../../data/identity_repository.dart' show recordProfileSelfie;
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/live_selfie.dart';
import '../../widgets/net_image.dart';

/// Where a new account lands after sign-up: Driver goes straight into
/// partner registration (after the photo step, taken or skipped);
/// Passenger (and anything unknown) the map.
String signupLanding(String? role) => role == 'driver' ? driverSignupLanding : '/';

const driverSignupLanding = '/drive/onboarding';

/// Where the photo step goes on, from its `?next=`: one of the two sign-up
/// landings, never an arbitrary route from the URL ('/drive' is how links
/// made before partner registration said Driver).
String signupPhotoNext(String? next) =>
    signupLanding(const {'/drive', driverSignupLanding}.contains(next) ? 'driver' : null);

/// The optional sign-up photo step (Expo `profile-photo.tsx`): the photo
/// becomes the avatar. Skip goes on without one; it can be added later from
/// Edit profile. A live selfie (0281): the front camera with its blink or
/// head-turn check, and how it was taken kept for the admin.
class SignupPhotoScreen extends ConsumerStatefulWidget {
  const SignupPhotoScreen({super.key, required this.next, this.takeSelfie = takeLiveAvatar});

  /// Where Continue and Skip go.
  final String next;

  /// The live selfie camera, cut square (overridden in tests).
  final Future<LiveSelfie?> Function(BuildContext context) takeSelfie;

  @override
  ConsumerState<SignupPhotoScreen> createState() => _SignupPhotoScreenState();
}

class _SignupPhotoScreenState extends ConsumerState<SignupPhotoScreen> {
  bool _uploading = false;

  Future<void> _pick() async {
    final LiveSelfie? selfie;
    try {
      selfie = await widget.takeSelfie(context);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (selfie == null || !mounted) return;
    final photo = selfie.picked;
    final problem = avatarProblem(photo.bytes.length);
    if (problem != null) return showInfo(context, problem);
    setState(() => _uploading = true);
    try {
      final url = await ref
          .read(accountRepositoryProvider)
          .uploadAvatar(photo.bytes, ext: photo.ext, contentType: photo.contentType);
      await recordProfileSelfie(ref, url, selfie);
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
        // A driver needs the photo to be approved (partner registration asks
        // for it again): no Skip, rather than asking twice. A passenger's is
        // optional.
        actions: [
          if (widget.next != driverSignupLanding)
            TextButton(onPressed: _uploading ? null : _done, child: const Text('Skip')),
        ],
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
                '${widget.next == driverSignupLanding ? 'Drivers need one to be approved. ' : ''}'
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
                child: Text(url == null ? 'Take a selfie' : 'Take a new selfie'),
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
