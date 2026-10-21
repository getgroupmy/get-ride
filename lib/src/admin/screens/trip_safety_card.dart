// Admin → App Settings → Trip safety (migrations 0154, 0269): the route
// check (off the planned route, stopped too long), how long the rider has
// to answer before their emergency contacts and support are told, 0154's
// start and mid-trip checks, and sharing trips with emergency contacts.
// Kept in the reliability row, as 0154's switches are.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/trip_safety.dart';
import '../../data/reliability_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import 'ride_offers_card.dart' show AdminNumberField;

class TripSafetyCard extends ConsumerStatefulWidget {
  const TripSafetyCard({super.key, required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<TripSafetyCard> createState() => _TripSafetyCardState();
}

class _TripSafetyCardState extends ConsumerState<TripSafetyCard> {
  final _offM = TextEditingController();
  final _offMin = TextEditingController();
  final _stopped = TextEditingController();
  final _noAnswer = TextEditingController();
  bool _route = true, _start = true, _separation = true, _share = true;
  SafetySettings? _loaded;

  @override
  void dispose() {
    for (final c in [_offM, _offMin, _stopped, _noAnswer]) {
      c.dispose();
    }
    super.dispose();
  }

  void _load(SafetySettings s) {
    if (_loaded == s) return;
    _loaded = s;
    _offM.text = '${s.routeOffM}';
    _offMin.text = '${s.routeOffMin}';
    _stopped.text = '${s.stoppedMin}';
    _noAnswer.text = '${s.noAnswerS}';
    _route = s.routeCheck;
    _start = s.startCheck;
    _separation = s.separation;
    _share = s.autoShare;
  }

  SafetySettings? _draft(SafetySettings base) {
    final a = AdminNumberField.read(_offM, SafetySettings.minRouteOff, SafetySettings.maxRouteOff);
    final b = AdminNumberField.read(_offMin, SafetySettings.minRouteOffMin, SafetySettings.maxRouteOffMin);
    final c = AdminNumberField.read(_stopped, SafetySettings.minStopped, SafetySettings.maxStopped);
    final d = AdminNumberField.read(_noAnswer, SafetySettings.minNoAnswer, SafetySettings.maxNoAnswer);
    if (a == null || b == null || c == null || d == null) return null;
    return base.copyWith(
      routeCheck: _route,
      routeOffM: a.toInt(),
      routeOffMin: b.toInt(),
      stoppedMin: c.toInt(),
      noAnswerS: d.toInt(),
      startCheck: _start,
      separation: _separation,
      autoShare: _share,
    );
  }

  Future<void> _save(SafetySettings next) async {
    try {
      final current = await ref.read(reliabilitySettingsProvider.future);
      await ref.read(reliabilityRepositoryProvider).save(current.withSafety(next));
      ref.invalidate(reliabilitySettingsProvider);
      if (mounted) showInfo(context, 'Trip safety saved');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Card(
      key: const ValueKey('trip-safety-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AsyncView(
          value: ref.watch(reliabilitySettingsProvider),
          onRetry: () => ref.invalidate(reliabilitySettingsProvider),
          data: (rel) {
            _load(rel.safety);
            final draft = _draft(rel.safety);
            void edited() => setState(() {});
            Widget toggle(String key, String title, String subtitle, bool value, ValueChanged<bool> set) =>
                SwitchListTile(
                  key: ValueKey('trip-safety-$key'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(title),
                  subtitle: Text(subtitle),
                  value: value,
                  onChanged: widget.canEdit ? (v) => setState(() => set(v)) : null,
                );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Trip safety', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'Checks on the rider\'s trip. When the rider doesn\'t answer in time, their emergency contacts get '
                  'the live trip link and support gets an SOS alert (without the call).',
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
                toggle('route', 'Route check', 'Ask when the car leaves the planned route or stops too long', _route,
                    (v) => _route = v),
                AdminNumberField(
                  key: const ValueKey('trip-safety-off-m'),
                  controller: _offM,
                  label: 'Off route by (m)',
                  min: SafetySettings.minRouteOff,
                  max: SafetySettings.maxRouteOff,
                  enabled: widget.canEdit && _route,
                  onChanged: edited,
                ),
                const SizedBox(height: 8),
                AdminNumberField(
                  key: const ValueKey('trip-safety-off-min'),
                  controller: _offMin,
                  label: 'For at least (min)',
                  min: SafetySettings.minRouteOffMin,
                  max: SafetySettings.maxRouteOffMin,
                  enabled: widget.canEdit && _route,
                  onChanged: edited,
                ),
                const SizedBox(height: 8),
                AdminNumberField(
                  key: const ValueKey('trip-safety-stopped'),
                  controller: _stopped,
                  label: 'Stopped too long (min)',
                  min: SafetySettings.minStopped,
                  max: SafetySettings.maxStopped,
                  enabled: widget.canEdit && _route,
                  onChanged: edited,
                ),
                const SizedBox(height: 8),
                AdminNumberField(
                  key: const ValueKey('trip-safety-no-answer'),
                  controller: _noAnswer,
                  label: 'No answer, then alert after (s)',
                  min: SafetySettings.minNoAnswer,
                  max: SafetySettings.maxNoAnswer,
                  enabled: widget.canEdit && _route,
                  onChanged: edited,
                ),
                toggle('start', '"Are you in the car?" start check',
                    'When a trip starts away from the passenger\'s phone', _start, (v) => _start = v),
                toggle('separation', '"Still on your trip?" check', 'When the phones drift apart mid-trip',
                    _separation, (v) => _separation = v),
                toggle(
                  'share',
                  'Auto-share trips with emergency contacts',
                  'Each rider chooses on Profile > Emergency contacts: every trip, at night only (10 pm to 6 am), '
                      'or never; at night unless they change it. By SMS or WhatsApp, the channels the sign-in code uses.',
                  _share,
                  (v) => _share = v,
                ),
                const SizedBox(height: 8),
                if (widget.canEdit)
                  BusyButton.filled(
                    key: const ValueKey('trip-safety-save'),
                    onPressed: draft == null || draft == rel.safety ? null : () => _save(draft),
                    icon: const Icon(Icons.save_outlined),
                    child: const Text('Save trip safety'),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
