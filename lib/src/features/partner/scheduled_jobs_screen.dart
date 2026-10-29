// Scheduled rides for drivers (migrations 0189, 0198), in two tabs:
//
//   Upcoming   every booking no driver has taken yet, from now on, by day.
//              With advance booking the driver books one; without, they mark
//              it "interested" and are told when they can accept it (the
//              first to accept gets it).
//   My rides   requests sent to them (a driver handing a ride over, a
//              passenger choosing them) to accept or decline, and the rides
//              they hold: hand one to another driver by code, or let it go
//              back to the pool.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/place_fees.dart' show PlaceFeeGoesTo;
import '../../core/scheduled_rides.dart';
import '../../data/scheduled_ride_repository.dart';
import '../../widgets/offer_motion.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../ride/driver_code_sheet.dart';
import '../ride/scheduled_rides_screen.dart' show pickupLabel;
import '../../widgets/back_or_go_button.dart';
import '../../widgets/page_style_host.dart';

class ScheduledJobsScreen extends ConsumerWidget {
  const ScheduledJobsScreen({super.key, this.initialTab = 0});

  /// 0: Upcoming, 1: My rides.
  final int initialTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming = [
      for (final o in ref.watch(scheduledOffersProvider).value ?? const <ScheduledOffer>[])
        if (o.incoming) o,
    ];
    return DefaultTabController(
      length: 2,
      initialIndex: initialTab.clamp(0, 1),
      child: Scaffold(
        appBar: AppBar(
          leading: const BackOrGoButton(fallback: '/drive'),
          title: const Text('Scheduled rides'),
          bottom: TabBar(
            tabs: [
              const Tab(key: ValueKey('scheduled-tab-upcoming'), text: 'Upcoming'),
              Tab(
                key: const ValueKey('scheduled-tab-mine'),
                child: Badge(
                  isLabelVisible: incoming.isNotEmpty,
                  label: Text('${incoming.length}'),
                  child: const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('My rides')),
                ),
              ),
            ],
          ),
        ),
        body: const TabBarView(children: [_UpcomingTab(), _MineTab()]),
      ),
    );
  }
}

void _refresh(WidgetRef ref) {
  ref.invalidate(upcomingBookingsProvider);
  ref.invalidate(acceptedScheduledRidesProvider);
  ref.invalidate(scheduledOffersProvider);
}

Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() action, {String? done}) async {
  try {
    await action();
    if (done != null && context.mounted) showInfo(context, done);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
  _refresh(ref);
}

// ---- Upcoming -------------------------------------------------------------------------------

class _UpcomingTab extends ConsumerWidget {
  const _UpcomingTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final config = ref.watch(scheduledRidesConfigProvider).value ?? ScheduledRidesConfig.off;
    final now = DateTime.now();
    return RefreshIndicator(
      onRefresh: () async => _refresh(ref),
      child: AsyncView(
        value: ref.watch(upcomingBookingsProvider),
        onRetry: () => ref.invalidate(upcomingBookingsProvider),
        data: (all) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Every booking still without a driver, from now (${DateFormat('EEE d MMM, h:mm a').format(now)}).',
              key: const ValueKey('scheduled-upcoming-now'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              config.advance
                  ? 'Book one to make it yours. It is sent to you ${config.releaseMinutes} minutes before pickup.'
                  : config.interestNoticeMinutes > 0
                  ? "Mark the ones you'd like. ${_noticeLabel(config.interestNoticeMinutes)} before pickup you're "
                        'told you can accept them: the first driver to accept gets it.'
                  : 'Each one comes to drivers nearby as a request ${config.releaseMinutes} minutes before pickup.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            if (all.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: EmptyState(
                  key: ValueKey('scheduled-upcoming-empty'),
                  icon: Icons.event_busy_outlined,
                  title: 'No bookings waiting for a driver',
                ),
              )
            else
              for (final (day, items) in groupByBookingDay(all, (b) => b.ride.pickupAt, now)) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                  child: Text(day, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                ),
                for (final b in items) _UpcomingCard(booking: b, config: config),
              ],
          ],
        ),
      ),
    );
  }
}

String _noticeLabel(int minutes) =>
    minutes % 60 == 0 ? '${minutes ~/ 60} ${minutes == 60 ? 'hour' : 'hours'}' : '$minutes minutes';

class _UpcomingCard extends ConsumerWidget {
  const _UpcomingCard({required this.booking, required this.config});

