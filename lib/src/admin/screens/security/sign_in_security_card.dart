// Admin → App Settings → Sign-in security (migrations 0179 and 0180), and
// Admin → Users → an account's current device with "Sign out all devices".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/sign_in_security.dart';
import '../../../data/session_guard.dart';
import '../../../providers.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';

class SignInSecurityCard extends ConsumerStatefulWidget {
  const SignInSecurityCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  ConsumerState<SignInSecurityCard> createState() => _SignInSecurityCardState();
}

class _SignInSecurityCardState extends ConsumerState<SignInSecurityCard> {
  SignInConfig? _edited;

  Future<void> _save(SignInConfig stored, SignInConfig next) async {
    if (next.oneDevice && !stored.oneDevice) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('One device per account?'),
          content: const Text(
            'Accounts that are not admins or sub-admins will be signed in on one device at a time: signing in '
            'on a new phone signs the old one out.\n\n'
            'Turn this on only once App updates\' minimum is 1.4.8 or later. Older builds are not told why '
            'they stopped working.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Turn on')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final db = ref.read(supabaseProvider);
    final saved = await runAdminAction(
      context,
      () => db.rpc('set_sign_in_config', params: {'p_config': next.toJson()}),
      success: 'Sign-in security saved',
    );
    if (!mounted || !saved) return;
    setState(() => _edited = null);
    ref.invalidate(signInConfigProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return AsyncView(
      value: ref.watch(signInConfigProvider),
      onRetry: () => ref.invalidate(signInConfigProvider),
      data: (stored) {
        final c = _edited ?? stored;
        Widget toggle(String key, String title, String subtitle, bool value, SignInConfig Function(bool) set) =>
            SwitchListTile(
              key: ValueKey('sign-in-$key'),
              contentPadding: EdgeInsets.zero,
              value: value,
              onChanged: widget.canEdit ? (v) => setState(() => _edited = set(v)) : null,
              title: Text(title),
              subtitle: Text(subtitle),
            );
        return Card(
          key: const ValueKey('sign-in-security-card'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Sign-in security', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'Passkeys let people sign in with their face or fingerprint. Turn each surface on only once it is '
                  'set up: passkeys on in the Supabase dashboard (relying party www.getride.my) for all three, plus the '
                  'app association files for Android and iOS. A button shown before that fails for everyone.',
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
                const SizedBox(height: 8),
                toggle(
                  'passkey-web',
                  'Passkeys on the website',
                  'Sign in with a passkey on www.getride.my.',
                  c.passkeyWeb,
                  (v) => c.copyWith(passkeyWeb: v),
                ),
                toggle(
                  'passkey-android',
                  'Passkeys in the Android app',
                  'Needs assetlinks.json with both signing keys.',
                  c.passkeyAndroid,
                  (v) => c.copyWith(passkeyAndroid: v),
                ),
                toggle(
                  'passkey-ios',
                  'Passkeys in the iOS app',
                  'Needs the webcredentials association for www.getride.my.',
                  c.passkeyIos,
                  (v) => c.copyWith(passkeyIos: v),
                ),
                const Divider(height: 24),
                toggle(
                  'one-device',
                  'One device per account',
                  c.oneDevice
                      ? 'On: signing in on a new device signs the old one out. Admins and sub-admins are not limited.'
                      : 'Off: an account may be signed in on several devices.',
                  c.oneDevice,
                  (v) => c.copyWith(oneDevice: v),
                ),
                if (widget.canEdit) ...[
                  const SizedBox(height: 8),
                  BusyButton.filled(
                    key: const ValueKey('sign-in-security-save'),
                    onPressed: c == stored ? null : () => _save(stored, c),
                    icon: const Icon(Icons.save_outlined),
                    child: const Text('Save sign-in security'),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The account's recorded device, or null when none (off, an admin, or
/// a database without 0180).
final activeSessionProvider = FutureProvider.autoDispose.family<Map<String, dynamic>?, String>((ref, userId) async {
  try {
    final row = await ref.watch(supabaseProvider).from('active_sessions').select().eq('user_id', userId).maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  } catch (_) {
    return null;
  }
});

/// In the user sheet: where the account is signed in, and the button that
/// ends every sign-in (a lost or stolen phone, a support case).
class ActiveDeviceSection extends ConsumerWidget {
  const ActiveDeviceSection({super.key, required this.userId, required this.canEdit});

  final String userId;
  final bool canEdit;

  Future<void> _signOutEverywhere(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Sign out all devices?'),
        content: const Text(
          'Every device signed in to this account is signed out. They can sign in again with their number.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out all')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await runAdminAction(
      context,
      () => ref.read(supabaseProvider).rpc('admin_sign_out_everywhere', params: {'p_user': userId}),
      success: 'Signed out of every device',
    );
    ref.invalidate(activeSessionProvider(userId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final row = ref.watch(activeSessionProvider(userId)).value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            key: const ValueKey('admin-user-device'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.smartphone),
            title: const Text('Signed in on'),
            subtitle: Text(
              row == null
                  ? 'Not limited to one device'
                  : activeDeviceLine(row, when: (d) => DateFormat('d MMM HH:mm').format(d)),
              style: t.textTheme.bodySmall,
            ),
          ),
          if (canEdit)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('admin-user-sign-out-everywhere'),
                icon: const Icon(Icons.logout),
                label: const Text('Sign out all devices'),
                onPressed: () => _signOutEverywhere(context, ref),
              ),
            ),
        ],
      ),
    );
  }
}
