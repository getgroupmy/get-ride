// The passenger's "Vehicle permit" button on the driver's card, from the
// driver's acceptance to the end of the trip (never on an offer, never after
// the trip): the permits of the ride's vehicle and driver that the country
// shows passengers. A vehicle on bypass has none, so no button.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/permits.dart';
import '../../data/models.dart';
import '../../data/permits_repository.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/permit_views.dart';

/// Whether the ride is between acceptance and the end of the trip.
bool ridePermitsShown(RideRequest r) =>
    r.hasDriver && r.partnerVehicleId != null &&
    (r.status == RideStatus.accepted || r.status == RideStatus.arrived || r.status == RideStatus.onTrip);

class RidePermitButton extends ConsumerWidget {
  const RidePermitButton({super.key, required this.ride});
  final RideRequest ride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ridePermitsShown(ride)) return const SizedBox.shrink();
    final v = ref.watch(ridePermitsProvider(ride.id)).value;
    final label = v == null ? null : permitButtonLabel(v.permits);
    if (v == null || label == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: PermitButton(
        key: const ValueKey('ride-permit-button'),
        label: label,
        onPressed: () => showAppSheet<void>(
          id: 'ride.vehicle-permits',
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (c) => PermitSheetBody(
            permits: v.permits,
            plate: ride.partnerPlate ?? v.plate,
            colours: ride.partnerPlateColours ?? v.colours,
            vehicleLabel: ride.partnerVehicle ?? v.label,
            onClose: () => Navigator.pop(c),
          ),
        ),
      ),
    );
  }
}
