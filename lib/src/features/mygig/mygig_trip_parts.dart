// myGiG on the driver's trip screen (migration 0329): how the passenger
// follows the ride, "Passenger didn't come" after the free minutes (a fee
// only for a registered passenger paying in the app), waiting at a stop,
// "Change destination" and "Add stop" (back to the passenger to accept),
// and after the trip the per-trip myGiG fee, pay by link, Family and
// business paid on their own, and "Block this number". 0331: "Reassign to
// another driver" before pickup and "Hand over" during the trip.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/mygig.dart';
import '../../core/ride_payment.dart' show RidePaymentStatus;
import '../../data/geo_service.dart';
import '../../data/models.dart';
import '../../data/mygig_repository.dart';
import '../../providers.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../ride/place_search.dart';
import 'mygig_new_screen.dart' show openMygigWhatsApp;
import 'mygig_reassign.dart' show MygigReassignButton;
import 'mygig_waiting_screen.dart';

/// Whether [r] is a myGiG ride.
bool isMygigRide(RideRequest r) => r.raw['mygig'] is Map;

/// The minutes since [from] (whole, never below 0).
int mygigMinutesSince(DateTime? from, DateTime now) => from == null ? 0 : now.difference(from).inMinutes.clamp(0, 100000);

/// "Passenger didn't come" may be pressed: arrived, the free minutes over.
bool mygigNoShowReady(RideRequest r, MygigRide g, DateTime now) =>
    r.status == RideStatus.arrived && r.arrivedAt != null && mygigMinutesSince(r.arrivedAt, now) >= g.waitFreeMin;

class MygigTripCard extends ConsumerStatefulWidget {
  const MygigTripCard({super.key, required this.ride, this.onEnded});
  final RideRequest ride;

  /// The ride ended here (no-show): the screen goes home.
  final VoidCallback? onEnded;

  @override
  ConsumerState<MygigTripCard> createState() => _MygigTripCardState();
}

