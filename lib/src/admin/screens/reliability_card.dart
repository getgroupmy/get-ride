// Admin → SMS / WhatsApp → Reliability: switches for the parts of the app that
// keep working without a connection (lib/src/core/reliability_settings.dart).
// A switch applies the moment it moves; every app picks it up live.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/reliability_settings.dart';
import '../../data/reliability_repository.dart';
import '../../widgets/common.dart';
import '../widgets/admin_widgets.dart';

const _rows = [
  (
    key: 'chat_outbox',
    title: 'Chat messages wait for the connection',
    subtitle: 'A message written with no signal is kept on the phone and sent when it is back.',
  ),
  (
    key: 'ride_cache',
    title: 'Trips open with no connection',
    subtitle: 'The trip screen shows the ride as last seen, and a relaunch still finds it.',
  ),
  (
    key: 'background_ack',
    title: 'Confirm pushes while the app is closed',
    subtitle: 'A chat message shows delivered as soon as it lands, and is not sent again.',
  ),
  (
    key: 'server_trip_start',
    title: 'Trip start checked by the server',
    subtitle:
        'Only the server starts a trip, and drivers can\'t see the trip code. Turn on only after App Version '
        'has made every phone update: older builds can\'t start trips with it on.',
  ),
  (
    key: 'read_aloud',
    title: 'Read passenger messages aloud to drivers',
    subtitle: 'Drivers hear new messages during a trip, and can still turn it off for themselves.',
  ),
];

class ReliabilityCard extends ConsumerStatefulWidget {
  const ReliabilityCard({super.key, required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<ReliabilityCard> createState() => _ReliabilityCardState();
}

class _ReliabilityCardState extends ConsumerState<ReliabilityCard> {
  /// What the admin just set, shown until the saved row comes back.
  ReliabilitySettings? _pending;
  String? _saving;

  Future<void> _set(ReliabilitySettings current, String key, bool on) async {
    if (key == 'server_trip_start' && on) {
      final ok = await confirm(
        context,
        'Only the server starts trips?',
        'Drivers on an app older than this build won\'t be able to start trips. Turn this on only after '
            'App Version has made every phone update.',
        ok: 'Turn on',
      );
      if (!ok || !mounted) return;
    }
    final next = current.withSwitch(key, on);
    setState(() {
      _pending = next;
      _saving = key;
    });
    try {
      await ref.read(reliabilityRepositoryProvider).save(next);
      ref.invalidate(reliabilitySettingsProvider);
    } catch (e) {
      // Put the switch back: the database didn't take it.
      if (mounted) {
        setState(() => _pending = null);
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final loaded = ref.watch(reliabilitySettingsProvider);
    final saved = loaded.value;
    if (saved != null && _pending == saved) _pending = null;
    final s = _pending ?? saved ?? const ReliabilitySettings();
    return Card(
      key: const ValueKey('reliability-card'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Reliability', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'What the apps do when the connection drops. Changes apply at once, without a restart.',
                style: t.textTheme.bodySmall,
              ),
            ),
            for (final r in _rows)
              SwitchListTile(
                key: ValueKey('reliability-${r.key}'),
                title: Text(r.title),
                subtitle: Text(r.subtitle),
                value: s[r.key],
                secondary: _saving == r.key
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : null,
                onChanged: !widget.canEdit || _saving != null || saved == null ? null : (on) => _set(s, r.key, on),
              ),
            if (loaded.hasError)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text('Couldn’t load the saved switches; the offline ones are treated as on.', style: t.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}
