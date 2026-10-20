// A stand order on the driver's side (migration 0251): an order a taxi stand
// or counter made for a walk-in customer, offered to this driver alone
// ("Assigned to you") or to a group they are in ("Stand order · <group>").
// It is taken with the same Accept; Decline on an assigned order sends it
// straight back to the stand.
import 'package:flutter/material.dart';

import '../../core/dispatch.dart';
import '../../data/models.dart';

/// The request's stand order details for driver [me], or null.
StandOrderInfo? standOrderOf(RideRequest r, String? me) => StandOrderInfo.of(r.raw, me: me);

/// Requests with a stand order assigned to [me] first, each group keeping its order.
List<RideRequest> pinAssignedFirst(List<RideRequest> list, String? me) {
  bool mine(RideRequest r) => standOrderOf(r, me)?.assignedToMe ?? false;
  return [
    for (final r in list)
      if (mine(r)) r,
    for (final r in list)
      if (!mine(r)) r,
  ];
}

/// The card's stand line: who it is for, the stand, the ticket, the payment.
class StandOrderLabel extends StatelessWidget {
  const StandOrderLabel({super.key, required this.request, required this.me});

  final RideRequest request;
  final String? me;

  @override
  Widget build(BuildContext context) {
    final info = standOrderOf(request, me);
    if (info == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        key: ValueKey('stand-order-${request.id}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            info.assignedToMe ? Icons.person_pin_circle_outlined : Icons.storefront_outlined,
            size: 16,
            color: t.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.primary, fontWeight: FontWeight.w700),
                ),
                Text(
                  '${info.details} · ${info.fareMode == FareMode.meter ? 'Meter' : info.fareMode.label}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
