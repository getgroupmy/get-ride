// SOS to GET.ride's safety team (migration 0193), for admins: the red banner
// on every admin screen while an SOS is waiting, and the page that lists
// them, where an admin acknowledges (stops the re-alerts) and resolves.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/safety_incident_repository.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';

/// Red across the top of every admin screen until each SOS is acknowledged.
class SosAdminBanner extends ConsumerWidget {
  const SosAdminBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiting = [
      for (final i in ref.watch(activeIncidentsProvider).value ?? const <SafetyIncident>[])
        if (i.open) i,
    ];
    if (waiting.isEmpty) return const SizedBox.shrink();
    final first = waiting.first;
    return Material(
      key: const ValueKey('sos-admin-banner'),
      color: const Color(0xFFC62828),
      child: SafeArea(
        bottom: false,
        child: InkWell(
          onTap: () => openSafetyIncidents(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.sos, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    waiting.length == 1
                        ? 'SOS: ${first.roleLabel.toLowerCase()} ${first.reporterName} needs help'
                        : '${waiting.length} SOS alerts waiting',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Text('Open', style: TextStyle(color: Colors.white)),
                const Icon(Icons.chevron_right, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void openSafetyIncidents(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SafetyIncidentsScreen()));

class SafetyIncidentsScreen extends ConsumerWidget {
  const SafetyIncidentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('SOS alerts')),
      body: AsyncView(
        value: ref.watch(allIncidentsProvider),
        onRetry: () => ref.invalidate(allIncidentsProvider),
        data: (all) => all.isEmpty
            ? const EmptyState(icon: Icons.verified_user_outlined, title: 'No SOS alerts')
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [for (final i in all) _IncidentCard(incident: i)],
              ),
      ),
    );
  }
}

class _IncidentCard extends ConsumerWidget {
  const _IncidentCard({required this.incident});

  final SafetyIncident incident;

  Future<void> _resolve(BuildContext context, WidgetRef ref) async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Resolve this SOS?'),
        content: TextField(
          key: const ValueKey('sos-resolve-note'),
          controller: note,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'What happened (optional)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Resolve')),
        ],
      ),
    );
    final text = note.text.trim();
    note.dispose();
    if (ok != true || !context.mounted) return;
    await runAdminAction(
      context,
      () => ref.read(safetyIncidentRepositoryProvider).resolve(incident.id, note: text.isEmpty ? null : text),
      success: 'SOS resolved',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final i = incident;
    final when = i.createdAt == null ? '' : DateFormat('d MMM HH:mm').format(i.createdAt!);
    final color = switch (i.status) {
      'open' => t.colorScheme.errorContainer,
      'acknowledged' => t.colorScheme.tertiaryContainer,
      _ => null,
    };
    final onColor = switch (i.status) {
      'open' => t.colorScheme.onErrorContainer,
      'acknowledged' => t.colorScheme.onTertiaryContainer,
      _ => t.colorScheme.onSurface,
    };
    final map = i.mapUri;
    return Card(
      key: ValueKey('sos-incident-${i.id}'),
      color: color,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(i.resolved ? Icons.check_circle_outline : Icons.sos, color: onColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${i.roleLabel}: ${i.reporterName}',
                    style: t.textTheme.titleMedium?.copyWith(color: onColor, fontWeight: FontWeight.w700),
                  ),
                ),
                Text('$when · ${i.status}', style: t.textTheme.bodySmall?.copyWith(color: onColor)),
              ],
            ),
            const SizedBox(height: 6),
            DefaultTextStyle.merge(
              style: TextStyle(color: onColor),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (i.reporterPhone != null) SelectableText('Phone: ${i.reporterPhone}'),
                  if (i.plate != null || i.partnerName != null)
                    Text('Driver: ${[i.partnerName, i.plate, i.vehicle].whereType<String>().join(' · ')}'),
                  if (i.pickupName != null) Text('Trip: ${i.pickupName} → ${i.dropName ?? '?'}'),
                  Text(
                    i.locationAt == null
                        ? 'Location: unknown'
                        : 'Location at ${DateFormat('HH:mm:ss').format(i.locationAt!)}',
                  ),
                  if (i.note != null) Text('Note: ${i.note}'),
                  if (i.open && i.alertRound > 1) Text('Alerted ${i.alertRound} times'),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (map != null)
                  OutlinedButton.icon(
                    key: ValueKey('sos-map-${i.id}'),
                    icon: const Icon(Icons.map_outlined),
                    label: const Text('Map'),
                    onPressed: () => launchUrl(map, mode: LaunchMode.externalApplication),
                  ),
                if (i.reporterPhone != null)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.call_outlined),
                    label: const Text('Call'),
                    onPressed: () => launchUrl(Uri(scheme: 'tel', path: i.reporterPhone)),
                  ),
                if (i.open)
                  BusyButton.filled(
                    key: ValueKey('sos-ack-${i.id}'),
                    onPressed: () => runAdminAction(
                      context,
                      () => ref.read(safetyIncidentRepositoryProvider).acknowledge(i.id),
                      success: 'Acknowledged: no more re-alerts',
                    ),
                    child: const Text('Acknowledge'),
                  ),
                if (!i.resolved)
                  BusyButton.outlined(
                    key: ValueKey('sos-resolve-${i.id}'),
                    onPressed: () => _resolve(context, ref),
                    child: const Text('Resolve'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
