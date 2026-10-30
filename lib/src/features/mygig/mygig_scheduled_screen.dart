// myGiG part B (0330): Scheduled myGiG. The driver's later myGiG rides and
// hire by time (from the calendar button on the home map, with a count, and
// the side menu's row): the date and time, the passenger as the admin lets
// drivers see them, the price, what is paid, "Day 2 of 5", and Start when
// it is due (each day of a hire starts here). The passenger's own myGiG
// bookings in their app's Scheduled rides, until they end.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/mygig.dart' show MygigConfig, mygigMoney;
import '../../core/mygig_hire.dart';
import '../../data/mygig_repository.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';

const mygigScheduledPath = '/drive/mygig/scheduled';

/// Scheduled myGiG (the driver).
class MygigScheduledScreen extends ConsumerWidget {
  const MygigScheduledScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mygigScheduledProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Scheduled myGiG')),
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(mygigScheduledProvider),
        data: (list) => list.isEmpty
            ? ListView(children: const [
                EmptyState(
                  key: ValueKey('mygig-scheduled-empty'),
                  icon: Icons.event_outlined,
                  title: 'No myGiG bookings yet',
                  message: 'On the trip details, choose Later, or hire by time, to book a passenger ahead.',
                ),
              ])
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(mygigScheduledProvider),
                child: ResponsiveCenter(
                  maxWidth: 760,
                  child: ListView(
                    key: const ValueKey('mygig-scheduled'),
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final b in list) MygigScheduledCard(booking: b, now: DateTime.now()),
                      const SizedBox(height: 4),
                      Text(
                        'Later rides and hire by time you booked with myGiG. Each day of a daily, weekly or monthly hire '
                        'starts here.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

/// A booking on Scheduled myGiG, with Start (when due), taking what is due
/// in cash or by link, and Cancel.
class MygigScheduledCard extends ConsumerWidget {
  const MygigScheduledCard({super.key, required this.booking, required this.now});
  final MygigBooking booking;
  final DateTime now;

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (context.mounted) showError(context, e);
    } finally {
      ref.invalidate(mygigScheduledProvider);
    }
  }

  Future<void> _start(BuildContext context, WidgetRef ref) => _run(context, ref, () async {
    final ride = booking.rideId ?? await ref.read(mygigRepositoryProvider).startBooking(booking.id);
    if (ride != null && context.mounted) context.go('/drive/trip/$ride');
  });

  Future<void> _cash(BuildContext context, WidgetRef ref) async {
    final ok = await showAppDialog<bool>(
      id: 'mygig.booking-cash',
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Received ${mygigMoney(booking.due)} in cash?'),
        content: const Text('Confirm only once the passenger has paid you. It is recorded on the booking.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not yet')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Received')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await _run(context, ref, () => ref.read(mygigRepositoryProvider).bookingCash(booking.id));
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final ok = await showAppDialog<bool>(
      id: 'mygig.booking-cancel',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cancel this booking?'),
        content: const Text('The passenger is told, and everything they paid is refunded.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep booking')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cancel booking')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await _run(context, ref, () async {
      await ref.read(mygigRepositoryProvider).cancelBooking(booking: booking.id);
      if (context.mounted) {
        await showAppNotice(
          id: 'notice.mygig',
          context: context,
          title: 'Booking cancelled',
          message: 'The passenger was told. What they paid is refunded.',
        );
      }
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final b = booking;
    final tag = b.kind == MygigKind.trip ? 'Ride' : b.dayText ?? (b.kind == MygigKind.hourly ? 'Hourly' : b.title);
    final next = b.nextAt;
    final startLabel = b.rideId != null
        ? 'Open today’s trip'
        : b.days > 1 && b.nextDay['day'] != null
        ? 'Start day ${b.nextDay['day']}'
        : 'Start';
    return Card(
      key: ValueKey('mygig-booking-${b.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(next == null ? b.whenText(now) : mygigWhenText(next, now),
                  style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            Chip(label: Text(tag), visualDensity: VisualDensity.compact),
          ]),
          Text(b.whatText),
          Text('${b.name} · from ${b.pickupName} · ${mygigMoney(b.price)}', style: t.textTheme.bodySmall),
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.payments_outlined, size: 16, color: t.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Expanded(child: Text(b.payText, key: const ValueKey('mygig-booking-pay'), style: t.textTheme.bodySmall)),
          ]),
          if (b.kind != MygigKind.trip || b.awaitingPayment) Text(b.cancelText(now), style: t.textTheme.bodySmall),
          if (b.awaitingPayment)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Not confirmed until the passenger pays. It ends if they don’t pay in time.',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
            ),
          const SizedBox(height: 4),
          Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            BusyButton.tonal(
              key: const ValueKey('mygig-booking-start'),
              icon: const Icon(Icons.play_arrow),
              onPressed: b.rideId != null || b.canStart ? () => _start(context, ref) : null,
              child: Text(startLabel),
            ),
            if (b.linkOwed > 0)
              BusyButton.text(
                key: const ValueKey('mygig-booking-link'),
                icon: const Icon(Icons.link),
                onPressed: () => _run(context, ref, () => ref.read(mygigRepositoryProvider).sendPayLink(b.id)),
                child: Text(b.payUrl == null ? 'Send pay link' : 'Send it again'),
              ),
            if (!b.awaitingPayment && b.due > 0 && b.plan != 'business')
              BusyButton.text(
                key: const ValueKey('mygig-booking-cash'),
                icon: const Icon(Icons.payments_outlined),
                onPressed: () => _cash(context, ref),
                child: Text('Received ${mygigMoney(b.due)} in cash'),
              ),
            if (b.canCancel)
              BusyButton.text(
                key: const ValueKey('mygig-booking-cancel'),
                icon: const Icon(Icons.close),
                onPressed: () => _cancel(context, ref),
                child: const Text('Cancel'),
              ),
          ]),
          if (!b.canStart && b.rideId == null && b.startFrom != null && !b.awaitingPayment)
            Text('Start from ${mygigWhenText(b.startFrom!, now)}', style: t.textTheme.bodySmall),
        ]),
      ),
    );
  }
}

