// Admin → App Settings → PIN sign-in (migration 0192): how many wrong PINs
// lock an account, and for how long. Every account must have a PIN; after
// the second wrong try the sign-in screen says how many tries are left, and
// a locked PIN always offers an SMS code instead.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth_utils.dart';
import '../../../data/live_tables.dart';
import '../../../providers.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';

final pinPolicyProvider = FutureProvider.autoDispose<PinPolicy>((ref) async {
  ref.watchLive('app_settings');
  return PinPolicy.fromJson(await ref.watch(supabaseProvider).rpc('pin_policy'));
});

class PinPolicyCard extends ConsumerStatefulWidget {
  const PinPolicyCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  ConsumerState<PinPolicyCard> createState() => _PinPolicyCardState();
}

class _PinPolicyCardState extends ConsumerState<PinPolicyCard> {
  final _tries = TextEditingController();
  final _minutes = TextEditingController();
  PinPolicy? _loaded;

  @override
  void dispose() {
    _tries.dispose();
    _minutes.dispose();
    super.dispose();
  }

  void _load(PinPolicy p) {
    if (_loaded == p) return;
    _loaded = p;
    _tries.text = '${p.maxAttempts}';
    _minutes.text = '${p.lockMinutes}';
  }

  PinPolicy? _draft() {
    final tries = int.tryParse(_tries.text.trim());
    final minutes = int.tryParse(_minutes.text.trim());
    if (tries == null || tries < 3 || tries > 10 || minutes == null || minutes < 1 || minutes > 1440) return null;
    return PinPolicy(maxAttempts: tries, lockMinutes: minutes);
  }

  Future<void> _save() async {
    final p = _draft();
    if (p == null) {
      showInfo(context, 'Wrong PINs before the lock: 3–10. Lock: 1–1440 minutes.');
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(supabaseProvider).rpc('set_pin_policy', params: {'p_policy': p.toJson()}),
      success: 'PIN sign-in saved',
    );
    if (ok && mounted) ref.invalidate(pinPolicyProvider);
  }

  Widget _number(String key, TextEditingController c, String label, String hint) => SizedBox(
    width: 220,
    child: TextField(
      key: ValueKey('pin-policy-$key'),
      controller: c,
      enabled: widget.canEdit,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label, helperText: hint),
      onChanged: (_) => setState(() {}),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('pin-policy-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AsyncView(
          value: ref.watch(pinPolicyProvider),
          onRetry: () => ref.invalidate(pinPolicyProvider),
          data: (stored) {
            _load(stored);
            final draft = _draft();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('PIN sign-in', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'Every account must have a 6-digit PIN; one without is asked to set it before entering the app. '
                  'From the second wrong PIN the app says how many tries are left. A locked PIN can always be '
                  'bypassed with an SMS code. The wait between SMS codes is in Admin → SMS / WhatsApp.',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _number('tries', _tries, 'Wrong PINs before the lock', '3–10'),
                    _number('minutes', _minutes, 'Locked for (minutes)', '1–1440'),
                  ],
                ),
                if (widget.canEdit) ...[
                  const SizedBox(height: 12),
                  BusyButton.filled(
                    key: const ValueKey('pin-policy-save'),
                    onPressed: draft == null || draft == stored ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    child: const Text('Save PIN sign-in'),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
