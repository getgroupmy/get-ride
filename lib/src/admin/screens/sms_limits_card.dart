// Admin → SMS / WhatsApp → Sign-in SMS limits (migration 0149): the limits
// the sign-in SMS hook keeps to, and what it did in the last hour.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/sms_limits.dart';
import '../../data/live_tables.dart';
import '../../data/messaging_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../widgets/admin_widgets.dart';

final smsLimitsProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('sms_settings');
  return ref.watch(messagingRepositoryProvider).smsLimits();
});

final smsActivityProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('sms_log');
  return ref.watch(messagingRepositoryProvider).smsActivity();
});

final smsLogProvider = FutureProvider.autoDispose.family<List<SmsLogEntry>, String?>((ref, status) {
  ref.watchLive('sms_log');
  return ref.watch(messagingRepositoryProvider).smsLog(status: status);
});

class SmsLimitsCard extends ConsumerWidget {
  const SmsLimitsCard({super.key, required this.canEdit});
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('sms-limits-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Sign-in SMS limits', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              'Every sign-in code goes out through the OTP gateway phone, within these limits. '
              'Supabase’s own Auth rate limits stay on as an upper cap.',
              style: t.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            AsyncView(
              value: ref.watch(smsLimitsProvider),
              onRetry: () => ref.invalidate(smsLimitsProvider),
              data: (s) => _LimitsForm(key: ValueKey(s.updatedAt), limits: s, canEdit: canEdit),
            ),
            const Divider(height: 32),
            _Activity(canEdit: canEdit),
          ],
        ),
      ),
    );
  }
}

class _LimitsForm extends ConsumerStatefulWidget {
  const _LimitsForm({super.key, required this.limits, required this.canEdit});
  final SmsLimits limits;
  final bool canEdit;

  @override
  ConsumerState<_LimitsForm> createState() => _LimitsFormState();
}

class _LimitsFormState extends ConsumerState<_LimitsForm> {
  late bool _enabled = widget.limits.enabled;
  late final _hour = TextEditingController(text: '${widget.limits.perPhonePerHour}');
  late final _day = TextEditingController(text: '${widget.limits.perPhonePerDay}');
  late final _resend = TextEditingController(text: '${widget.limits.minResendSeconds}');
  late final _global = TextEditingController(text: '${widget.limits.globalPerHour}');
  late final _prefixes = TextEditingController(text: widget.limits.allowedPrefixes.join(', '));
  late final _blocked = TextEditingController(text: widget.limits.blockedNumbers.join(', '));
  late final _template = TextEditingController(text: widget.limits.messageTemplate);

  @override
  void dispose() {
    for (final c in [_hour, _day, _resend, _global, _prefixes, _blocked, _template]) {
      c.dispose();
    }
    super.dispose();
  }

  SmsLimits _draft() => widget.limits.copyWith(
    enabled: _enabled,
    perPhonePerHour: int.tryParse(_hour.text.trim()) ?? 0,
    perPhonePerDay: int.tryParse(_day.text.trim()) ?? 0,
    minResendSeconds: int.tryParse(_resend.text.trim()) ?? 0,
    globalPerHour: int.tryParse(_global.text.trim()) ?? 0,
    allowedPrefixes: parsePhoneList(_prefixes.text),
    blockedNumbers: parsePhoneList(_blocked.text),
    messageTemplate: _template.text.trim(),
  );

  Future<void> _save() async {
    final s = _draft();
    final problem = smsLimitsProblem(s);
    if (problem != null) {
      showInfo(context, problem);
      return;
    }
    if (!s.enabled && widget.limits.enabled) {
      final ok = await confirm(
        context,
        'Turn off SMS sign-in?',
        'Nobody will be able to get a sign-in code by SMS until it is turned back on.',
        ok: 'Turn off',
      );
      if (!ok || !mounted) return;
    }
    await runAdminAction(
      context,
      () => ref.read(messagingRepositoryProvider).saveSmsLimits(s),
      success: 'Sign-in SMS limits saved',
    );
  }

