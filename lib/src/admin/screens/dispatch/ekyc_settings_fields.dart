// GET eKYC (migration 0439): our own eKYC server running the whole ID check
// in its page inside the app, switched on per use. Shown under "Checking
// their photos" (IdentityProviderFields). Each change is saved as it is
// made. GET eKYC never rejects anyone: its verdict and reasons are shown on
// the check, and a rider is auto-verified only when it approved AND the face
// match meets the country's auto-verify score.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ekyc.dart';
import '../../../data/ekyc_repository.dart';
import '../../../widgets/common.dart';

class EkycSettingsFields extends ConsumerStatefulWidget {
  const EkycSettingsFields({super.key, this.enabled = true});

  final bool enabled;

  @override
  ConsumerState<EkycSettingsFields> createState() => _EkycSettingsFieldsState();
}

class _EkycSettingsFieldsState extends ConsumerState<EkycSettingsFields> {
  EkycConfig? _saved;
  bool _busy = false;

  Future<void> _set(EkycConfig c) async {
    setState(() => _busy = true);
    try {
      final saved = await ref.read(ekycRepositoryProvider).setConfig(c);
      if (!mounted) return;
      setState(() => _saved = saved);
      ref.invalidate(ekycConfigProvider);
      showInfo(context, 'Saved');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  EkycConfig _with(EkycConfig c, {bool? on, bool? riderGate, bool? dispatchId, bool? test}) => EkycConfig(
        on: on ?? c.on,
        riderGate: riderGate ?? c.riderGate,
        dispatchId: dispatchId ?? c.dispatchId,
        test: test ?? c.test,
        serverKey: c.serverKey,
        webhookKey: c.webhookKey,
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final c = _saved ?? ref.watch(ekycConfigProvider).value;
    if (c == null) return const SizedBox.shrink();
    final on = widget.enabled && !_busy;
    Widget tile(String key, String title, String sub, bool value, ValueChanged<bool>? change) => SwitchListTile(
          key: ValueKey(key),
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          subtitle: Text(sub),
          value: value,
          onChanged: change,
        );
    return Column(
      key: const ValueKey('ekyc-settings'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        Text('GET eKYC', style: t.textTheme.titleSmall),
        Text(
          'Our own eKYC server runs the whole check in its page, inside the app: the ID front and back, a selfie '
          'with head turns, reading the card, the face match and sanctions screening. The result lands here as a '
          'check to review, with its verdict and reasons. It never rejects anyone.',
          style: muted,
        ),
        tile('ekyc-on', 'Use GET eKYC', 'Switch off to go back to the photo and selfie steps at once', c.on,
            on ? (v) => _set(_with(c, on: v)) : null),
        tile('ekyc-rider', 'Rider ID check before booking',
            'Verified straight away when GET eKYC approves and the face match meets the country\'s auto-verify score',
            c.riderGate, on && c.on ? (v) => _set(_with(c, riderGate: v)) : null),
        tile('ekyc-dispatch', 'Dispatch sign-in: the ID step',
            'An admin still approves each ID; the selfie step on a new phone stays as it is',
            c.dispatchId, on && c.on ? (v) => _set(_with(c, dispatchId: v)) : null),
        tile('ekyc-test', 'Test mode', 'Checks are marked as tests on GET eKYC and deleted there after 48 hours', c.test,
            on ? (v) => _set(_with(c, test: v)) : null),
        if (c.missingKeys != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(c.missingKeys!,
                key: const ValueKey('ekyc-keys-note'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
          ),
      ],
    );
  }
}
