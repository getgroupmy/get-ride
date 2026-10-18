// Admin → SMS / WhatsApp → SMS fallback for trips (migration 0150): a trip
// alert the app never confirmed goes out as an SMS through the gateway phone.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sms_fallback.dart';
import '../../data/live_tables.dart';
import '../../data/messaging_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../widgets/admin_widgets.dart';
import '../../widgets/search_select.dart';

final smsFallbackProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('sms_fallback_settings');
  return ref.watch(messagingRepositoryProvider).smsFallback();
});

final smsFallbackSummaryProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('sms_fallback_settings');
  return ref.watch(messagingRepositoryProvider).smsFallbackSummary();
});

class SmsFallbackCard extends ConsumerWidget {
  const SmsFallbackCard({super.key, required this.canEdit});
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('sms-fallback-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('SMS fallback for trips', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              'When the app hasn’t confirmed a trip alert (driver assigned, driver arrived, trip cancelled) '
              'in time, it is sent once as an SMS through the gateway phone. It keeps to the sign-in SMS '
              'country and block lists, and waits while no gateway phone is online on the route.',
              style: t.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            AsyncView(
              value: ref.watch(smsFallbackProvider),
              onRetry: () => ref.invalidate(smsFallbackProvider),
              data: (s) => _Form(key: ValueKey(s.updatedAt), settings: s, canEdit: canEdit),
            ),
            const Divider(height: 32),
            const _Summary(),
          ],
        ),
      ),
    );
  }
}

class _Form extends ConsumerStatefulWidget {
  const _Form({super.key, required this.settings, required this.canEdit});
  final SmsFallbackSettings settings;
  final bool canEdit;

  @override
  ConsumerState<_Form> createState() => _FormState();
}

class _FormState extends ConsumerState<_Form> {
  late SmsFallbackSettings _draft = widget.settings;
  late final _cap = TextEditingController(text: '${widget.settings.perPhonePerHour}');

  @override
  void dispose() {
    _cap.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = _draft.copyWith(perPhonePerHour: int.tryParse(_cap.text.trim()) ?? 0);
    final problem = smsFallbackProblem(s);
    if (problem != null) {
      showInfo(context, problem);
      return;
    }
    await runAdminAction(
      context,
      () => ref.read(messagingRepositoryProvider).saveSmsFallback(s),
      success: 'SMS fallback saved',
    );
  }

  @override
  Widget build(BuildContext context) {
    final edit = widget.canEdit;
    final waits = {...smsFallbackWaits, _draft.afterSeconds}.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('sms-fallback-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Text trip alerts the app didn’t confirm'),
          subtitle: const Text('Off: trip alerts go by push only.'),
          value: _draft.enabled,
          onChanged: edit ? (v) => setState(() => _draft = _draft.copyWith(enabled: v)) : null,
        ),
        SwitchListTile(
          key: const ValueKey('sms-fallback-critical'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Urgent alerts only'),
          subtitle: const Text(
            'Driver assigned, arrived, trip cancelled and cancellation requests. '
            'Off: chat messages and other alerts are texted too.',
          ),
          value: _draft.criticalOnly,
          onChanged: edit ? (v) => setState(() => _draft = _draft.copyWith(criticalOnly: v)) : null,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          children: [
            SizedBox(
              width: 220,
              child: SearchableDropdownFormField<int>(
                key: const ValueKey('sms-fallback-wait'),
                isExpanded: true,
                initialValue: _draft.afterSeconds,
                decoration: const InputDecoration(labelText: 'Text it after', helperText: 'Without a confirmation'),
                items: [for (final w in waits) DropdownMenuItem(value: w, child: Text(smsFallbackWaitLabel(w)))],
                onChanged: edit ? (v) => setState(() => _draft = _draft.copyWith(afterSeconds: v)) : null,
              ),
            ),
            SizedBox(
              width: 220,
              child: SearchableDropdownFormField<String>(
                key: const ValueKey('sms-fallback-channel'),
                isExpanded: true,
                initialValue: _draft.channel,
                decoration: const InputDecoration(labelText: 'Sent by', helperText: 'The gateway phone on this route'),
                items: [
                  for (final e in smsFallbackChannels.entries)
                    DropdownMenuItem(
                      value: e.key,
                      child: Text(e.value, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: edit ? (v) => setState(() => _draft = _draft.copyWith(channel: v)) : null,
              ),
            ),
            SizedBox(
              width: 220,
              child: TextField(
                key: const ValueKey('sms-fallback-cap'),
                controller: _cap,
                enabled: edit,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Texts per number per hour', helperText: '1–30'),
              ),
            ),
          ],
        ),
        if (edit) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: BusyButton.filled(
              key: const ValueKey('sms-fallback-save'),
              icon: const Icon(Icons.save_outlined),
              onPressed: _save,
              child: const Text('Save'),
            ),
          ),
        ],
      ],
    );
  }
}

class _Summary extends ConsumerWidget {
  const _Summary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return AsyncView(
      value: ref.watch(smsFallbackSummaryProvider),
      onRetry: () => ref.invalidate(smsFallbackSummaryProvider),
      data: (s) {
        final pct = s.confirmedPercent;
        Widget stat(String key, String label, String value) => SizedBox(
          width: 150,
          child: Column(
            key: ValueKey('sms-fallback-stat-$key'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              Text(label, style: t.textTheme.bodySmall),
            ],
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Last 24 hours', style: t.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                stat('alerts', 'Trip alerts', '${s.alerts}'),
                stat('confirmed', 'Confirmed by the app', pct == null ? '—' : '$pct%'),
                stat('queued', 'Sent as SMS', '${s.smsQueued}'),
                stat('skipped', 'Not texted (limits, no number, trip moved on)', '${s.smsSkipped}'),
              ],
            ),
          ],
        );
      },
    );
  }
}