  Widget _number(String key, TextEditingController c, String label, String hint) => SizedBox(
    width: 200,
    child: TextField(
      key: ValueKey('sms-limits-$key'),
      controller: c,
      enabled: widget.canEdit,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label, helperText: hint),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final edit = widget.canEdit;
    final changed = widget.limits.updatedAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('sms-limits-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('SMS sign-in on'),
          subtitle: const Text('Off: no sign-in code is sent by SMS.'),
          value: _enabled,
          onChanged: edit ? (v) => setState(() => _enabled = v) : null,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          children: [
            _number('hour', _hour, 'Codes per number per hour', '1–20'),
            _number('day', _day, 'Codes per number per day', '1–50'),
            _number('resend', _resend, 'Seconds between codes', '15–600'),
            _number('global', _global, 'Total codes per hour', 'All numbers together'),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('sms-limits-prefixes'),
          controller: _prefixes,
          enabled: edit,
          decoration: const InputDecoration(
            labelText: 'Allowed country prefixes',
            helperText: 'Comma separated, like +60. Empty allows every country.',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('sms-limits-blocked'),
          controller: _blocked,
          enabled: edit,
          maxLines: null,
          decoration: const InputDecoration(
            labelText: 'Blocked numbers',
            helperText: 'Comma separated, with the country code (+60123456789).',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('sms-limits-template'),
          controller: _template,
          enabled: edit,
          maxLength: 300,
          decoration: const InputDecoration(labelText: 'Message', helperText: '{code} is replaced by the code.'),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                changed == null ? '' : 'Last changed ${DateFormat('d MMM yyyy, HH:mm').format(changed.toLocal())}',
                style: t.textTheme.bodySmall,
              ),
            ),
            if (edit)
              BusyButton.filled(
                key: const ValueKey('sms-limits-save'),
                icon: const Icon(Icons.save_outlined),
                onPressed: _save,
                child: const Text('Save'),
              ),
          ],
        ),
      ],
    );
  }
}

class _Activity extends ConsumerStatefulWidget {
  const _Activity({required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<_Activity> createState() => _ActivityState();
}

class _ActivityState extends ConsumerState<_Activity> {
  String? _status;

  Future<void> _block(String phone) async {
    final current = await ref.read(smsLimitsProvider.future);
    if (current.blockedNumbers.contains(phone) || !mounted) return;
    final ok = await confirm(
      context,
      'Block ${maskPhone(phone)}?',
      'No sign-in code will be sent to this number.',
      ok: 'Block',
    );
    if (!ok || !mounted) return;
    await runAdminAction(
      context,
      () => ref
          .read(messagingRepositoryProvider)
          .saveSmsLimits(current.copyWith(blockedNumbers: [...current.blockedNumbers, phone])),
      success: 'Number blocked',
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final activity = ref.watch(smsActivityProvider).value;
    Widget count(String label, int? n, Color color) => Expanded(
      child: Card(
        color: color.withValues(alpha: 0.12),
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Text(n == null ? '–' : '$n', style: t.textTheme.headlineSmall?.copyWith(color: color)),
              Text(label, style: t.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
    final cs = t.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Last hour', style: t.textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            count('Sent to gateway', activity?.queued, Colors.green),
            count('Blocked', activity?.blocked, Colors.orange),
            count('Failed', activity?.failed, cs.error),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            for (final (label, value) in const [
              ('All', null),
              ('Sent', 'queued'),
              ('Blocked', 'blocked'),
              ('Failed', 'failed'),
            ])
              ChoiceChip(
                key: ValueKey('sms-log-filter-${value ?? 'all'}'),
                label: Text(label),
                selected: _status == value,
                onSelected: (_) => setState(() => _status = value),
              ),
          ],
        ),
        const SizedBox(height: 8),
        AsyncView(
          value: ref.watch(smsLogProvider(_status)),
          onRetry: () => ref.invalidate(smsLogProvider(_status)),
          data: (rows) => rows.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text('No sign-in SMS yet.', style: t.textTheme.bodySmall, textAlign: TextAlign.center),
                )
              : Column(
                  children: [
                    for (final r in rows)
                      ListTile(
                        key: ValueKey('sms-log-${r.id}'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          switch (r.status) {
                            'queued' => Icons.check_circle_outline,
                            'blocked' => Icons.block,
                            _ => Icons.error_outline,
                          },
                          color: switch (r.status) {
                            'queued' => Colors.green,
                            'blocked' => Colors.orange,
                            _ => cs.error,
                          },
                        ),
                        title: Text(maskPhone(r.phone)),
                        subtitle: Text(
                          [
                            if (r.createdAt != null) DateFormat('d MMM, HH:mm:ss').format(r.createdAt!.toLocal()),
                            if (smsReasonLabel(r.reason).isNotEmpty) smsReasonLabel(r.reason),
                          ].join(' · '),
                        ),
                        trailing: widget.canEdit && r.phone.startsWith('+')
                            ? IconButton(
                                key: ValueKey('sms-log-block-${r.id}'),
                                tooltip: 'Block this number',
                                icon: const Icon(Icons.block),
                                onPressed: () => _block(r.phone),
                              )
                            : null,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
