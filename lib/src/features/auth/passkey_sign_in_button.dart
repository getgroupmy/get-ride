// "Sign in with a passkey" on the sign-in screen (migration 0179's
// switches; features/auth/passkey/ does the ceremony).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sign_in_security.dart';
import '../../data/session_guard.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import 'passkey/passkey.dart' as pk;

/// Whether passkeys are offered here: the admin's switch for this surface
/// is on, this build can run the ceremony, and the device can reach an
/// authenticator. Absent rather than disabled when any is missing: there
/// is nothing the person holding the phone could do about it.
final passkeyOfferedHereProvider = FutureProvider<bool>((ref) async {
  final config = await ref.watch(signInConfigProvider.future);
  final surface = signInSurface(isWeb: kIsWeb, platform: defaultTargetPlatform);
  if (!passkeyOffered(config, surface) || !pk.passkeysAvailable) return false;
  try {
    return await pk.passkeysUsable();
  } catch (_) {
    return false;
  }
});

/// "Continue with passkey", the first choice on the sign-in screen (as
/// inDrive does) wherever passkeys are offered; nothing elsewhere.
class PasskeySignInButton extends ConsumerStatefulWidget {
  const PasskeySignInButton({super.key});

  @override
  ConsumerState<PasskeySignInButton> createState() => _PasskeySignInButtonState();
}

class _PasskeySignInButtonState extends ConsumerState<PasskeySignInButton> {
  bool _busy = false;

  Future<void> _signIn() async {
    setState(() => _busy = true);
    try {
      final result = await ref.read(authRepositoryProvider).signInWithPasskey();
      if (!mounted) return;
      // Signed in: the router moves on by itself. Closing the prompt is a
      // decision, not a failure, so it says nothing.
      if (result.outcome == pk.PasskeyOutcome.failed) {
        showInfo(context, result.message ?? 'The passkey could not be used. Sign in with your number instead.');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(passkeyOfferedHereProvider).value != true) return const SizedBox.shrink();
    final t = Theme.of(context);
    return FilledButton.icon(
      key: const ValueKey('passkey-sign-in'),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        backgroundColor: t.colorScheme.inverseSurface,
        foregroundColor: t.colorScheme.onInverseSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      onPressed: _busy ? null : _signIn,
      icon: _busy
          ? SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: t.colorScheme.onInverseSurface),
            )
          : const Icon(Icons.how_to_reg_outlined),
      label: const Text('Continue with passkey'),
    );
  }
}

/// "You signed in on another device…", once, after this device was
/// signed out by a newer sign-in elsewhere (migration 0180).
class SignedOutElsewhereNote extends StatelessWidget {
  const SignedOutElsewhereNote({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: signedOutElsewhere,
      builder: (context, shown, _) {
        if (!shown) return const SizedBox.shrink();
        final t = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Card(
            key: const ValueKey('signed-out-elsewhere'),
            color: t.colorScheme.secondaryContainer,
            child: ListTile(
              leading: Icon(Icons.devices_other, color: t.colorScheme.onSecondaryContainer),
              title: Text(signedOutElsewhereMessage, style: TextStyle(color: t.colorScheme.onSecondaryContainer)),
              trailing: IconButton(
                tooltip: 'Dismiss',
                icon: Icon(Icons.close, color: t.colorScheme.onSecondaryContainer),
                onPressed: () => signedOutElsewhere.value = false,
              ),
            ),
          ),
        );
      },
    );
  }
}
