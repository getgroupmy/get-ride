// Admin > Settings > Office NAS > Uptime (migration 0318): every target with
// its last check (from the office NAS and from the cloud), its 30-day
// uptime and its history; adding and changing targets; when to alert and
// where (admin app push, Telegram, WhatsApp/SMS, email), a test alert, and
// the recent alerts. Every change saves at once (EDIT on Office NAS).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/office_nas.dart';
import '../../../data/office_nas_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../widgets/admin_widgets.dart';
import '../catalogue/catalogue_widgets.dart' show canEditPage;
import 'office_nas_overview.dart';

IconData _channelIcon(AlertChannel c) => switch (c) {
      AlertChannel.push => Icons.notifications_outlined,
      AlertChannel.telegram => Icons.send_outlined,
      AlertChannel.sms => Icons.sms_outlined,
      AlertChannel.email => Icons.mail_outline,
    };

/// What an address for [c] looks like, or null when [v] is one.
String? addressProblem(AlertChannel c, String v) {
  final s = v.trim();
  return switch (c) {
    AlertChannel.telegram => RegExp(r'^(-?\d{3,20}|@[A-Za-z0-9_]{5,32})$').hasMatch(s)
        ? null
        : 'A chat id (a number; a group\'s starts with -100) or @channelname',
    AlertChannel.sms => RegExp(r'^\+?\d{6,15}$').hasMatch(s.replaceAll(RegExp(r'[\s-]'), ''))
        ? null
        : 'A phone number with its country code, e.g. +60123456789',
    AlertChannel.email => RegExp(r'^[^@\s]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$').hasMatch(s) ? null : 'An email address',
    AlertChannel.push => null,
  };
}

/// The Uptime tab.
class OfficeNasUptime extends ConsumerStatefulWidget {
  const OfficeNasUptime({super.key});

  @override
  ConsumerState<OfficeNasUptime> createState() => _OfficeNasUptimeState();
}

class _OfficeNasUptimeState extends ConsumerState<OfficeNasUptime> {
  NasUptimeSettings? _cfg;

  Future<void> _save(NasUptimeSettings next) async {
    final before = _cfg;
    setState(() => _cfg = next);
    late NasUptimeSettings stored;
    final ok = await runAdminAction(context, () async {
      stored = await ref.read(officeNasRepositoryProvider).saveUptime(next);
    });
    if (!mounted) return;
    setState(() => _cfg = ok ? stored : before);
    if (ok) ref.invalidate(officeNasProvider);
  }

  Future<void> _editTarget(UptimeTarget? target) async {
    final result = await showAppDialog<_TargetEdit>(
      id: 'admin-office-nas.target',
      context: context,
      builder: (_) => _TargetDialog(target: target),
    );
    if (result == null || !mounted) return;
    final repo = ref.read(officeNasRepositoryProvider);
    if (result.delete) {
      if (!await confirm(context, 'Remove ${target!.name}?', 'Its checks stop and its history goes.', ok: 'Remove')) {
        return;
      }
      if (!mounted) return;
      await runAdminAction(context, () => repo.deleteTarget(target.id));
    } else {
      await runAdminAction(context, () => repo.saveTarget(result.target!));
    }
    ref.invalidate(officeNasProvider);
  }

  Future<void> _history(TargetStatus s) => showAppSheet<void>(
        id: 'admin-office-nas.uptime-history',
        context: context,
        isScrollControlled: true,
        builder: (_) => _HistorySheet(status: s),
      );

  Future<void> _addAddress(NasUptimeSettings cfg, AlertChannel c) async {
    final v = await showAppDialog<String>(
      id: 'admin-office-nas.address',
      context: context,
      builder: (_) => _AddressDialog(channel: c),
    );
    if (v == null || !mounted) return;
    await _save(switch (c) {
      AlertChannel.telegram => cfg.copyWith(telegramChats: [...cfg.telegramChats, v]),
      AlertChannel.sms => cfg.copyWith(smsNumbers: [...cfg.smsNumbers, v]),
      AlertChannel.email => cfg.copyWith(emails: [...cfg.emails, v]),
      AlertChannel.push => cfg,
    });
  }

