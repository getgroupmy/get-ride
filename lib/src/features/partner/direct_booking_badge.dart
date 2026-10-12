// GET.now on the driver's side (migration 0161): a passenger who scanned
// this driver's code booked them directly. The request is offered to this
// driver alone, so it goes to the top of their list with its own label —
// distinct from My Ride's gold-star "regular rider".
import 'package:flutter/material.dart';

import '../../data/models.dart';

/// Whether [r] was booked directly with the driver [me].
bool bookedMeDirectly(RideRequest r, String? me) => me != null && r.directDriverId == me;

/// [list] with the requests booked directly with [me] first, each group
/// keeping its order.
List<RideRequest> pinDirectFirst(List<RideRequest> list, String? me) {
  if (me == null) return list;
  return [
    for (final r in list)
      if (bookedMeDirectly(r, me)) r,
    for (final r in list)
      if (!bookedMeDirectly(r, me)) r,
  ];
}

/// "Booked you directly", on a request a passenger booked with this
/// driver's GET.now code; nothing on any other.
class DirectBookingLabel extends StatelessWidget {
  const DirectBookingLabel({super.key, required this.request, required this.me});

  final RideRequest request;
  final String? me;

  @override
  Widget build(BuildContext context) {
    if (!bookedMeDirectly(request, me)) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        key: ValueKey('direct-booking-${request.id}'),
        children: [
          Icon(Icons.qr_code_2, size: 16, color: t.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Booked you directly',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.primary, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
