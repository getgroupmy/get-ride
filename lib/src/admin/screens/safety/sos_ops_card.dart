// Admin → App Settings → SOS alerts (migration 0193): who is alerted when a
// passenger or driver presses SOS, the ops numbers texted through the
// gateway's "Ops alert" channel, how often an unanswered SOS is sent again
// (from the second round to every full admin too), and how long the
// person's location keeps coming.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/live_tables.dart';
import '../../../data/safety_incident_repository.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';
import 'safety_incidents_screen.dart';
import '../../../widgets/search_select.dart';

final sosOpsConfigProvider = FutureProvider.autoDispose<SosOpsConfig>((ref) {
  ref.watchLive('app_settings');
  return ref.watch(safetyIncidentRepositoryProvider).config();
});

final sosAdminsProvider = FutureProvider.autoDispose<Map<String, String>>(
  (ref) => ref.watch(safetyIncidentRepositoryProvider).admins(),
);

class SosOpsCard extends ConsumerStatefulWidget {
  const SosOpsCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  ConsumerState<SosOpsCard> createState() => _SosOpsCardState();
}

class _SosOpsCardState extends ConsumerState<SosOpsCard> {
  final _numbers = TextEditingController();
  final _realert = TextEditingController();
  final _location = TextEditingController();
  Set<String> _onCall = {};
  bool _sms = true;
  SosOpsConfig? _loaded;

  @override
  void dispose() {
    _numbers.dispose();
    _realert.dispose();
    _location.dispose();
    super.dispose();
  }

  void _load(SosOpsConfig c) {
    if (_loaded == c) return;
    _loaded = c;
    _numbers.text = c.smsNumbers.join(', ');
    _realert.text = '${c.realertMinutes}';
    _location.text = '${c.locationMinutes}';
    _onCall = {...c.onCall};
    _sms = c.smsEnabled;
  }

  SosOpsConfig? _draft() {
    final realert = int.tryParse(_realert.text.trim());
    final location = int.tryParse(_location.text.trim());
    if (realert == null || realert < 1 || realert > 60 || location == null || location < 5 || location > 240) {
      return null;
    }
    return SosOpsConfig(
      onCall: _onCall.toList()..sort(),
      smsNumbers: parseOpsNumbers(_numbers.text),
      smsEnabled: _sms,
      realertMinutes: realert,
      locationMinutes: location,
    );
  }

  Future<void> _save() async {
    final c = _draft();
    if (c == null) {
      showInfo(context, 'Re-alert every 1–60 minutes; share the location for 5–240 minutes.');
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(safetyIncidentRepositoryProvider).saveConfig(c),
      success: 'SOS alerts saved',
    );
    if (ok && mounted) ref.invalidate(sosOpsConfigProvider);
  }

  Widget _number(String key, TextEditingController c, String label, String hint) => SizedBox(
    width: 240,
    child: TextField(
      key: ValueKey('sos-ops-$key'),
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
    final admins = ref.watch(sosAdminsProvider).value ?? const <String, String>{};
    return Card(
      key: const ValueKey('sos-ops-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AsyncView(
          value: ref.watch(sosOpsConfigProvider),
          onRetry: () => ref.invalidate(sosOpsConfigProvider),
          data: (stored) {
            _load(stored);
            final draft = _draft();
            final sorted = admins.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('SOS alerts', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    TextButton.icon(
                      key: const ValueKey('sos-ops-open-list'),
                      icon: const Icon(Icons.list_alt),
                      label: const Text('SOS history'),
                      onPressed: () => openSafetyIncidents(context),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'When a passenger or driver presses SOS, the on-call admins get an urgent push and the ops numbers '
                  'an SMS, with the trip, the plate and a map link. Until someone acknowledges it, it is sent again '
                  '-- from the second round to every full admin too. The other person on the trip is never told.',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                Text('On call', style: t.textTheme.labelLarge),
                const SizedBox(height: 4),
                if (sorted.isEmpty)
                  Text('No admins found.', style: t.textTheme.bodySmall)
                else
                  ListSearchFilter(
                    count: sorted.length,
                    hint: 'Search admins',
                    builder: (context, q) => Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final a in sorted)
                        if (q.isEmpty || searchSelectMatches(a.value, q) || _onCall.contains(a.key))
                          FilterChip(
                          key: ValueKey('sos-ops-oncall-${a.key}'),
                          label: Text(a.value),
                          selected: _onCall.contains(a.key),
                          onSelected: widget.canEdit
                              ? (on) => setState(() => on ? _onCall.add(a.key) : _onCall.remove(a.key))
                              : null,
                        ),
                    ],
                  ),
                  ),
                const SizedBox(height: 12),
                SwitchListTile(
                  key: const ValueKey('sos-ops-sms'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Also text the ops numbers'),
                  subtitle: const Text('Sent by the gateway phone on the "Ops alert" channel (Admin → SMS).'),
                  value: _sms,
                  onChanged: widget.canEdit ? (v) => setState(() => _sms = v) : null,
                ),
                TextField(
                  key: const ValueKey('sos-ops-numbers'),
                  controller: _numbers,
                  enabled: widget.canEdit && _sms,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Ops numbers',
                    helperText: 'Separate with commas, e.g. +60123456789, +60198765432',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _number('realert', _realert, 'Re-alert every (minutes)', '1–60'),
                    _number('location', _location, 'Share location for (minutes)', '5–240'),
                  ],
                ),
                if (widget.canEdit) ...[
                  const SizedBox(height: 12),
                  BusyButton.filled(
                    key: const ValueKey('sos-ops-save'),
                    onPressed: draft == null || draft == stored ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    child: const Text('Save SOS alerts'),
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