  Future<void> _removeAddress(NasUptimeSettings cfg, AlertChannel c, String v) => _save(switch (c) {
        AlertChannel.telegram => cfg.copyWith(telegramChats: [for (final x in cfg.telegramChats) if (x != v) x]),
        AlertChannel.sms => cfg.copyWith(smsNumbers: [for (final x in cfg.smsNumbers) if (x != v) x]),
        AlertChannel.email => cfg.copyWith(emails: [for (final x in cfg.emails) if (x != v) x]),
        AlertChannel.push => cfg,
      });

  Future<void> _test() async {
    await runAdminAction(
      context,
      () => ref.read(officeNasRepositoryProvider).testAlert(),
      success: 'A test alert went to every channel that is on. Telegram and email follow within a minute.',
    );
    ref.invalidate(officeNasProvider);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = canEditPage(ref, officeNasPage);
    return AsyncView(
      value: ref.watch(officeNasProvider),
      onRetry: () => ref.invalidate(officeNasProvider),
      errorTitle: "Couldn't load the monitor",
      data: (nas) {
        final cfg = _cfg ?? nas.uptime;
        final t = Theme.of(context);
        return ResponsiveCenter(
          maxWidth: 1000,
          child: ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
            _TargetsCard(nas: nas, canEdit: canEdit, onEdit: _editTarget, onHistory: _history),
            const SizedBox(height: 12),
            _AlertsToCard(
              cfg: cfg,
              canEdit: canEdit,
              onChange: _save,
              onAdd: (c) => _addAddress(cfg, c),
              onRemove: (c, v) => _removeAddress(cfg, c, v),
              onTest: _test,
            ),
            const SizedBox(height: 12),
            _ChecksCard(cfg: cfg, canEdit: canEdit, onChange: _save),
            const SizedBox(height: 12),
            _RecentAlertsCard(nas: nas),
            const SizedBox(height: 12),
            Text(
              'Down for ${cfg.failAfter} ${cfg.failAfter == 1 ? 'check' : 'checks in a row'}: alert. Back up: '
              '"resolved". The monitor also runs on a cloud function, so a dead NAS is reported too.',
              key: const ValueKey('office-nas-uptime-note'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ]),
        );
      },
    );
  }
}

class _TargetsCard extends StatelessWidget {
  const _TargetsCard({required this.nas, required this.canEdit, required this.onEdit, required this.onHistory});
  final OfficeNasState nas;
  final bool canEdit;
  final ValueChanged<UptimeTarget?> onEdit;
  final ValueChanged<TargetStatus> onHistory;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final rows = nas.uptimeRows();
    final head = t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Card(
      key: const ValueKey('office-nas-targets'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          NasCardTitle(
            Icons.monitor_heart_outlined,
            'What is checked',
            trailing: canEdit
                ? TextButton.icon(
                    key: const ValueKey('office-nas-add-target'),
                    onPressed: () => onEdit(null),
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                  )
                : null,
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              Expanded(flex: 16, child: Text('Target', style: head)),
              Expanded(flex: 8, child: Text('Now', style: head)),
              Expanded(flex: 9, child: Text('Answer', style: head)),
              Expanded(flex: 9, child: Text('30 days', style: head)),
              if (canEdit) const SizedBox(width: 40),
            ]),
          ),
          for (final r in rows) _TargetRow(nas: nas, row: r, canEdit: canEdit, onEdit: onEdit, onHistory: onHistory),
        ]),
      ),
    );
  }
}

