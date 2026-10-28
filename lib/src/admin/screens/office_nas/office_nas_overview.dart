// Admin > Settings > Office NAS > Overview (migration 0318): connecting the
// NAS app (full admins), a card per NAS service from its last check-in
// (nas_services) and the box's numbers. Also the small pieces the other tabs
// of this page share.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/office_nas.dart';
import '../../../data/office_nas_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';

/// A tone's colour, readable in light and dark.
Color toneColor(Tone tone, ThemeData t) {
  final dark = t.brightness == Brightness.dark;
  return switch (tone) {
    Tone.ok => dark ? Colors.green.shade300 : Colors.green.shade800,
    Tone.warn => dark ? Colors.orange.shade300 : Colors.orange.shade900,
    Tone.bad => t.colorScheme.error,
    Tone.idle => t.colorScheme.onSurfaceVariant,
  };
}

Tone statusTone(UptimeStatus s) => switch (s) {
      UptimeStatus.up => Tone.ok,
      UptimeStatus.slow => Tone.warn,
      UptimeStatus.down => Tone.bad,
      UptimeStatus.unknown => Tone.idle,
    };

/// "Online · seen 20 s ago" in the page's corner.
class NasOnlineChip extends StatelessWidget {
  const NasOnlineChip(this.nas, {super.key});
  final OfficeNasState nas;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final (text, tone) = !nas.connected && nas.services.isEmpty
        ? ('Not connected', Tone.idle)
        : nas.online
            ? ('Online · seen ${agoText(nas.lastSeen, nas.now)}', Tone.ok)
            : ('Offline · seen ${agoText(nas.lastSeen, nas.now)}', Tone.bad);
    final c = toneColor(tone, t);
    return Center(
      child: Container(
        key: const ValueKey('office-nas-online'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(14)),
        child: Text(text, style: t.textTheme.labelLarge?.copyWith(color: c, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// A card's heading: an icon and a title.
class NasCardTitle extends StatelessWidget {
  const NasCardTitle(this.icon, this.title, {super.key, this.trailing});
  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(icon, color: t.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
        ?trailing,
      ]),
    );
  }
}

/// A labelled value with − and + buttons.
class NasStepper extends StatelessWidget {
  const NasStepper({super.key, required this.label, required this.value, this.hint, this.onDown, this.onUp, this.valueKey});

  final String label;
  final String? hint;
  final String value;

  /// Null: that way is at its limit, or the page is read-only.
  final VoidCallback? onDown, onUp;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: t.textTheme.bodyLarge),
            if (hint != null) Text(hint!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
        IconButton.outlined(tooltip: 'Lower $label', icon: const Icon(Icons.remove), onPressed: onDown),
        SizedBox(width: 84, child: Text(value, key: valueKey, textAlign: TextAlign.center, style: t.textTheme.titleMedium)),
        IconButton.outlined(tooltip: 'Raise $label', icon: const Icon(Icons.add), onPressed: onUp),
      ]),
    );
  }
}

