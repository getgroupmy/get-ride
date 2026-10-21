// After booking (migrations 0249 and 0258): when the rider chose a pickup door
// that has a step-by-step guide, and its airport or place shows guides, a
// card on the ride offers "How to find your driver at <door>" until the
// trip starts.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/airport_queue.dart';
import '../../data/airport_repository.dart';
import '../../data/models.dart';
import '../../widgets/page_style_host.dart';
import 'airport_door_sheet.dart' show AirportGuideViewer;

/// The guide's door for [ride], or null when there is no guide to show: no
/// door, a door without steps, the area's guide switched off, or the trip
/// under way.
AirportDoor? pickupGuideDoor(
  RideRequest ride,
  List<AirportDoor> doors,
  Map<String, AirportSettings> settings,
) {
  if (ride.status != RideStatus.open && ride.status != RideStatus.accepted && ride.status != RideStatus.arrived) {
    return null;
  }
  final id = ride.pickupDoorId;
  if (id == null) return null;
  final door = doors.where((d) => d.id == id).firstOrNull;
  if (door == null || door.guide.isEmpty) return null;
  final s = settings[ride.pickupAreaId ?? door.airportId];
  if (s != null && !s.guideOn) return null;
  return door;
}

class PickupGuideCard extends ConsumerWidget {
  const PickupGuideCard({super.key, required this.ride});
  final RideRequest ride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final door = pickupGuideDoor(
      ride,
      ref.watch(airportDoorsProvider).value ?? const [],
      ref.watch(airportSettingsProvider).value ?? const {},
    );
    if (door == null) return const SizedBox.shrink();
    final n = door.guide.length;
    return Card(
      key: const ValueKey('pickup-guide-card'),
      child: ListTile(
        leading: const Icon(Icons.directions_walk),
        title: Text('How to find your driver at ${door.name}'),
        subtitle: Text('$n step${n == 1 ? '' : 's'} with photos'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showAppSheet<void>(
          id: 'ride.pickup-guide',
          context: context,
          fitContent: true,
          showDragHandle: true,
          builder: (c) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: AirportGuideViewer(
              door: door,
              backLabel: 'Close',
              doneLabel: 'Done',
              onBack: () => Navigator.of(c).pop(),
              onPickHere: () => Navigator.of(c).pop(),
            ),
          ),
        ),
      ),
    );
  }
}