class _MygigTripCardState extends ConsumerState<MygigTripCard> {
  Timer? _tick;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _noShow(MygigRide g) async {
    final r = widget.ride;
    final waited = mygigMinutesSince(r.arrivedAt, _now);
    final fee = g.canCharge ? g.noShowFee : 0.0;
    final ok = await showAppDialog<bool>(
      id: 'mygig.no-show',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Passenger didn’t come?'),
        content: Text('You waited $waited min. ${fee > 0
            ? 'The no-show fee of ${mygigMoney(fee)} is charged to ${mygigPayName(g.pay)}.'
            : 'The ride ends with no fee: ${g.registered ? 'they pay by ${g.pay == MygigPay.cash ? 'cash' : 'link'}' : 'they aren’t registered'}, so nothing can be charged after the fact.'}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep waiting')),
          FilledButton(key: const ValueKey('mygig-no-show-ok'), onPressed: () => Navigator.pop(c, true), child: const Text('End ride')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final charged = await ref.read(mygigRepositoryProvider).noShow(r.id);
      if (!mounted) return;
      await showAppNotice(
        id: 'notice.mygig',
        context: context,
        title: 'Ride ended: no-show',
        message: charged > 0 ? '${mygigMoney(charged)} no-show fee charged. It goes to your GET.wallet.'
            : 'Nothing was charged. You’re online for the next request.',
      );
      widget.onEnded?.call();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _stopWait(bool on) async {
    try {
      await ref.read(mygigRepositoryProvider).stopWait(widget.ride.id, on: on);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Change destination ([addStop] false) or add a stop before it: priced
  /// again by the server and sent to the passenger the same way.
  Future<void> _change({required bool addStop}) async {
    final r = widget.ride;
    final pick = await showPlaceSearch(context, title: addStop ? 'Add a stop' : 'Change destination',
        near: r.dropLat == null ? null : LatLng(r.dropLat!, r.dropLng!));
    final p = pick?.place;
    if (p == null || !mounted) return;
    final stops = [
      for (final s in r.stops)
        {'lat': s.point.latitude, 'lng': s.point.longitude, 'name': s.name},
      if (addStop) {'lat': p.point.latitude, 'lng': p.point.longitude, 'name': p.name},
    ];
    final drop = addStop
        ? {'lat': r.dropLat, 'lng': r.dropLng, 'name': r.dropLabel}
        : {'lat': p.point.latitude, 'lng': p.point.longitude, 'name': p.name, 'address': p.address};
    double? km, min;
    try {
      final from = LatLng(r.pickupLat!, r.pickupLng!);
      final to = LatLng((drop['lat'] as num).toDouble(), (drop['lng'] as num).toDouble());
      final RouteInfo route = await ref.read(geoServiceProvider).route(from, to,
          via: [for (final s in stops) LatLng((s['lat'] as num).toDouble(), (s['lng'] as num).toDouble())]);
      km = route.distanceKm;
      min = route.durationMin;
    } catch (_) {}
    if (!mounted) return;
    try {
      final sent = await ref.read(mygigRepositoryProvider).reprice(r.id, {
        'drop': drop,
        'stops': stops,
        'km': ?km,
        'min': ?min,
      });
      if (!mounted) return;
      // The driver's WhatsApp sends the new link, as it did the first time.
      if (sent.way == MygigWay.whatsapp) await openMygigWhatsApp(sent);
      if (!mounted) return;
      await Navigator.of(context).push(AppPageRoute<void>(
        id: 'mygig.change-waiting',
        builder: (_) => MygigWaitingScreen(sent: sent, change: true),
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    final g = MygigRide.of(r.raw);
    if (g == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final waitingAtStop = g.stopWaitSince != null;
    final pickupWait = r.raw['waiting_charge'] is num ? (r.raw['waiting_charge'] as num).toDouble() : 0.0;
    final waitSoFar = pickupWait + g.stopWaitCharge;
    return Card(
      key: const ValueKey('mygig-trip-card'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.hail, size: 18),
            const SizedBox(width: 6),
            Expanded(child: Text('myGiG · ${mygigPayName(g.pay)}', style: t.textTheme.titleSmall)),
          ]),
          Text(g.following, style: t.textTheme.bodySmall),
          // No losses (owner's rule): paid before the trip, or collected.
          if (r.status != RideStatus.completed) MygigPayFirst(ride: r),
          if (r.status == RideStatus.arrived && !g.waitOn)
            Text('Waiting is free on this ride.', style: t.textTheme.bodySmall),
          // 0331: reassign before pickup, hand over during the trip (as the admin allows).
          if (r.status.isOngoing) MygigReassignButton(ride: r),
          if (r.status == RideStatus.arrived && mygigNoShowReady(r, g, _now))
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('mygig-no-show'),
                style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
                icon: const Icon(Icons.person_off_outlined),
                label: Text('Passenger didn’t come${g.canCharge && g.noShowFee > 0 ? ' · charge ${mygigMoney(g.noShowFee)}' : ' · no fee'}'),
                onPressed: () => _noShow(g),
              ),
            ),
          if (r.status == RideStatus.onTrip) ...[
            if (waitSoFar > 0)
              Text('Waiting so far: ${mygigMoney(waitSoFar)} (the passenger sees it)',
                  key: const ValueKey('mygig-wait-so-far'), style: t.textTheme.bodySmall),
            Wrap(spacing: 4, children: [
              TextButton.icon(
                key: const ValueKey('mygig-change-dest'),
                icon: const Icon(Icons.edit_location_alt_outlined),
                label: const Text('Change destination'),
                onPressed: () => _change(addStop: false),
              ),
              if (r.stops.length < mygigMaxStops)
                TextButton.icon(
                  key: const ValueKey('mygig-add-stop'),
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: const Text('Add stop'),
                  onPressed: () => _change(addStop: true),
                ),
              if (g.waitOn)
                BusyButton.text(
                  key: const ValueKey('mygig-stop-wait'),
                  icon: Icon(waitingAtStop ? Icons.play_arrow : Icons.more_time),
                  onPressed: () => _stopWait(!waitingAtStop),
                  child: Text(waitingAtStop ? 'Carry on (waiting ${mygigMinutesSince(g.stopWaitSince, _now)} min)' : 'Waiting at a stop'),
                ),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// After the trip: what myGiG adds to the collect card.
class MygigCollectCard extends ConsumerWidget {
  const MygigCollectCard({super.key, required this.ride});
  final RideRequest ride;

  Future<void> _block(BuildContext context, WidgetRef ref, MygigRide g) async {
    final ok = await showAppDialog<bool>(
      id: 'mygig.block',
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Block ${g.phone ?? 'this number'}?'),
        content: const Text('You won’t be able to send a myGiG to this number. get.ride is told, and you can unblock it '
            'in myGiG settings.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('mygig-block-ok'), onPressed: () => Navigator.pop(c, true), child: const Text('Block')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(mygigRepositoryProvider).block(ride: ride.id);
      if (!context.mounted) return;
      await showAppNotice(
        id: 'notice.mygig',
        context: context,
        title: 'Number blocked',
        message: 'No more myGiG rides from this number. Unblock it any time in myGiG settings.',
      );
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = MygigRide.of(ride.raw);
    if (g == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final paid = ride.paymentStatus == RidePaymentStatus.paid;
    return Card(
      key: const ValueKey('mygig-collect'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (g.tripFeeAmount > 0)
          ListTile(
            key: const ValueKey('mygig-trip-fee'),
            dense: true,
            title: Text('Your myGiG fee (${g.tripFee.text}), from GET.credit'),
            trailing: Text('−${mygigMoney(g.tripFeeAmount)}'),
          ),
        if (g.cashPaid > 0 || g.linkPaid > 0)
          ListTile(
            key: const ValueKey('mygig-paid-before'),
            dense: true,
            title: Text(g.linkPaid > 0 ? 'Paid by link before the end' : 'Paid in cash before the end'),
            trailing: Text(mygigMoney(g.linkPaid + g.cashPaid)),
          ),
        if (g.pay == MygigPay.family)
          ListTile(
            leading: const Icon(Icons.family_restroom),
            title: Text(paid ? 'Paid by the Family host’s GET.wallet' : 'Family pays this trip'),
            subtitle: Text(paid ? 'Family · nothing to collect' : 'If Family can’t cover it, the passenger pays in their app.'),
          ),
        if (g.pay == MygigPay.business)
          const ListTile(
            leading: Icon(Icons.business_center_outlined),
            title: Text('Charged to the business account'),
            subtitle: Text('Business account · nothing to collect'),
          ),
        if (g.pay == MygigPay.link && !paid) ...[
          ListTile(
            key: const ValueKey('mygig-link-waiting'),
            leading: const Icon(Icons.hourglass_top),
            title: const Text('Waiting for the passenger to pay'),
            subtitle: Text(g.payUrl == null
                ? 'Send the payment link: card, FPX or DuitNow.'
                : 'Payment link sent to ${g.phone ?? 'the passenger'}: card, FPX or DuitNow.'),
          ),
          Wrap(alignment: WrapAlignment.center, spacing: 4, children: [
            BusyButton.text(
              key: const ValueKey('mygig-send-pay-link'),
              icon: const Icon(Icons.link),
              onPressed: () async {
                try {
                  await ref.read(mygigRepositoryProvider).sendPayLink(ride.id);
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              child: Text(g.payUrl == null ? 'Send payment link' : 'Send it again'),
            ),
            BusyButton.text(
              key: const ValueKey('mygig-take-cash'),
              icon: const Icon(Icons.payments_outlined),
              onPressed: () async {
                try {
                  await ref.read(mygigRepositoryProvider).takeCash(ride.id);
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              child: const Text('Didn’t pay? Take cash'),
            ),
          ]),
        ],
        if (g.phone != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(g.way == MygigWay.app ? 'Receipt sent to their app' : 'The receipt is on their trip link',
                textAlign: TextAlign.center, style: t.textTheme.bodySmall),
          ),
        if (g.phone != null)
          TextButton.icon(
            key: const ValueKey('mygig-block'),
            style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
            icon: const Icon(Icons.block),
            label: const Text('Block this number'),
            onPressed: () => _block(context, ref, g),
          ),
      ]),
    );
  }
}


/// What must be paid before the trip starts or ends (no losses to get.ride
/// or the driver): a pay-by-link passenger's price (the link is sent; or
/// cash instead), what was added at Complete, and a cash passenger's
/// coming to the pickup.
class MygigPayFirst extends ConsumerWidget {
  const MygigPayFirst({super.key, required this.ride});
  final RideRequest ride;

  Future<void> _run(BuildContext context, Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = MygigRide.of(ride.raw);
    if (g == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final repo = ref.read(mygigRepositoryProvider);
    if (g.owed > 0) {
      final atEnd = g.pendingFinal.isNotEmpty;
      return Container(
        key: const ValueKey('mygig-pay-first'),
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: t.colorScheme.tertiaryContainer, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            atEnd
                ? 'Collect ${mygigMoney(g.owed)} more before you complete (tolls, parking, waiting or a changed route)'
                : 'The passenger pays ${mygigMoney(g.owed)} by link before the trip starts',
            style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onTertiaryContainer),
          ),
          Text(g.payUrl == null ? 'Send the payment link: card, FPX or DuitNow.' : 'Payment link sent. It updates here once paid.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onTertiaryContainer)),
          Wrap(spacing: 4, children: [
            BusyButton.text(
              key: const ValueKey('mygig-pay-link'),
              icon: const Icon(Icons.link),
              onPressed: () => _run(context, () => repo.sendPayLink(ride.id)),
              child: Text(g.payUrl == null ? 'Send payment link' : 'Send it again'),
            ),
            BusyButton.text(
              key: const ValueKey('mygig-pay-cash'),
              icon: const Icon(Icons.payments_outlined),
              onPressed: () => _run(context, () async {
                await repo.takeCash(ride.id);
                if (atEnd) await repo.complete(ride.id);
              }),
              child: Text('Received ${mygigMoney(g.owed)} in cash'),
            ),
          ]),
        ]),
      );
    }
    if (g.approachCashDue > 0 && (ride.status == RideStatus.accepted || ride.status == RideStatus.arrived)) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: BusyButton.tonal(
          key: const ValueKey('mygig-approach-cash'),
          icon: const Icon(Icons.payments_outlined),
          onPressed: () => _run(context, () => repo.approachCash(ride.id)),
          child: Text('Received ${mygigMoney(g.approachCashDue)} for coming to the pickup'),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