/// A label and its value on one line, as the mockup's rows.
class NasRow extends StatelessWidget {
  const NasRow(this.label, this.value, {super.key, this.tone, this.valueKey, this.onTap});
  final String label;
  final String value;
  final Tone? tone;
  final Key? valueKey;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.dividerColor))),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(child: Text(label, style: t.textTheme.bodyMedium)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              key: valueKey,
              textAlign: TextAlign.end,
              style: t.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: tone == null ? null : toneColor(tone!, t),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The Overview tab.
class OfficeNasOverview extends ConsumerWidget {
  const OfficeNasOverview({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(officeNasProvider);
    final fullAdmin = ref.watch(adminAccessProvider).value?.isFullAdmin ?? false;
    return AsyncView(
      value: value,
      onRetry: () => ref.invalidate(officeNasProvider),
      errorTitle: "Couldn't load the NAS",
      data: (nas) {
        final t = Theme.of(context);
        return ResponsiveCenter(
          maxWidth: 1100,
          child: ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
            Text(
              'get.ride keeps working when the NAS is off: everything here is a fallback or a side job. Each '
              'service connects out with its own key; no ports open.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            _ConnectionCard(nas: nas, fullAdmin: fullAdmin),
            const SizedBox(height: 12),
            _Cards(nas: nas),
            if (boxLine(nas) case final line?) ...[
              const SizedBox(height: 12),
              Container(
                key: const ValueKey('office-nas-box'),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: t.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(line, style: t.textTheme.bodySmall),
              ),
            ],
          ]),
        );
      },
    );
  }
}

class _ConnectionCard extends ConsumerWidget {
  const _ConnectionCard({required this.nas, required this.fullAdmin});
  final OfficeNasState nas;
  final bool fullAdmin;

  Future<void> _connect(BuildContext context, WidgetRef ref) async {
    final name = await showAppDialog<String>(
      id: 'admin-office-nas.connect',
      context: context,
      builder: (_) => const _ConnectDialog(),
    );
    if (name == null || !context.mounted) return;
    ({String code, DateTime? expiresAt})? answer;
    final ok = await runAdminAction(context, () async {
      answer = await ref.read(officeNasRepositoryProvider).pairingCode(name);
    });
    if (!ok || answer == null || !context.mounted) return;
    final until = answer!.expiresAt == null ? null : DateFormat('HH:mm').format(answer!.expiresAt!);
    await showAppDialog<void>(
      id: 'admin-office-nas.code',
      context: context,
      builder: (c) {
        final t = Theme.of(c);
        return AlertDialog(
          title: const Text('Connection code'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SelectableText(
              answer!.code,
              key: const ValueKey('office-nas-code'),
              style: t.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 4),
            ),
            const SizedBox(height: 12),
            Text(
              'Put this code in the NAS app\'s .env as PAIR_CODE and start it (deploy/nas-backup/README.md). It works '
              'once, ${until == null ? 'for 10 minutes' : 'until $until'}. The app only calls out to get.ride, so no '
              'ports are opened on your network.',
              style: t.textTheme.bodySmall,
            ),
          ]),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done'))],
        );
      },
    );
    ref.invalidate(officeNasProvider);
  }

  Future<void> _disconnect(BuildContext context, WidgetRef ref, NasAgent a) async {
    if (!await confirm(context, 'Disconnect ${a.label}?',
        'Backups and the checks from the office stop at once and its key stops working. The backups already on the '
        'NAS stay there.',
        ok: 'Disconnect')) {
      return;
    }
    if (!context.mounted) return;
    await runAdminAction(context, () => ref.read(officeNasRepositoryProvider).disconnect(a.id));
    ref.invalidate(officeNasProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('office-nas-connection'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          NasCardTitle(
            Icons.dns_outlined,
            'Backup and uptime app',
            trailing: fullAdmin
                ? TextButton(
                    key: const ValueKey('office-nas-connect'),
                    onPressed: () => _connect(context, ref),
                    child: Text(nas.agents.isEmpty ? 'Connect the NAS' : 'Connect again'),
                  )
                : null,
          ),
          if (nas.agents.isEmpty)
            Text(
              'Not connected yet. Run the get.ride backup app in Docker on the NAS and give it a connection code'
              '${fullAdmin ? '' : ' (a full admin makes one)'}.',
              style: t.textTheme.bodySmall,
            ),
          for (final a in nas.agents)
            Row(children: [
              Icon(Icons.circle, size: 12, color: toneColor(a.online ? Tone.ok : Tone.bad, t)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${a.label} · ${a.online ? 'Online' : 'Offline'}, seen ${agoText(a.lastSeenAt, nas.now)}',
                      key: ValueKey('office-nas-agent-${a.id}'), style: t.textTheme.titleSmall),
                  if (a.model != null || a.appVersion != null)
                    Text([?a.model, if (a.appVersion != null) 'Version ${a.appVersion}'].join(' · '),
                        style: t.textTheme.bodySmall),
                ]),
              ),
              if (fullAdmin)
                TextButton(
                  key: ValueKey('office-nas-disconnect-${a.id}'),
                  onPressed: () => _disconnect(context, ref, a),
                  child: const Text('Disconnect'),
                ),
            ]),
        ]),
      ),
    );
  }
}

/// Names the NAS before its code is made. Owns its text box.
class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog();

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  final _label = TextEditingController(text: 'Office NAS');

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Connect the NAS'),
        content: TextField(
          key: const ValueKey('office-nas-label'),
          controller: _label,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. DS224+ office'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, _label.text.trim()), child: const Text('Get code')),
        ],
      );
}

/// The heartbeat cards: this batch's three, then any other NAS service that
/// checks in (the other batches' cards replace these at merge).
class _Cards extends StatelessWidget {
  const _Cards({required this.nas});
  final OfficeNasState nas;

  @override
  Widget build(BuildContext context) {
    const known = {'backup', 'uptime', 'box'};
    final cards = <Widget>[
      _HeartbeatCard(key: const ValueKey('office-nas-card-backups'), icon: Icons.backup_outlined, name: 'Backups', card: backupCard(nas)),
      _HeartbeatCard(key: const ValueKey('office-nas-card-uptime'), icon: Icons.monitor_heart_outlined, name: 'Uptime', card: uptimeCard(nas)),
      _HeartbeatCard(key: const ValueKey('office-nas-card-restore'), icon: Icons.restore, name: 'Restore test', card: restoreCard(nas)),
      for (final s in nas.services)
        if (!known.contains(s.service))
          _HeartbeatCard(
            key: ValueKey('office-nas-card-${s.service}'),
            icon: Icons.miscellaneous_services_outlined,
            name: StatusChip.labelFor(s.service),
            card: (
              status: s.onlineAt(nas.now) ? StatusChip.labelFor(s.status ?? 'running') : 'Not checking in',
              tone: s.onlineAt(nas.now) ? Tone.ok : Tone.bad,
              note: 'Seen ${agoText(s.lastSeen, nas.now)}${s.version == null ? '' : ' · v${s.version}'}',
            ),
          ),
    ];
    return LayoutBuilder(builder: (context, box) {
      final columns = box.maxWidth >= 900 ? 4 : (box.maxWidth >= 560 ? 2 : 1);
      const gap = 12.0;
      final width = (box.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(spacing: gap, runSpacing: gap, children: [for (final c in cards) SizedBox(width: width, child: c)]);
    });
  }
}

class _HeartbeatCard extends StatelessWidget {
  const _HeartbeatCard({super.key, required this.icon, required this.name, required this.card});
  final IconData icon;
  final String name;
  final Card3 card;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 20, color: t.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(child: Text(name, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 4),
        Text(card.status,
            style: t.textTheme.bodySmall?.copyWith(color: toneColor(card.tone, t), fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(card.note,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
