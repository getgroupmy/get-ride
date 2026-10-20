// The driver's place at an airport (migration 0249), under the Drive switch:
// dropped off ("Go to the waiting zone within N min to join the Comfort
// queue"), in the queue ("#2 of 5"), an airport order, refused ("Only
// drivers who dropped off at KUL can wait for airport orders") or around
// the airport outside a waiting zone. Nothing outside an airport.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/airport_queue.dart';
import '../../data/airport_repository.dart';

/// How often the card asks again (the position is reported every minute).
const airportStatePoll = Duration(seconds: 30);

/// The server's view of this driver at an airport, asked every
/// [airportStatePoll]; outside when it can't be read.
final driverAirportStateProvider =
    StreamProvider.autoDispose<DriverAirportState>((ref) async* {
      final repo = ref.watch(airportRepositoryProvider);
      while (true) {
        try {
          yield await repo.driverState();
        } catch (_) {
          yield DriverAirportState.outsideState;
        }
        await Future<void>.delayed(airportStatePoll);
      }
    });

class AirportQueueCard extends ConsumerWidget {
  const AirportQueueCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s =
        ref.watch(driverAirportStateProvider).value ??
        DriverAirportState.outsideState;
    if (!s.showCard) return const SizedBox.shrink();
    return AirportQueueView(state: s);
  }
}

/// The card for [state] (no data access, for tests and previews).
class AirportQueueView extends StatelessWidget {
  const AirportQueueView({super.key, required this.state});
  final DriverAirportState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final s = state;
    final (Color fg, IconData icon) = switch (s.stage) {
      DriverAirportStage.queued ||
      DriverAirportStage.offer => (scheme.primary, Icons.flight_land),
      DriverAirportStage.refused => (scheme.error, Icons.block),
      _ => (scheme.tertiary, Icons.flight),
    };
    return Card(
      key: ValueKey('airport-queue-${s.stage.name}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: fg),
                  const SizedBox(width: 6),
                  Text(
                    s.title,
                    style: t.textTheme.labelMedium?.copyWith(color: fg),
                  ),
                ],
              ),
            ),
            if (s.stage == DriverAirportStage.queued &&
                s.position != null &&
                !s.outside)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  '#${s.position}',
                  key: const ValueKey('airport-queue-position'),
                  style: t.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Text(
              s.message,
              key: const ValueKey('airport-queue-message'),
              style: s.stage == DriverAirportStage.queued && !s.outside
                  ? t.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    )
                  : t.textTheme.bodyMedium,
            ),
            if (s.zones.isNotEmpty &&
                (s.stage == DriverAirportStage.dropped ||
                    s.stage == DriverAirportStage.around))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  s.zones.join(' · '),
                  style: t.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Tells the server the driver passed on an airport offer, so it goes to the
/// next driver straight away (and, as the airport says, this one to the back
/// of the queue). Best effort.
Future<void> declineAirportOffer(WidgetRef ref, String rideId) async {
  try {
    await ref.read(airportRepositoryProvider).declineOffer(rideId);
  } catch (_) {}
  ref.invalidate(driverAirportStateProvider);
}
