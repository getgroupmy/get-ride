// Admin → SMS / WhatsApp → Reliability: switches for the parts of the app that
// keep working without a connection (lib/src/core/reliability_settings.dart).
// A switch applies the moment it moves; every app picks it up live.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ble_handshake.dart';
import '../../core/reliability_settings.dart';
import '../../core/trip_safety.dart';
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
    await _save(current.withSwitch(key, on), key);
  }

  Future<void> _setBle(ReliabilitySettings current, String key, BleSettings next) async {
    if (key == 'ble_autostart_no_pin' && next.autostartNoPin && !current.ble.autostartNoPin) {
      final ok = await confirm(
        context,
        'Start trips without the code?',
        'When both phones find each other at the pickup, close and for at least 5 seconds, and their GPS agrees, '
            'the trip starts by itself. The driver gets 3 seconds to cancel, and the code still works.',
        ok: 'Turn on',
      );
      if (!ok || !mounted) return;
    }
    await _save(current.withBle(next), key);
  }

  Future<void> _setSafety(ReliabilitySettings current, String key, SafetySettings next) async {
    if (key == 'safety_separation' && next.separation && !current.safety.separation) {
      final ok = await confirm(
        context,
        'Ask passengers mid-trip?',
        'When the passenger\'s and driver\'s phones stay apart during a trip, the passenger gets a notification '
            'asking if they\'re OK. Phones that don\'t share their location can\'t be checked.',
        ok: 'Turn on',
      );
      if (!ok || !mounted) return;
    }
    await _save(current.withSafety(next), key);
  }

  Future<void> _save(ReliabilitySettings next, String key) async {
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
            _BleSection(
              ble: s.ble,
              saving: _saving,
              enabled: widget.canEdit && _saving == null && saved != null,
              onChanged: (key, next) => _setBle(s, key, next),
            ),
            _SafetySection(
              safety: s.safety,
              saving: _saving,
              enabled: widget.canEdit && _saving == null && saved != null,
              onChanged: (key, next) => _setSafety(s, key, next),
            ),
            if (loaded.hasError)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Couldn’t load the saved switches; the offline ones are treated as on.',
                  style: t.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Bluetooth at the pickup (Phase D, 0153): the phones find each other and
/// the server confirms the right car; optionally it starts the trip.
class _BleSection extends ConsumerWidget {
  const _BleSection({required this.ble, required this.saving, required this.enabled, required this.onChanged});

  final BleSettings ble;
  final String? saving;
  final bool enabled;
  final void Function(String key, BleSettings next) onChanged;

  static const _rssiSteps = [-90, -85, -80, -75, -70, -65, -60, -55, -50];
  static const _timeouts = [10, 20, 30, 60];

  Widget? _spinner(String key) =>
      saving == key ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final on = enabled && ble.enabled;
    final stats = ref.watch(bleStartStatsProvider);
    return Column(
      key: const ValueKey('reliability-ble'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Bluetooth at pickup', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        ),
        SwitchListTile(
          key: const ValueKey('reliability-ble_enabled'),
          title: const Text('Phones find each other at pickup'),
          subtitle: const Text(
            'The rider\'s and driver\'s phones look for each other over Bluetooth and both see "✓ Correct car". '
            'Needs this build or newer; the trip code always still works.',
          ),
          value: ble.enabled,
          secondary: _spinner('ble_enabled'),
          onChanged: enabled ? (v) => onChanged('ble_enabled', ble.copyWith(enabled: v)) : null,
        ),
        SwitchListTile(
          key: const ValueKey('reliability-ble_android'),
          title: const Text('On Android phones'),
          value: ble.android,
          secondary: _spinner('ble_android'),
          onChanged: on ? (v) => onChanged('ble_android', ble.copyWith(android: v)) : null,
        ),
        SwitchListTile(
          key: const ValueKey('reliability-ble_ios'),
          title: const Text('On iPhones'),
          value: ble.ios,
          secondary: _spinner('ble_ios'),
          onChanged: on ? (v) => onChanged('ble_ios', ble.copyWith(ios: v)) : null,
        ),
        SwitchListTile(
          key: const ValueKey('reliability-ble_autostart_no_pin'),
          title: const Text('Start the trip without the code'),
          subtitle: const Text('Once the driver has arrived and the phones match, the trip starts by itself.'),
          value: ble.autostartNoPin,
          secondary: _spinner('ble_autostart_no_pin'),
          onChanged: on ? (v) => onChanged('ble_autostart_no_pin', ble.copyWith(autostartNoPin: v)) : null,
        ),
        SwitchListTile(
          key: const ValueKey('reliability-ble_chat'),
          title: const Text('Chat over Bluetooth when there\'s no signal'),
          subtitle: const Text(
            'At the pickup, a message that can\'t reach the server goes straight to the other phone. Short text only.',
          ),
          value: ble.chat,
          secondary: _spinner('ble_chat'),
          onChanged: on ? (v) => onChanged('ble_chat', ble.copyWith(chat: v)) : null,
        ),
        ListTile(
          title: const Text('How close'),
          subtitle: Text(
            'Signal of ${ble.rssiThresholdDbm} dBm or stronger. Closer to 0 means the phones must be nearer.',
          ),
          trailing: DropdownButton<int>(
            key: const ValueKey('reliability-ble_rssi'),
            value: _rssiSteps.contains(ble.rssiThresholdDbm) ? ble.rssiThresholdDbm : null,
            hint: Text('${ble.rssiThresholdDbm}'),
            items: [for (final v in _rssiSteps) DropdownMenuItem(value: v, child: Text('$v dBm'))],
            onChanged: on
                ? (v) => v == null ? null : onChanged('ble_rssi_threshold_dbm', ble.copyWith(rssiThresholdDbm: v))
                : null,
          ),
        ),
        ListTile(
          title: const Text('Both phones within'),
          subtitle: const Text('How recent both sightings must be to count as a match.'),
          trailing: DropdownButton<int>(
            key: const ValueKey('reliability-ble_timeout'),
            value: _timeouts.contains(ble.matchTimeoutS) ? ble.matchTimeoutS : null,
            hint: Text('${ble.matchTimeoutS} s'),
            items: [for (final v in _timeouts) DropdownMenuItem(value: v, child: Text('$v s'))],
            onChanged: on
                ? (v) => v == null ? null : onChanged('ble_match_timeout_s', ble.copyWith(matchTimeoutS: v))
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            stats.when(
              data: (s) => s.describe(7),
              loading: () => 'Loading how trips started…',
              error: (_, _) => 'Couldn\u2019t load how trips started.',
            ),
            key: const ValueKey('reliability-ble-stats'),
            style: t.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// Trip safety signals (Phase D4, 0154): the start check, mid-trip
/// separation and lost item reports.
class _SafetySection extends ConsumerWidget {
  const _SafetySection({required this.safety, required this.saving, required this.enabled, required this.onChanged});

  final SafetySettings safety;
  final String? saving;
  final bool enabled;
  final void Function(String key, SafetySettings next) onChanged;

  static const _distances = [100, 200, 300, 500, 1000];
  static const _minutes = [2, 3, 5, 10];

  Widget? _spinner(String key) =>
      saving == key ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final summary = ref.watch(tripSafetySummaryProvider);
    final distances = enabled && (safety.startCheck || safety.separation);
    return Column(
      key: const ValueKey('reliability-safety'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Trip safety', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        ),
        SwitchListTile(
          key: const ValueKey('reliability-safety_start_check'),
          title: const Text('Check the passenger was there at the start'),
          subtitle: const Text(
            'A trip started with the two phones far apart, or with the passenger\'s phone never seeing the car, '
            'is flagged and the passenger is asked "Are you in the car?".',
          ),
          value: safety.startCheck,
          secondary: _spinner('safety_start_check'),
          onChanged: enabled ? (v) => onChanged('safety_start_check', safety.copyWith(startCheck: v)) : null,
        ),
        SwitchListTile(
          key: const ValueKey('reliability-safety_separation'),
          title: const Text('Ask when the phones drift apart mid-trip'),
          subtitle: const Text('The passenger is asked "Are you still on your trip?", with a button for help.'),
          value: safety.separation,
          secondary: _spinner('safety_separation'),
          onChanged: enabled ? (v) => onChanged('safety_separation', safety.copyWith(separation: v)) : null,
        ),
        SwitchListTile(
          key: const ValueKey('reliability-safety_lost_items'),
          title: const Text('"Left something behind?" after a trip'),
          subtitle: const Text('Passengers report lost items for 7 days; the driver answers found or not.'),
          value: safety.lostItems,
          secondary: _spinner('safety_lost_items'),
          onChanged: enabled ? (v) => onChanged('safety_lost_items', safety.copyWith(lostItems: v)) : null,
        ),
        ListTile(
          title: const Text('Apart means more than'),
          trailing: DropdownButton<int>(
            key: const ValueKey('reliability-safety_far_apart'),
            value: _distances.contains(safety.farApartM) ? safety.farApartM : null,
            hint: Text('${safety.farApartM} m'),
            items: [for (final v in _distances) DropdownMenuItem(value: v, child: Text('$v m'))],
            onChanged: distances
                ? (v) => v == null ? null : onChanged('safety_far_apart_m', safety.copyWith(farApartM: v))
                : null,
          ),
        ),
        ListTile(
          title: const Text('Apart mid-trip for'),
          trailing: DropdownButton<int>(
            key: const ValueKey('reliability-safety_minutes'),
            value: _minutes.contains(safety.separationMin) ? safety.separationMin : null,
            hint: Text('${safety.separationMin} min'),
            items: [for (final v in _minutes) DropdownMenuItem(value: v, child: Text('$v min'))],
            onChanged: enabled && safety.separation
                ? (v) => v == null ? null : onChanged('safety_separation_min', safety.copyWith(separationMin: v))
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            summary.when(
              data: (s) => s.describe(7),
              loading: () => 'Loading trip safety…',
              error: (_, _) => 'Couldn\u2019t load trip safety.',
            ),
            key: const ValueKey('reliability-safety-summary'),
            style: t.textTheme.bodySmall,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextButton.icon(
              key: const ValueKey('reliability-open-report'),
              onPressed: () => context.push('/admin/m/ble-report'),
              icon: const Icon(Icons.insights_outlined, size: 18),
              label: const Text('Open the Bluetooth & safety report'),
            ),
          ),
        ),
      ],
    );
  }
}
