// Scheduled rides for the rider (migration 0189): the "When" row on the
// confirm step, the pickup time picker, the upcoming card on Home and the
// bookings page (Trips → Scheduled).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/scheduled_rides.dart';
import '../../data/scheduled_ride_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import 'confirm_parts.dart' show ConfirmSwitch;

/// "Tue 14 Oct, 18:30".
String pickupLabel(DateTime at) => DateFormat('EEE d MMM, HH:mm').format(at);

/// Asks for a pickup day, then the time; null when closed or out of range
/// (the reason is shown).
Future<DateTime?> pickPickupTime(BuildContext context, ScheduledRidesConfig c, {DateTime? initial}) async {
  final now = DateTime.now();
  final first = earliestPickup(now, c);
  final last = latestPickup(now, c);
  final start = initial != null && pickupTimeProblem(initial, now, c) == null ? initial : first;
  final day = await showDatePicker(
    context: context,
    initialDate: DateTime(start.year, start.month, start.day),
    firstDate: DateTime(first.year, first.month, first.day),
    lastDate: DateTime(last.year, last.month, last.day),
    helpText: 'Pickup day',
  );
  if (day == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(start),
    helpText: 'Pickup time',
  );
  if (time == null || !context.mounted) return null;
  final at = DateTime(day.year, day.month, day.day, time.hour, time.minute);
  final problem = pickupTimeProblem(at, DateTime.now(), c);
  if (problem != null) {
    showInfo(context, problem);
    return null;
  }
  return at;
}

/// The confirm step's "When" row: now, or a pickup time with the
/// scheduling fee and the free-cancellation window.
class ScheduleRow extends StatelessWidget {
  const ScheduleRow({
    super.key,
    required this.at,
    required this.config,
    required this.fare,
    required this.money,
    required this.onChanged,
    this.owed = 0,
  });

  final DateTime? at;
  final ScheduledRidesConfig config;
  final double fare;
  final String Function(double) money;
  final ValueChanged<DateTime?> onChanged;

  /// Late-cancel fees from earlier bookings, added to this ride.
  final double owed;

  Future<void> _pick(BuildContext context) async {
    final picked = await pickPickupTime(context, config, initial: at);
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final when = at;
    final fee = schedulingFee(fare, config);
    final lines = <String>[
      if (when == null) 'Book now, or schedule up to ${config.maxDaysAhead} days ahead',
      if (when != null) pickupLabel(when),
      if (when != null && fee > 0) '+ ${money(fee)} scheduling fee',
      if (when != null && config.lateCancelFee > 0)
        'Free cancellation until ${DateFormat('HH:mm').format(freeCancelUntil(when, config))}',
      if (owed > 0) '+ ${money(owed)} late fee from an earlier booking',
    ];
    return InkWell(
      key: const ValueKey('schedule-row'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => _pick(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, shape: BoxShape.circle),
              child: Icon(Icons.event_outlined, size: 18, color: t.colorScheme.onSurface),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    when == null ? 'Schedule for later' : 'Scheduled pickup',
                    style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    lines.join(' · '),
                    key: const ValueKey('schedule-summary'),
                    style: t.textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (when != null)
              IconButton(
                key: const ValueKey('schedule-edit'),
                tooltip: 'Change pickup time',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.edit_outlined, size: 18, color: t.colorScheme.onSurfaceVariant),
                onPressed: () => _pick(context),
              ),
            ConfirmSwitch(
              key: const ValueKey('schedule-switch'),
              value: when != null,
              onChanged: (v) => v ? _pick(context) : onChanged(null),
            ),
          ],
        ),
      ),
    );
  }
}

/// Home: the soonest booking still to come; opens the bookings page.
class UpcomingRideCard extends ConsumerWidget {
  const UpcomingRideCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final upcoming = ref.watch(upcomingScheduledRidesProvider);
    if (upcoming.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    final next = upcoming.first;
    final more = upcoming.length - 1;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        key: const ValueKey('upcoming-ride-card'),
        margin: EdgeInsets.zero,
        color: t.colorScheme.secondaryContainer,
        child: ListTile(
          leading: Icon(Icons.event_available, color: t.colorScheme.onSecondaryContainer),
          title: Text(
            'Upcoming ride · ${pickupLabel(next.pickupAt)}',
            style: TextStyle(color: t.colorScheme.onSecondaryContainer, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            [scheduledStatusLabel(next), if (more > 0) '+$more more'].join(' · '),
            style: TextStyle(color: t.colorScheme.onSecondaryContainer),
          ),
          trailing: Icon(Icons.chevron_right, color: t.colorScheme.onSecondaryContainer),
          onTap: () => context.push('/trips/scheduled'),
        ),
      ),
    );
  }
}