class _TargetRow extends StatelessWidget {
  const _TargetRow({required this.nas, required this.row, required this.canEdit, required this.onEdit, required this.onHistory});
  final OfficeNasState nas;
  final ({UptimeTarget target, TargetStatus? status}) row;
  final bool canEdit;
  final ValueChanged<UptimeTarget?> onEdit;
  final ValueChanged<TargetStatus> onHistory;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final target = row.target;
    final s = row.status;
    final status = target.on ? (s?.status ?? UptimeStatus.unknown) : UptimeStatus.unknown;
    final latest = s?.latest;
    final answer = !target.on
        ? 'Off'
        : latest == null
            ? '–'
            : latest.ms != null
                ? '${latest.ms} ms'
                : (latest.detail ?? '–').replaceFirst('Last seen ', 'seen ').replaceFirst('Last checked in ', 'seen ');
    final id = s?.id ?? target.id;
    return InkWell(
      key: ValueKey('office-nas-target-$id'),
      onTap: s == null ? null : () => onHistory(s),
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: t.dividerColor))),
        child: Row(children: [
          Expanded(
            flex: 16,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(s?.name ?? target.name,
                  style: t.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: target.on ? null : t.colorScheme.onSurfaceVariant,
                  )),
            ),
          ),
          Expanded(
            flex: 8,
            child: Text(
              target.on ? status.label : 'Off',
              key: ValueKey('office-nas-target-status-$id'),
              style: t.textTheme.bodySmall?.copyWith(color: toneColor(statusTone(status), t), fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(flex: 9, child: Text(answer, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall)),
          Expanded(
            flex: 9,
            child: Text(s?.uptime30 ?? '–', key: ValueKey('office-nas-target-uptime-$id'), style: t.textTheme.bodySmall),
          ),
          if (canEdit)
            SizedBox(
              width: 40,
              child: IconButton(
                key: ValueKey('office-nas-edit-$id'),
                tooltip: 'Change ${target.name}',
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: () => onEdit(target),
              ),
            ),
        ]),
      ),
    );
  }
}

class _AlertsToCard extends StatelessWidget {
  const _AlertsToCard({
    required this.cfg,
    required this.canEdit,
    required this.onChange,
    required this.onAdd,
    required this.onRemove,
    required this.onTest,
  });

  final NasUptimeSettings cfg;
  final bool canEdit;
  final ValueChanged<NasUptimeSettings> onChange;
  final ValueChanged<AlertChannel> onAdd;
  final void Function(AlertChannel, String) onRemove;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    String hint(AlertChannel c) => switch (c) {
          AlertChannel.push => 'Every full admin with the admin app.',
          AlertChannel.telegram => 'The bot token is in API Keys > Telegram > Bot. Chats:',
          AlertChannel.sms => 'Through the SMS gateway\'s Ops alert channel. Numbers:',
          AlertChannel.email => 'Through Resend (API Keys > Email > Resend). Addresses:',
        };
    return Card(
      key: const ValueKey('office-nas-alerts-to'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const NasCardTitle(Icons.campaign_outlined, 'Alerts go to'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in AlertChannel.values)
              FilterChip(
                key: ValueKey('office-nas-channel-${c.name}'),
                avatar: Icon(_channelIcon(c), size: 18),
                label: Text(c.label),
                selected: cfg.isOn(c),
                showCheckmark: false,
                onSelected: canEdit ? (v) => onChange(cfg.withChannel(c, v)) : null,
              ),
          ]),
          for (final c in AlertChannel.values)
            if (cfg.isOn(c)) ...[
              const SizedBox(height: 12),
              Text(c.label, style: t.textTheme.titleSmall),
              Text(hint(c), style: t.textTheme.bodySmall),
              if (cfg.addresses(c) case final list?)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    for (final v in list)
                      InputChip(
                        key: ValueKey('office-nas-address-${c.name}-$v'),
                        label: Text(v),
                        onDeleted: canEdit ? () => onRemove(c, v) : null,
                      ),
                    if (list.isEmpty)
                      Text('None yet: nothing is sent.',
                          style: t.textTheme.bodySmall?.copyWith(color: toneColor(Tone.warn, t))),
                    if (canEdit)
                      TextButton.icon(
                        key: ValueKey('office-nas-add-address-${c.name}'),
                        onPressed: () => onAdd(c),
                        icon: const Icon(Icons.add),
                        label: const Text('Add'),
                      ),
                  ]),
                ),
            ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('office-nas-test-alert'),
              onPressed: canEdit ? onTest : null,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Send a test alert'),
            ),
          ),
        ]),
      ),
    );
  }
}