  final UpcomingBooking booking;
  final ScheduledRidesConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ride = booking.ride;
    final repo = ref.read(scheduledRideRepositoryProvider);
    final from = booking.acceptFrom;
    final note = config.advance || booking.canAccept
        ? null
        : !booking.interested
        ? null
        : from != null
        ? "We'll tell you at ${pickupLabel(from)} when you can accept it."
        : "You'll get it as a request when it is released.";
    return _BookingCard(
      cardKey: ValueKey('scheduled-upcoming-${ride.id}'),
      ride: ride,
      note: note,
      highlight: booking.canAccept && !config.advance,
      actions: [
        if (booking.canAccept)
          BusyButton.filled(
            key: ValueKey('scheduled-job-accept-${ride.id}'),
            onPressed: () => _run(
              context,
              ref,
              () => repo.accept(ride.id),
              done: 'Ride booked for ${pickupLabel(ride.pickupAt)}. The passenger is told.',
            ),
            child: Text(config.advance ? 'Book this ride' : 'Accept'),
          ),
        if (!config.advance)
          booking.interested
              ? BusyButton.tonal(
                  key: ValueKey('scheduled-interest-off-${ride.id}'),
                  onPressed: () => _run(context, ref, () => repo.setInterest(ride.id, false)),
                  icon: const Icon(Icons.star),
                  child: const Text('Interested'),
                )
              : BusyButton.outlined(
                  key: ValueKey('scheduled-interest-on-${ride.id}'),
                  onPressed: () => _run(
                    context,
                    ref,
                    () => repo.setInterest(ride.id, true),
                    done: config.interestNoticeMinutes > 0
                        ? "Marked. We'll tell you when you can accept it."
                        : 'Marked.',
                  ),
                  icon: const Icon(Icons.star_border),
                  child: const Text("I'm interested"),
                ),
      ],
    );
  }
}

// ---- My rides -------------------------------------------------------------------------------