/// The calendar button on the driver's home map, with how many bookings
/// are in Scheduled myGiG.
class MygigScheduledButton extends StatelessWidget {
  const MygigScheduledButton({super.key, required this.config});
  final MygigConfig? config;

  @override
  Widget build(BuildContext context) {
    final n = config?.scheduledCount ?? 0;
    return IconButton.filledTonal(
      key: const ValueKey('partner-mygig-scheduled'),
      tooltip: n == 0 ? 'Scheduled myGiG' : 'Scheduled myGiG: $n',
      onPressed: () => context.push(mygigScheduledPath),
      icon: Badge(isLabelVisible: n > 0, label: Text('$n'), child: const Icon(Icons.event)),
    );
  }
}

/// A myGiG booking in the passenger's app, until it ends.
class MygigPassengerBookingCard extends ConsumerWidget {
  const MygigPassengerBookingCard({super.key, required this.booking});
  final MygigBooking booking;

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final b = booking;
    final keep = b.cancelFree ? 0.0 : b.keepIfCancelled;
    final ok = await showAppDialog<bool>(
      id: 'mygig.my-booking-cancel',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cancel this booking?'),
        content: Text(keep > 0
            ? '${mygigMoney(keep)} you paid is kept for the driver; the rest is refunded.'
            : 'It is free to cancel now. What you paid is refunded.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep booking')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cancel booking')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(mygigRepositoryProvider).cancelBooking(booking: b.id);
    } catch (e) {
      if (context.mounted) showError(context, e);
    } finally {
      ref.invalidate(mygigMyBookingsProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final b = booking;
    final now = DateTime.now();
    final d = b.driver;
    return Card(
      key: ValueKey('mygig-my-booking-${b.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(b.whenText(now), style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
            Chip(label: Text(b.statusText), visualDensity: VisualDensity.compact),
          ]),
          Text(b.whatText),
          Text(
            [
              '${d['name'] ?? 'Your driver'}',
              if (d['vehicle'] != null) '${d['vehicle']}',
              if (d['plate'] != null) '${d['plate']}',
              mygigMoney(b.price),
            ].join(' · '),
            style: t.textTheme.bodySmall,
          ),
          if (b.dayText != null) Text(b.dayText!, style: t.textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(b.payText, style: t.textTheme.bodySmall),
          if (b.open) Text(b.cancelText(now), style: t.textTheme.bodySmall),
          Wrap(spacing: 4, children: [
            if (b.rideId != null)
              TextButton.icon(
                key: const ValueKey('mygig-my-booking-follow'),
                icon: const Icon(Icons.map_outlined),
                onPressed: () => context.go('/ride/${b.rideId}'),
                label: const Text('Follow the ride'),
              ),
            if (b.linkOwed > 0 && b.payUrl != null)
              TextButton.icon(
                key: const ValueKey('mygig-my-booking-pay'),
                icon: const Icon(Icons.payments_outlined),
                onPressed: () => launchUrl(Uri.parse(b.payUrl!), mode: LaunchMode.externalApplication),
                label: Text('Pay ${mygigMoney(b.linkOwed)}'),
              ),
            if (b.canCancel)
              TextButton.icon(
                key: const ValueKey('mygig-my-booking-cancel'),
                style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
                icon: const Icon(Icons.cancel_outlined),
                onPressed: () => _cancel(context, ref),
                label: const Text('Cancel booking'),
              ),
          ]),
        ]),
      ),
    );
  }
}