class _ChecksCard extends StatelessWidget {
  const _ChecksCard({required this.cfg, required this.canEdit, required this.onChange});
  final NasUptimeSettings cfg;
  final bool canEdit;
  final ValueChanged<NasUptimeSettings> onChange;

  @override
  Widget build(BuildContext context) {
    String min(int n) => n == 1 ? '1 min' : '$n min';
    String secs(int ms) => '${(ms / 1000).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')} s';
    return Card(
      key: const ValueKey('office-nas-checks'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const NasCardTitle(Icons.tune, 'Checks'),
          NasStepper(
            label: 'Alert after',
            hint: 'Failed checks in a row from the NAS or the cloud',
            value: '${cfg.failAfter}',
            valueKey: const ValueKey('office-nas-fail-after'),
            onDown: canEdit && cfg.failAfter > 1 ? () => onChange(cfg.copyWith(failAfter: cfg.failAfter - 1)) : null,
            onUp: canEdit && cfg.failAfter < 10 ? () => onChange(cfg.copyWith(failAfter: cfg.failAfter + 1)) : null,
          ),
          NasStepper(
            label: 'From the NAS every',
            value: min(cfg.nasEveryMinutes),
            valueKey: const ValueKey('office-nas-nas-every'),
            onDown: canEdit && cfg.nasEveryMinutes > 1
                ? () => onChange(cfg.copyWith(nasEveryMinutes: cfg.nasEveryMinutes - 1))
                : null,
            onUp: canEdit && cfg.nasEveryMinutes < 60
                ? () => onChange(cfg.copyWith(nasEveryMinutes: cfg.nasEveryMinutes + 1))
                : null,
          ),
          NasStepper(
            label: 'From the cloud every',
            hint: 'Also covers the gateway phones, the NAS itself and last night\'s backup',
            value: min(cfg.cloudEveryMinutes),
            valueKey: const ValueKey('office-nas-cloud-every'),
            onDown: canEdit && cfg.cloudEveryMinutes > 1
                ? () => onChange(cfg.copyWith(cloudEveryMinutes: cfg.cloudEveryMinutes - 1))
                : null,
            onUp: canEdit && cfg.cloudEveryMinutes < 60
                ? () => onChange(cfg.copyWith(cloudEveryMinutes: cfg.cloudEveryMinutes + 1))
                : null,
          ),
          NasStepper(
            label: 'Slow from',
            hint: 'An answer this slow shows as Slow (still up)',
            value: secs(cfg.slowMs),
            valueKey: const ValueKey('office-nas-slow'),
            onDown: canEdit && cfg.slowMs > 500 ? () => onChange(cfg.copyWith(slowMs: cfg.slowMs - 500)) : null,
            onUp: canEdit && cfg.slowMs < 30000 ? () => onChange(cfg.copyWith(slowMs: cfg.slowMs + 500)) : null,
          ),
          NasStepper(
            label: 'Gateway phone late after',
            hint: 'Not checked in for this long: Slow',
            value: min(cfg.gatewayLateMinutes),
            valueKey: const ValueKey('office-nas-gateway-late'),
            onDown: canEdit && cfg.gatewayLateMinutes > 1
                ? () => onChange(cfg.copyWith(gatewayLateMinutes: cfg.gatewayLateMinutes - 1))
                : null,
            onUp: canEdit && cfg.gatewayLateMinutes < 120
                ? () => onChange(cfg.copyWith(
                    gatewayLateMinutes: cfg.gatewayLateMinutes + 1,
                    gatewayDownMinutes: cfg.gatewayDownMinutes <= cfg.gatewayLateMinutes + 1
                        ? cfg.gatewayLateMinutes + 2
                        : cfg.gatewayDownMinutes))
                : null,
          ),
          NasStepper(
            label: 'Gateway phone down after',
            value: min(cfg.gatewayDownMinutes),
            valueKey: const ValueKey('office-nas-gateway-down'),
            onDown: canEdit && cfg.gatewayDownMinutes > cfg.gatewayLateMinutes + 1
                ? () => onChange(cfg.copyWith(gatewayDownMinutes: cfg.gatewayDownMinutes - 1))
                : null,
            onUp: canEdit && cfg.gatewayDownMinutes < 240
                ? () => onChange(cfg.copyWith(gatewayDownMinutes: cfg.gatewayDownMinutes + 1))
                : null,
          ),
        ]),
      ),
    );
  }
}

