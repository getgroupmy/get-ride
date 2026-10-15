// The passenger's side of a mid-trip handover (migration 0199): approve or
// decline the driver's request, then see the new driver on their way.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/trip_handover.dart';
import '../../data/models.dart';
import '../../data/trip_handover_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';

class RiderHandoverCard extends ConsumerWidget {
  const RiderHandoverCard({super.key, required this.ride});
  final RideRequest ride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ride.status != RideStatus.onTrip || ride.fromCache) return const SizedBox.shrink();
    final h = ref.watch(rideHandoverProvider(ride.id));
    final t = Theme.of(context);
    if (h != null && h.status == TripHandoverStatus.awaitingRider) {
      final on = t.colorScheme.onTertiaryContainer;
      final repo = ref.read(tripHandoverRepositoryProvider);
      Future<void> answer(bool approve) async {
        try {
          await repo.riderAnswer(h.id, approve: approve);
          ref.invalidate(rideHandoversProvider(ride.id));
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
      }

      return Card(
        key: ValueKey('rider-handover-ask-${h.id}'),
        color: t.colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Your driver asks to hand over your trip',
                style: t.textTheme.titleSmall?.copyWith(color: on, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '${_capital(h.whoTakesOver)} would meet you where the car is and take you the rest of the way. '
                'Your fare stays the same.',
                style: t.textTheme.bodyMedium?.copyWith(color: on),
              ),
              if (h.note != null)
                Text(
                  '"${h.note}"',
                  style: t.textTheme.bodySmall?.copyWith(color: on, fontStyle: FontStyle.italic),
                ),
              const SizedBox(height: 4),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  BusyButton.text(
                    key: ValueKey('rider-handover-decline-${h.id}'),
                    onPressed: () => answer(false),
                    child: const Text('Decline'),
                  ),
                  BusyButton.filled(
                    key: ValueKey('rider-handover-approve-${h.id}'),
                    onPressed: () => answer(true),
                    child: const Text('Approve'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final String? line = switch (h?.status) {
      _ when ride.handoverMeeting =>
        '${ride.partnerName ?? 'Your new driver'} is on the way to take you the rest of the way. Stay with the car.',
      TripHandoverStatus.offered => 'Finding a driver to take over. Your driver carries on until then.',
      _ => null,
    };
    if (line == null) return const SizedBox.shrink();
    final on = t.colorScheme.onSecondaryContainer;
    return Card(
      key: const ValueKey('rider-handover-status'),
      color: t.colorScheme.secondaryContainer,
      child: ListTile(
        leading: Icon(Icons.swap_horiz, color: on),
        title: Text(line, style: TextStyle(color: on)),
      ),
    );
  }
}

String _capital(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