/// Trips → Scheduled: the rider's bookings, upcoming first.
class ScheduledRidesScreen extends ConsumerWidget {
  const ScheduledRidesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(scheduledRidesConfigProvider).value ?? ScheduledRidesConfig.off;
    return Scaffold(
      appBar: AppBar(title: const Text('Scheduled rides')),
      body: AsyncView(
        value: ref.watch(myScheduledRidesProvider),
        onRetry: () => ref.invalidate(myScheduledRidesProvider),
        data: (all) {
          final upcoming = [
            for (final r in all)
              if (r.upcoming) r,
          ];
          final past = [
            for (final r in all.reversed)
              if (!r.upcoming) r,
          ];
          if (all.isEmpty) {
            return const EmptyState(
              icon: Icons.event_outlined,
              title: 'No scheduled rides',
              message: 'On the booking screen, turn on "Schedule for later" to book a ride ahead.',
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(myScheduledRidesProvider),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (upcoming.isNotEmpty) ...[
                  const _Heading('Upcoming'),
                  for (final r in upcoming) _BookingCard(ride: r, config: config),
                ],
                if (past.isNotEmpty) ...[
                  const _Heading('Past'),
                  for (final r in past.take(30)) _BookingCard(ride: r, config: config),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
  );
}

class _BookingCard extends ConsumerWidget {
  const _BookingCard({required this.ride, required this.config});

  final ScheduledRide ride;
  final ScheduledRidesConfig config;

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final fee = cancelFeeAt(ride.pickupAt, DateTime.now(), config);
    final money = formatMoney(fee, ride.currency ?? 'MYR');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cancel this ride?'),
        content: Text(
          fee > 0
              ? 'It is less than ${config.freeCancelMinutes} minutes to pickup, so a $money late cancellation fee '
                    'applies. It comes out of your GET wallet, or is added to your next ride.'
              : 'You can cancel free of charge.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep ride')),
          FilledButton(
            key: const ValueKey('scheduled-cancel-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: Text(fee > 0 ? 'Cancel and pay $money' : 'Cancel ride'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final r = await ref.read(scheduledRideRepositoryProvider).cancel(ride.id);
      if (context.mounted) {
        showInfo(context, switch (r.cancelFeeStatus) {
          'charged' =>
            'Ride cancelled. ${formatMoney(r.cancelFee, r.currency ?? 'MYR')} was taken from your GET wallet.',
          'due' => 'Ride cancelled. The late fee will be added to your next ride.',
          _ => 'Ride cancelled.',
        });
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
    ref.invalidate(myScheduledRidesProvider);
    ref.invalidate(owedFeesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final currency = ride.currency ?? 'MYR';
    final rideId = ride.rideId;
    return Card(
      key: ValueKey('scheduled-${ride.id}'),
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
            const SizedBox(height: 6),
            Text(scheduledStatusLabel(ride), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.primary)),
            const SizedBox(height: 6),
            _Place(icon: Icons.trip_origin, color: Colors.green.shade600, text: ride.pickupAddress ?? 'Pickup'),
            _Place(icon: Icons.location_on, color: Colors.red.shade600, text: ride.dropAddress ?? 'Destination'),
            if (ride.bookedForName != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'For ${ride.bookedForName} · ${ride.bookedForPhone ?? ''}',
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
            if (ride.schedulingFee > 0)
              Text(
                'Includes ${formatMoney(ride.schedulingFee, currency)} scheduling fee',
                style: t.textTheme.bodySmall?.copyWith(color: muted),
              ),
            if (ride.upcoming) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  if (ride.status == ScheduledStatus.released && rideId != null)
                    FilledButton.tonalIcon(
                      key: ValueKey('scheduled-track-${ride.id}'),
                      icon: const Icon(Icons.near_me_outlined),
                      label: const Text('Track ride'),
                      onPressed: () => context.push('/ride/$rideId'),
                    ),
                  BusyButton.outlined(
                    key: ValueKey('scheduled-cancel-${ride.id}'),
                    onPressed: () => _cancel(context, ref),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Place extends StatelessWidget {
  const _Place({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );
}