class _RecentAlertsCard extends StatelessWidget {
  const _RecentAlertsCard({required this.nas});
  final OfficeNasState nas;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('office-nas-recent-alerts'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const NasCardTitle(Icons.history, 'Recent alerts'),
          if (nas.alerts.isEmpty) Text('None yet.', style: t.textTheme.bodySmall),
          for (final a in nas.alerts.take(10))
            ListTile(
              key: ValueKey('office-nas-alert-${a.id}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                a.kind == 'resolved' ? Icons.check_circle_outline : (a.kind == 'test' ? Icons.notifications_none : Icons.error_outline),
                color: toneColor(a.kind == 'resolved' ? Tone.ok : (a.kind == 'test' ? Tone.idle : Tone.bad), t),
              ),
              title: Text('${a.title} · ${agoText(a.createdAt, nas.now)}'),
              subtitle: Text([a.body, if (a.delivery.isNotEmpty) a.delivery].join('\n')),
            ),
        ]),
      ),
    );
  }
}

/// What the target dialog gives back.
class _TargetEdit {
  const _TargetEdit.save(Map<String, dynamic> this.target) : delete = false;
  const _TargetEdit.delete()
      : target = null,
        delete = true;
  final Map<String, dynamic>? target;
  final bool delete;
}

/// Adds a target (a web address or the database) or changes one.
class _TargetDialog extends StatefulWidget {
  const _TargetDialog({this.target});
  final UptimeTarget? target;

  @override
  State<_TargetDialog> createState() => _TargetDialogState();
}

class _TargetDialogState extends State<_TargetDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.target?.name ?? '');
  late final _url = TextEditingController(text: widget.target?.url == '{payment}' ? '' : (widget.target?.url ?? 'https://'));
  late final _slow = TextEditingController(text: widget.target?.slowMs == null ? '' : '${widget.target!.slowMs}');
  late bool _on = widget.target?.on ?? true;
  late bool _fromNas = widget.target?.fromNas ?? true;
  late bool _fromCloud = widget.target?.fromCloud ?? true;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _slow.dispose();
    super.dispose();
  }

  bool get _isHttp => (widget.target?.kind ?? 'http') == 'http';
  bool get _payment => widget.target?.url == '{payment}';

  void _done() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final t = widget.target;
    final url = _url.text.trim();
    Navigator.pop(
      context,
      _TargetEdit.save({
        if (t != null) 'id': t.id,
        'name': _name.text.trim(),
        'kind': t?.kind ?? 'http',
        'url': _isHttp ? (_payment && url.isEmpty ? '{payment}' : url) : null,
        'on': _on,
        'from_nas': _fromNas,
        'from_cloud': _fromCloud,
        'slow_ms': int.tryParse(_slow.text.trim()),
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.target;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(t == null ? 'Add a target' : 'Change ${t.name}'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextFormField(
                key: const ValueKey('office-nas-target-name'),
                controller: _name,
                maxLength: 80,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Give it a name' : null,
              ),
              if (_isHttp)
                TextFormField(
                  key: const ValueKey('office-nas-target-url'),
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'Web address',
                    helperText: _payment ? 'Empty: the payment gateway in use' : 'Up when it answers below 500',
                  ),
                  validator: (v) => (_payment && (v ?? '').trim().isEmpty) || uptimeUrlOk(v ?? '')
                      ? null
                      : 'A web address starting with https://',
                )
              else if (t != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(t.where, style: theme.textTheme.bodySmall),
                ),
              SwitchListTile(
                key: const ValueKey('office-nas-target-on'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Checked'),
                value: _on,
                onChanged: (v) => setState(() => _on = v),
              ),
              if (t == null || t.networkCheck) ...[
                CheckboxListTile(
                  key: const ValueKey('office-nas-target-from-nas'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('From the office NAS'),
                  value: _fromNas,
                  onChanged: (v) => setState(() => _fromNas = v ?? true),
                ),
                CheckboxListTile(
                  key: const ValueKey('office-nas-target-from-cloud'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('From the cloud'),
                  value: _fromCloud,
                  onChanged: (v) => setState(() => _fromCloud = v ?? true),
                ),
                TextFormField(
                  key: const ValueKey('office-nas-target-slow'),
                  controller: _slow,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Slow from (ms)', helperText: 'Empty: the setting below'),
                  validator: (v) {
                    final s = (v ?? '').trim();
                    if (s.isEmpty) return null;
                    final n = int.tryParse(s);
                    return n == null || n < 100 || n > 60000 ? 'From 100 to 60000' : null;
                  },
                ),
              ],
            ]),
          ),
        ),
      ),
      actions: [
        if (t != null && !t.builtin)
          TextButton(
            key: const ValueKey('office-nas-target-delete'),
            onPressed: () => Navigator.pop(context, const _TargetEdit.delete()),
            child: const Text('Remove'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('office-nas-target-save'), onPressed: _done, child: const Text('Save')),
      ],
    );
  }
}

