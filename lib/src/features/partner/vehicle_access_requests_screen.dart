import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/vehicle_access_repository.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/common.dart';
import '../../widgets/net_image.dart';
import '../../widgets/offline_strip.dart';

/// "Driver requests": a vehicle owner approves or declines a driver another
/// approver added to their car (migrations 0377 + 0391). Reached from the
/// owner's Vehicles screen and from the `vehicle_access_request` notification.
class VehicleAccessRequestsScreen extends ConsumerWidget {
  const VehicleAccessRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(ownerDriverRequestsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Driver requests')),
      body: OfflineStrip.over(AsyncView<List<OwnerDriverRequest>>(
        value: value,
        onRetry: () => ref.invalidate(ownerDriverRequestsProvider),
        data: (items) => items.isEmpty
            ? const EmptyState(
                icon: Icons.verified_user_outlined,
                title: 'No driver requests',
                message: 'When someone is added as a driver of your vehicle, '
                    'their request appears here for you to approve or decline.',
              )
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(ownerDriverRequestsProvider),
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  itemBuilder: (context, i) => ResponsiveCenter(
                    maxWidth: 640,
                    child: _RequestCard(key: ValueKey('driver-request-${items[i].assignmentId}'), item: items[i]),
                  ),
                ),
              ),
      )),
    );
  }
}

class _RequestCard extends ConsumerStatefulWidget {
  const _RequestCard({super.key, required this.item});
  final OwnerDriverRequest item;

  @override
  ConsumerState<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends ConsumerState<_RequestCard> {
  bool _busy = false;

  Future<void> _respond(bool approve) async {
    setState(() => _busy = true);
    final item = widget.item;
    try {
      await ref.read(vehicleAccessRepositoryProvider).respond(item.assignmentId, approve: approve);
      if (!mounted) return;
      ref.invalidate(ownerDriverRequestsProvider);
      unawaited(showAppNotice(
        id: 'notice.vehicle-access', context: context,
        message: approve
            ? '${item.driverName} can now drive ${item.plate ?? 'your vehicle'}.'
            : 'Declined ${item.driverName}.',
        kind: approve ? NoticeKind.success : NoticeKind.info));
    } catch (e) {
      if (!mounted) return;
      final m = e.toString();
      unawaited(showAppNotice(
        id: 'notice.vehicle-access', context: context,
        message: m.contains('not_allowed')
            ? "That vehicle isn't registered to you."
            : "Couldn't save. Try again.",
        kind: NoticeKind.error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final item = widget.item;
    final car = [item.plate, item.vehicleLabel].where((s) => (s ?? '').isNotEmpty).join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                NetAvatar(
                    url: item.driverAvatar, radius: 22,
                    fallback: Icon(Icons.person_outline, color: cs.onSurfaceVariant),
                    backgroundColor: cs.surfaceContainerHighest),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.driverName, style: t.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text('Wants to drive ${car.isEmpty ? 'your vehicle' : car}',
                          style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: ValueKey('driver-request-decline-${item.assignmentId}'),
                    style: OutlinedButton.styleFrom(foregroundColor: cs.error, side: BorderSide(color: cs.error)),
                    onPressed: _busy ? null : () => _respond(false),
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: ValueKey('driver-request-approve-${item.assignmentId}'),
                    onPressed: _busy ? null : () => _respond(true),
                    child: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Approve'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