/// A myGiG hire on the driver's trip screen: the time and km used today,
/// overtime once the hours are up (paid before the day ends).
class MygigHireCard extends StatefulWidget {
  const MygigHireCard({super.key, required this.row, this.now});
  final Map<String, dynamic> row;

  /// The clock (tests).
  final DateTime Function()? now;

  @override
  State<MygigHireCard> createState() => _MygigHireCardState();
}

class _MygigHireCardState extends State<MygigHireCard> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = widget.row;
    final g = r['mygig'] is Map ? Map<String, dynamic>.from(r['mygig'] as Map) : const <String, dynamic>{};
    double n(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
    final hours = n(r['hire_hours']);
    final now = widget.now?.call() ?? DateTime.now();
    final started = DateTime.tryParse('${r['hire_started_at'] ?? ''}')?.toLocal();
    final h = mygigHireNow(
      startedAt: started,
      hours: hours,
      stepMin: (r['hire_step_min'] as num?)?.toInt() ?? 30,
      overtimeRate: n(r['hire_overtime_rate']),
      now: now,
    );
    final days = (g['days'] as num?)?.toInt() ?? 1;
    final title = '${mygigKindFrom(r['hire_package']).label}${days > 1 ? ' · day ${g['dayNo']} of $days' : ''}';
    final over = h.overtimeMin > 0;
    return Card(
      key: const ValueKey('mygig-hire-card'),
      color: over ? t.colorScheme.tertiaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          if (started == null)
            const Text('The clock starts when you start the trip.')
          else ...[
            Text('Time used today: ${h.used} of ${hours.toStringAsFixed(hours == hours.roundToDouble() ? 0 : 1)} h',
                key: const ValueKey('mygig-hire-used')),
            if (over)
              Text('Overtime ${h.overtimeMin} min · ${mygigMoney(h.overtime)} so far, paid before the day ends',
                  key: const ValueKey('mygig-hire-overtime'), style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ],
          Text('${n(r['hire_km_included']).round()} km included today, then ${mygigMoney(n(r['hire_extra_km_rate']))} a km'),
          Text('Overtime ${mygigMoney(n(r['hire_overtime_rate']))} an hour', style: t.textTheme.bodySmall),
        ]),
      ),
    );
  }
}

/// The trip screen's main button on a hire: "End day 2 of 5" on a booked
/// day of several, else "End hire".
String mygigEndHireLabel(Map<String, dynamic> row) {
  final g = row['mygig'];
  if (g is Map && g['days'] is num && (g['days'] as num) > 1 && (g['dayNo'] as num? ?? 0) < (g['days'] as num)) {
    return 'End day ${g['dayNo']} of ${g['days']}';
  }
  return 'End hire';
}
