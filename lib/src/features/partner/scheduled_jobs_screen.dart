// Scheduled rides for drivers (migration 0189): the rides the driver has
// taken ahead of time and, when the admin uses advance booking, the ones
// open to take. A ride the driver lets go of goes back to the pool, and
// the passenger is told the platform is finding another driver.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/scheduled_rides.dart';
import '../../data/scheduled_ride_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../ride/scheduled_rides_screen.dart' show pickupLabel;

class ScheduledJobsScreen extends ConsumerWidget {
  const ScheduledJobsScreen({super.key});

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(acceptedScheduledRidesProvider);
    ref.invalidate(openScheduledRidesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(scheduledRidesConfigProvider).value ?? ScheduledRidesConfig.off;
    final mine = ref.watch(acceptedScheduledRidesProvider);
    final open = ref.watch(openScheduledRidesProvider);
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Scheduled rides')),
      body: RefreshIndicator(
        onRefresh: () => _refresh(ref),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Your scheduled rides', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            AsyncView(
              value: mine,
              onRetry: () => ref.invalidate(acceptedScheduledRidesProvider),
              data: (rides) => rides.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        config.advance
                            ? 'None yet. Take one from the list below.'
                            : 'Scheduled rides come to you as ordinary requests when they are released, '
                                  '${config.releaseMinutes} minutes before pickup.',
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                    )
                  : Column(children: [for (final r in rides) _JobCard(ride: r, mine: true)]),
            ),
            if (config.advance) ...[
              const SizedBox(height: 16),
              Text('Available to book', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(
                'Take a ride ahead of time. It is sent to you ${config.releaseMinutes} minutes before pickup.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              AsyncView(
                value: open,
                onRetry: () => ref.invalidate(openScheduledRidesProvider),
                data: (rides) => rides.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: EmptyState(icon: Icons.event_busy_outlined, title: 'No rides to book right now'),
                      )
                    : Column(children: [for (final r in rides) _JobCard(ride: r, mine: false)]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Drive: the soonest scheduled ride this driver has taken and is still to
/// be sent to them, with how many more; opens Scheduled rides. Nothing
/// while scheduled rides are off or none is taken.
class PartnerUpcomingBookingCard extends ConsumerWidget {
  const PartnerUpcomingBookingCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!(ref.watch(scheduledRidesConfigProvider).value?.enabled ?? false)) return const SizedBox.shrink();
    final taken = [
      for (final r in ref.watch(acceptedScheduledRidesProvider).value ?? const <ScheduledRide>[])
        if (r.status == ScheduledStatus.assigned) r,
    ];
    if (taken.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    final next = taken.first;
    final more = taken.length - 1;
    final on = t.colorScheme.onSecondaryContainer;
    return Card(
      key: const ValueKey('partner-upcoming-booking'),
      color: t.colorScheme.secondaryContainer,
      child: ListTile(
        leading: Icon(Icons.event_available, color: on),
        title: Text(
          'Scheduled ride · ${pickupLabel(next.pickupAt)}',
          style: TextStyle(color: on, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [next.pickupAddress ?? 'Pickup', if (more > 0) '+$more more'].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: on),
        ),
        trailing: Icon(Icons.chevron_right, color: on),
        onTap: () => context.push('/drive/scheduled'),
      ),
    );
  }
}

class _JobCard extends ConsumerWidget {
  const _JobCard({required this.ride, required this.mine});

  final ScheduledRide ride;

  /// One the driver has taken (else one open to take).
  final bool mine;

  Future<void> _accept(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(scheduledRideRepositoryProvider).accept(ride.id);
      if (context.mounted) showInfo(context, 'Ride booked for ${pickupLabel(ride.pickupAt)}. The passenger is told.');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
    ref.invalidate(acceptedScheduledRidesProvider);
    ref.invalidate(openScheduledRidesProvider);
  }

  Future<void> _letGo(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("Can't make it?"),
        content: const Text(
          'The ride goes back to other drivers and the passenger is told we are finding them another driver.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep ride')),
          FilledButton(
            key: const ValueKey('scheduled-job-release-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Give up ride'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(scheduledRideRepositoryProvider).release(ride.id);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
    ref.invalidate(acceptedScheduledRidesProvider);
    ref.invalidate(openScheduledRidesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final currency = ride.currency ?? 'MYR';
    final rideId = ride.rideId;
    final km = ride.distanceKm;
    return Card(
      key: ValueKey('scheduled-job-${ride.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.event, size: 18, color: t.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    pickupLabel(ride.pickupAt),
                    style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(formatMoney(ride.total, currency), style: t.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [ride.service ?? 'Ride', if (km != null) formatDistance(km)].join(' · '),
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 4),
            Text('From ${ride.pickupAddress ?? 'pickup'}', maxLines: 2, overflow: TextOverflow.ellipsis),
            Text(
              'To ${ride.dropAddress ?? 'destination'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (!mine)
                  BusyButton.filled(
                    key: ValueKey('scheduled-job-accept-${ride.id}'),
                    onPressed: () => _accept(context, ref),
                    child: const Text('Book this ride'),
                  ),
                if (mine && ride.status == ScheduledStatus.released && rideId != null)
                  FilledButton.icon(
                    key: ValueKey('scheduled-job-open-${ride.id}'),
                    icon: const Icon(Icons.navigation_outlined),
                    label: const Text('Open trip'),
                    onPressed: () => context.push('/drive/trip/$rideId'),
                  ),
                if (mine && ride.status == ScheduledStatus.assigned)
                  BusyButton.outlined(
                    key: ValueKey('scheduled-job-release-${ride.id}'),
                    onPressed: () => _letGo(context, ref),
                    child: const Text("Can't make it"),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