/// One more chat, number or email address for [channel].
class _AddressDialog extends StatefulWidget {
  const _AddressDialog({required this.channel});
  final AlertChannel channel;

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final _form = GlobalKey<FormState>();
  final _value = TextEditingController();

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  void _done() {
    if (!(_form.currentState?.validate() ?? false)) return;
    var v = _value.text.trim();
    if (widget.channel == AlertChannel.sms) v = v.replaceAll(RegExp(r'[\s-]'), '');
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final (title, label) = switch (widget.channel) {
      AlertChannel.telegram => ('Add a Telegram chat', 'Chat id'),
      AlertChannel.sms => ('Add a number', 'Phone number'),
      _ => ('Add an email address', 'Email'),
    };
    return AlertDialog(
      title: Text(title),
      content: Form(
        key: _form,
        child: TextFormField(
          key: const ValueKey('office-nas-address'),
          controller: _value,
          autofocus: true,
          keyboardType: widget.channel == AlertChannel.sms
              ? TextInputType.phone
              : (widget.channel == AlertChannel.email ? TextInputType.emailAddress : TextInputType.text),
          decoration: InputDecoration(labelText: label),
          validator: (v) => addressProblem(widget.channel, v ?? ''),
          onFieldSubmitted: (_) => _done(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('office-nas-address-save'), onPressed: _done, child: const Text('Add')),
      ],
    );
  }
}

/// A target's last 200 checks.
class _HistorySheet extends ConsumerStatefulWidget {
  const _HistorySheet({required this.status});
  final TargetStatus status;

  @override
  ConsumerState<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends ConsumerState<_HistorySheet> {
  // Read once: the sheet's builder runs again as it is dragged.
  late final Future<List<UptimeCheckRow>> _rows = ref.read(officeNasRepositoryProvider).history(widget.status.id);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final status = widget.status;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => FutureBuilder<List<UptimeCheckRow>>(
        future: _rows,
        builder: (context, snap) {
          final rows = snap.data ?? const [];
          return ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
            Text(status.name, style: t.textTheme.titleLarge),
            Text('${status.uptime30} up over 30 days · ${status.checks30} checks', style: t.textTheme.bodySmall),
            const SizedBox(height: 8),
            if (snap.connectionState != ConnectionState.done) const LinearProgressIndicator(),
            if (snap.hasError) Text("Couldn't load the checks.", style: TextStyle(color: t.colorScheme.error)),
            if (snap.connectionState == ConnectionState.done && rows.isEmpty && !snap.hasError)
              Text('No checks in the last 7 days.', style: t.textTheme.bodySmall),
            for (final r in rows)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.circle, size: 12, color: toneColor(statusTone(r.status), t)),
                title: Text('${whenText(r.at, DateTime.now())} · ${r.source == 'nas' ? 'From the office' : 'From the cloud'}'),
                subtitle: Text([r.status.label, if (r.ms != null) '${r.ms} ms', ?r.detail].join(' · ')),
              ),
          ]);
        },
      ),
    );
  }
}
