import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_filters.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import '../../data/live_tables.dart';

final adminRidesProvider = FutureProvider.autoDispose.family<List<RideRequest>, String>((ref, group) async {
  ref.watchAdminLive('ride_requests');
  final rows = await ref.watch(adminRepositoryProvider).rides(statuses: rideStatusGroups[group]);
  return rows.map(RideRequest.new).toList();
});

class AdminRidesScreen extends ConsumerStatefulWidget {
  const AdminRidesScreen({super.key, this.initialFilter});
  final String? initialFilter;

  @override
  ConsumerState<AdminRidesScreen> createState() => _AdminRidesScreenState();
}

class _AdminRidesScreenState extends ConsumerState<AdminRidesScreen> {
  late String _group = rideStatusGroups.containsKey(widget.initialFilter) ? widget.initialFilter! : 'active';
  String _query = '';

  void _open(RideRequest r) {
    final canEdit = ref.read(moduleAccessProvider('rides')) == AccessLevel.edit;
    showAdminSheet<void>(
      context,
      title: '${r.pickupLabel} → ${r.dropLabel}',
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [StatusChip(r.raw['status'] as String?)]),
        const SizedBox(height: 12),
        DetailTable({
          'Request ID': r.id,
          'Service': r.service,
          'Fare': formatMoney(r.effectiveFare, r.currency),
          'Offered fare': r.offeredFare == null ? null : formatMoney(r.offeredFare, r.currency),
          'Payment': r.paymentMode,
          'Distance': formatDistance(r.distanceKm),
          'Rider': [r.riderName, r.riderPhone].whereType<String>().join(' · '),
          'Partner': [r.partnerName, r.partnerPhone].whereType<String>().join(' · '),
          'Vehicle': [r.partnerVehicle, r.partnerPlate].whereType<String>().join(' · '),
          'Pickup': r.pickupAddress,
          'Drop-off': r.dropAddress,
          'Note': r.note,
          'Area': [r.raw['city'], r.raw['state'], r.raw['country']].whereType<String>().join(', '),
          'Device / IP': [r.raw['device_os'], r.raw['ip_address']].whereType<String>().join(' · '),
          'Created': dateText(r.raw['created_at']),
          'Accepted': dateText(r.raw['accepted_at']),
          'Started': dateText(r.raw['started_at']),
          'Completed': dateText(r.raw['completed_at']),
          'Cancelled': dateText(r.raw['cancelled_at']),
          'Cancel reason': r.raw['cancel_reason'],
          'Commission': r.raw['commission_amount'] == null
              ? null
              : '${formatMoney(r.raw['commission_amount'] as num, r.currency)} '
                  '(${((r.raw['commission_rate'] as num? ?? 0) * 100).toStringAsFixed(1)}%)',
        }),
        if (canEdit && r.status.isOngoing) ...[
          const SizedBox(height: 16),
          BusyButton.outlined(
            icon: const Icon(Icons.cancel_outlined),
            child: const Text('Cancel this ride'),

            onPressed: () async {
              if (!await confirm(ctx, 'Cancel ride?', 'Both the rider and the partner will see it as cancelled.',
                  ok: 'Cancel ride')) {
                return;
              }
              if (!ctx.mounted) return;
              final ok = await runAdminAction(
                ctx,
                () => ref.read(adminRepositoryProvider).adminCancelRide(r.id, 'Cancelled by admin'),
                success: 'Ride cancelled',
              );
              if (ok) {
                ref.invalidate(adminRidesProvider(_group));
                if (ctx.mounted) Navigator.pop(ctx);
              }
            },
          ),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AdminPage(
      title: 'Rides',
      module: 'rides',
      actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(adminRidesProvider(_group))),
      ],
      body: Column(children: [
        FilterBar(
          filters: const {
            'active': 'In progress',
            'open': 'Open',
            'completed': 'Completed',
            'cancelled': 'Cancelled / expired',
            'all': 'All',
          },
          selected: _group,
          onSelected: (g) => setState(() => _group = g),
          onSearch: (q) => setState(() => _query = q),
          hint: 'Search rider, partner, place, plate…',
        ),
        Expanded(
          child: AsyncView(
            value: ref.watch(adminRidesProvider(_group)),
            onRetry: () => ref.invalidate(adminRidesProvider(_group)),
            data: (rides) {
              final q = _query.trim().toLowerCase();
              final list = q.isEmpty
                  ? rides
                  : rides
                      .where((r) => [
                            r.riderName, r.riderPhone, r.partnerName, r.partnerPhone, r.partnerPlate,
                            r.pickupLabel, r.dropLabel, r.id,
                          ].whereType<String>().any((s) => s.toLowerCase().contains(q)))
                      .toList();
              if (list.isEmpty) return const EmptyState(icon: Icons.local_taxi_outlined, title: 'No rides');
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = list[i];
                  return ListTile(
                    title: Text('${r.pickupLabel} → ${r.dropLabel}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text([
                      dateText(r.raw['created_at']),
                      r.riderName ?? 'rider',
                      if (r.partnerName != null) 'driver ${r.partnerName}',
                    ].join(' · ')),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(formatMoney(r.effectiveFare, r.currency)),
                        const SizedBox(height: 4),
                        StatusChip(r.raw['status'] as String?),
                      ],
                    ),
                    onTap: () => _open(r),
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}