class _MineTab extends ConsumerWidget {
  const _MineTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final config = ref.watch(scheduledRidesConfigProvider).value ?? ScheduledRidesConfig.off;
    final offers = ref.watch(scheduledOffersProvider).value ?? const <ScheduledOffer>[];
    final incoming = [
      for (final o in offers)
        if (o.incoming) o,
    ];
    return RefreshIndicator(
      onRefresh: () async => _refresh(ref),
      child: AsyncView(
        value: ref.watch(acceptedScheduledRidesProvider),
        onRetry: () => ref.invalidate(acceptedScheduledRidesProvider),
        data: (rides) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (incoming.isNotEmpty) ...[
              Text('Requests for you', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
            ],
            // Kept mounted while empty, so the last offer still slides out.
            OfferMotionList(children: [for (final o in incoming) _OfferCard(key: ValueKey('scheduled-offer-motion-${o.id}'), offer: o)]),
            if (incoming.isNotEmpty) const SizedBox(height: 8),
            if (rides.isEmpty && incoming.isEmpty)
              EmptyState(
                key: const ValueKey('scheduled-jobs-empty'),
                icon: Icons.event_outlined,
                title: 'No scheduled rides yet',
                message: config.advance
                    ? 'Book one on Upcoming. It is sent to you ${config.releaseMinutes} minutes before pickup.'
                    : "Mark bookings on Upcoming that you'd like, and accept one when you're told. "
                          'Other drivers and passengers can also send you a ride here.',
              )
            else if (rides.isNotEmpty) ...[
              Text('Your scheduled rides', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              for (final r in rides)
                _JobCard(
                  ride: r,
                  handover: offers
                      .where((o) => !o.incoming && o.kind == ScheduledOfferKind.transfer && o.ride.id == r.id)
                      .firstOrNull,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OfferCard extends ConsumerWidget {
  const _OfferCard({super.key, required this.offer});

  final ScheduledOffer offer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(scheduledRideRepositoryProvider);
    return _BookingCard(
      cardKey: ValueKey('scheduled-offer-${offer.id}'),
      ride: offer.ride,
      heading: offer.incomingTitle,
      note: 'Answer by ${pickupLabel(offer.expiresAt)}.',
      highlight: true,
      actions: [
        BusyButton.filled(
          key: ValueKey('scheduled-offer-accept-${offer.id}'),
          onPressed: () => _run(
            context,
            ref,
            () => repo.answerOffer(offer.id, accept: true),
            done: 'Ride booked for ${pickupLabel(offer.ride.pickupAt)}. The passenger is told.',
          ),
          child: const Text('Accept'),
        ),
        BusyButton.outlined(
          key: ValueKey('scheduled-offer-decline-${offer.id}'),
          onPressed: () => _run(context, ref, () => repo.answerOffer(offer.id, accept: false), done: 'Declined.'),
          child: const Text('Decline'),
        ),
      ],
    );
  }
}

class _JobCard extends ConsumerWidget {
  const _JobCard({required this.ride, this.handover});

  final ScheduledRide ride;

  /// This driver's handover of it, waiting for the other driver.
  final ScheduledOffer? handover;

  Future<void> _handOver(BuildContext context, WidgetRef ref) async {
    final code = await askDriverCode(
      context,
      title: 'Hand over this ride',
      message:
          "Enter the other driver's My Ride code or scan their GET.me QR. The ride stays yours until they "
          'accept it; the passenger is told when they do.',
      action: 'Send',
    );
    if (code == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref.read(scheduledRideRepositoryProvider).handOver(ride.id, code),
      done: 'Sent. The ride is yours until they accept it.',
    );
  }

  Future<void> _letGo(BuildContext context, WidgetRef ref) async {
    final ok = await showAppDialog<bool>(id: 'scheduled-jobs.let-go',
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
    await _run(context, ref, () => ref.read(scheduledRideRepositoryProvider).release(ride.id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rideId = ride.rideId;
    final waiting = handover;
    return _BookingCard(
      cardKey: ValueKey('scheduled-job-${ride.id}'),
      ride: ride,
      note: waiting?.waitingLabel,
      actions: [
        if (ride.status == ScheduledStatus.released && rideId != null)
          FilledButton.icon(
            key: ValueKey('scheduled-job-open-${ride.id}'),
            icon: const Icon(Icons.navigation_outlined),
            label: const Text('Open trip'),
            onPressed: () => context.push('/drive/trip/$rideId'),
          ),
        if (ride.status == ScheduledStatus.assigned) ...[
          if (waiting != null)
            BusyButton.outlined(
              key: ValueKey('scheduled-job-withdraw-${ride.id}'),
              onPressed: () => _run(
                context,
                ref,
                () => ref.read(scheduledRideRepositoryProvider).withdrawOffer(waiting.id),
                done: 'Handover withdrawn.',
              ),
              child: const Text('Withdraw handover'),
            )
          else
            // Not a busy button: it would spin while the code sheet is open.
            OutlinedButton.icon(
              key: ValueKey('scheduled-job-handover-${ride.id}'),
              onPressed: () => _handOver(context, ref),
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Hand over'),
            ),
          BusyButton.outlined(
            key: ValueKey('scheduled-job-release-${ride.id}'),
            onPressed: () => _letGo(context, ref),
            child: const Text("Can't make it"),
          ),
        ],
      ],
    );
  }
}

/// A booking: when, how much, how far, from and to, then its buttons.
class _BookingCard extends StatelessWidget {
  const _BookingCard({
    required this.cardKey,
    required this.ride,
    required this.actions,
    this.heading,
    this.note,
    this.highlight = false,
  });

  final Key cardKey;
  final ScheduledRide ride;
  final List<Widget> actions;
  final String? heading;
  final String? note;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final km = ride.distanceKm;
    return Card(
      key: cardKey,
      margin: const EdgeInsets.only(bottom: 10),
      shape: highlight
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: t.colorScheme.primary, width: 1.5),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (heading != null) ...[
              Text(heading!, style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary)),
              const SizedBox(height: 6),
            ],
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
                Text(
                  formatMoney(ride.total, ride.currency ?? 'MYR'),
                  key: ValueKey('scheduled-total-${ride.id}'),
                  style: t.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [ride.service ?? 'Ride', if (km != null) formatDistance(km)].join(' · '),
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            // The place fees the booking locked (0325), in its total; one
            // that is passed on says so, as on the offer card.
            if (ride.placeFees.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                [
                  for (final l in ride.placeFees)
                    '+ ${l.label} ${formatMoney(l.amount, ride.currency ?? 'MYR')}'
                        '${l.goesTo == PlaceFeeGoesTo.pass ? ' (passed on)' : ''}',
                ].join(' · '),
                key: ValueKey('scheduled-place-fees-${ride.id}'),
                style: t.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
            const SizedBox(height: 4),
            Text('From ${ride.pickupAddress ?? 'pickup'}', maxLines: 2, overflow: TextOverflow.ellipsis),
            Text(
              'To ${ride.dropAddress ?? 'destination'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            if (note != null) ...[
              const SizedBox(height: 6),
              Text(note!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.primary)),
            ],
            if (actions.isNotEmpty) ...[const SizedBox(height: 8), Wrap(spacing: 8, runSpacing: 8, children: actions)],
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
        // The count in the title: a long address is cut short and would hide it.
        title: Text(
          ['Scheduled ride', pickupLabel(next.pickupAt), if (more > 0) '+$more more'].join(' · '),
          style: TextStyle(color: on, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          next.pickupAddress ?? 'Pickup',
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
