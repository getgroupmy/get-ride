// ignore_for_file: experimental_member_use
// `auth.passkey` is @experimental in gotrue (passkeys are a beta feature of
// the Supabase project); there is no other way to verify one.
//
// Settings → Passkeys: save a passkey for this account on this device, and
// see and remove the ones saved. A passkey on a lost phone is a key
// somebody else holds, so the list is how one is cut off. Offered only
// where the admin has turned passkeys on for this surface (migration 0179).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/sign_in_security.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../auth/passkey/passkey.dart' as pk;
import '../auth/passkey_sign_in_button.dart';
import '../../widgets/page_style_host.dart';

final _passkeysProvider = FutureProvider.autoDispose<List<Passkey>>(
  (ref) => ref.watch(authRepositoryProvider).passkeys(),
);

String _when(DateTime d) => DateFormat('d MMM yyyy').format(d.toLocal());

/// The Settings row; absent where passkeys aren't offered.
class PasskeysTile extends ConsumerWidget {
  const PasskeysTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(passkeyOfferedHereProvider).value != true) return const SizedBox.shrink();
    return Card(
      child: ListTile(
        key: const ValueKey('passkeys'),
        leading: const Icon(Icons.fingerprint),
        title: const Text('Passkeys'),
        subtitle: const Text('Sign in with your face or fingerprint'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/account/settings/passkeys'),
      ),
    );
  }
}

class PasskeysScreen extends ConsumerStatefulWidget {
  const PasskeysScreen({super.key});

  @override
  ConsumerState<PasskeysScreen> createState() => _PasskeysScreenState();
}

class _PasskeysScreenState extends ConsumerState<PasskeysScreen> {
  String? _note;

  Future<void> _save() async {
    final result = await ref.read(authRepositoryProvider).savePasskey();
    if (!mounted) return;
    switch (result.outcome) {
      case pk.PasskeyOutcome.signedIn:
        showInfo(context, 'Passkey saved. Next time, sign in with it.');
        ref.invalidate(_passkeysProvider);
      case pk.PasskeyOutcome.cancelled:
        break;
      case pk.PasskeyOutcome.failed:
        final m = result.message ?? 'The passkey could not be saved on this device.';
        // The app isn't associated with the site yet: a plain note, not an error.
        if (pk.passkeyNotSetUpHere(m)) {
          setState(() => _note = m);
        } else {
          showInfo(context, m);
        }
    }
  }

  Future<void> _remove(Passkey p) async {
    final ok = await showAppDialog<bool>(id: 'passkeys.remove',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove this passkey?'),
        content: Text(
          '${p.friendlyName ?? 'This passkey'} will no longer sign in to your account. '
          'You can still sign in with your number and PIN.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(authRepositoryProvider).removePasskey(p.id);
      ref.invalidate(_passkeysProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final fix = ref.watch(passkeyAddressFixProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Passkeys')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ResponsiveCenter(
            maxWidth: 560,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'A passkey lets you sign in with your face, fingerprint or screen lock instead of your number '
                  'and PIN. It stays on your device (or your Apple or Google account) and only works for GET.ride.',
                  style: t.textTheme.bodyMedium?.copyWith(color: muted),
                ),
                const SizedBox(height: 16),
                // On the wrong address the browser would refuse the passkey
                // without a word, so say where it works instead.
                if (fix != null) ...[
                  Card(
                    key: const ValueKey('passkeys-wrong-address'),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.info_outline, color: muted),
                              const SizedBox(width: 12),
                              Expanded(child: Text(passkeyWrongAddressMessage(ref.watch(passkeyPageProvider)))),
                            ],
                          ),
                          const SizedBox(height: 12),
                          FilledButton.tonalIcon(
                            key: const ValueKey('passkeys-open-www'),
                            onPressed: () => openPasskeyAddress(fix),
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('Open $passkeyHost'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_note != null) ...[
                  Card(
                    key: const ValueKey('passkeys-not-set-up'),
                    child: ListTile(leading: const Icon(Icons.info_outline), title: Text(_note!)),
                  ),
                  const SizedBox(height: 12),
                ],
                BusyButton.filled(
                  key: const ValueKey('passkeys-save'),
                  onPressed: _note == null && fix == null ? _save : null,
                  icon: const Icon(Icons.add),
                  child: const Text('Save a passkey on this device'),
                ),
                const SizedBox(height: 24),
                Text('Saved passkeys', style: t.textTheme.titleSmall),
                const SizedBox(height: 4),
                AsyncView(
                  value: ref.watch(_passkeysProvider),
                  onRetry: () => ref.invalidate(_passkeysProvider),
                  data: (list) => list.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text('None yet.', style: t.textTheme.bodyMedium?.copyWith(color: muted)),
                        )
                      : Column(
                          children: [
                            for (final p in list)
                              Card(
                                child: ListTile(
                                  key: ValueKey('passkey-${p.id}'),
                                  leading: const Icon(Icons.key_outlined),
                                  title: Text(p.friendlyName ?? 'Passkey'),
                                  subtitle: Text(
                                    'Saved ${_when(p.createdAt)}'
                                    '${p.lastUsedAt == null ? '' : ' · last used ${_when(p.lastUsedAt!)}'}',
                                  ),
                                  trailing: IconButton(
                                    tooltip: 'Remove',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _remove(p),
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// After a sign-in with number and PIN, offers once per account and device
/// to save a passkey, where passkeys are offered. Quiet in every other case.
Future<void> offerPasskeyOnce(BuildContext context, WidgetRef ref, String userId) async {
  if (await ref.read(passkeyOfferedHereProvider.future) != true) return;
  // Not on the wrong address: the browser would refuse it, and the offer
  // is kept for when this account signs in at www.getride.my.
  if (ref.read(passkeyAddressFixProvider) != null) return;
  final prefs = await SharedPreferences.getInstance();
  final key = 'passkey_offered_$userId';
  if (prefs.getBool(key) == true) return;
  List<Passkey> saved;
  try {
    saved = await ref.read(authRepositoryProvider).passkeys();
  } catch (_) {
    return;
  }
  await prefs.setBool(key, true);
  if (saved.isNotEmpty || !context.mounted) return;
  final yes = await showAppSheet<bool>(id: 'passkeys.offer-passkey-once',
    context: context,
    showDragHandle: true,
    builder: (c) {
      final t = Theme.of(c);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.fingerprint, size: 48, color: t.colorScheme.primary),
              const SizedBox(height: 12),
              Text('Faster sign-in next time?', textAlign: TextAlign.center, style: t.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Save a passkey and sign in with your face or fingerprint, without your number, PIN or SMS.',
                textAlign: TextAlign.center,
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const ValueKey('passkey-offer-yes'),
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Save a passkey'),
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
            ],
          ),
        ),
      );
    },
  );
  if (yes != true || !context.mounted) return;
  final result = await ref.read(authRepositoryProvider).savePasskey();
  if (!context.mounted) return;
  if (result.outcome == pk.PasskeyOutcome.signedIn) {
    showInfo(context, 'Passkey saved. Next time, sign in with it.');
  } else if (result.outcome == pk.PasskeyOutcome.failed && result.message != null) {
    showInfo(context, result.message!);
  }
}
