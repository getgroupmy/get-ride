import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/early_end.dart';
import '../../core/format.dart';
import '../../core/navigation_app.dart';
import '../../core/trip_charges.dart';
import '../../core/trip_checkpoint.dart';
import '../../core/trip_progress.dart';
import '../../core/ride_cancel.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/cancel_request_prompt.dart';
import '../../widgets/common.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/ride_stop_tiles.dart';
import '../ride/live_ride_map.dart';
import '../ride/ride_tracking_screen.dart' show rideStreamProvider;
import '../safety/voice_protection_controller.dart';

LatLng? _ll(double? lat, double? lng) => lat == null || lng == null ? null : LatLng(lat, lng);

/// A one-off fix for a trip checkpoint when the screen's own GPS stream has
/// not produced one yet. Null when location is unavailable.
final tripFixProvider = Provider<Future<LatLng?> Function()>((ref) => () async {
  try {
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).timeout(const Duration(seconds: 8));
    return LatLng(p.latitude, p.longitude);
  } catch (_) {
    try {
      final last = kIsWeb ? null : await Geolocator.getLastKnownPosition();
      return last == null ? null : LatLng(last.latitude, last.longitude);
    } catch (_) {
      return null;
    }
  }
});

/// One fix from the driver's phone: where, which way, and how loose.
typedef TripFix = ({LatLng at, double? heading, double? accuracy});

/// The driver's own position stream while on the trip screen. Empty when
/// location is unavailable or refused.
final tripPositionStreamProvider = Provider<Stream<TripFix> Function()>((ref) => () async* {
  try {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
    yield* Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 15),
    ).map((p) => (at: LatLng(p.latitude, p.longitude), heading: p.heading < 0 ? null : p.heading, accuracy: p.accuracy));
  } catch (_) {}
});

/// The trip screen's clock, for the running trip time. For tests.
final tripClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Driver view of an accepted trip: navigate, arrive, verify code, start, complete.
class PartnerTripScreen extends ConsumerStatefulWidget {
  const PartnerTripScreen({super.key, required this.requestId});
  final String requestId;

  @override
  ConsumerState<PartnerTripScreen> createState() => _PartnerTripScreenState();
}

class _PartnerTripScreenState extends ConsumerState<PartnerTripScreen> {
  StreamSubscription<TripFix>? _gps;
  LatLng? _me;
  double? _heading;
  // The running trip: when this screen first saw it on trip (the row's
  // started_at wins), the distance driven since, and the last fix it counted.
  DateTime? _onTripSince;
  double _metres = 0;
  LatLng? _legFrom;
  DateTime? _legAt;
  Timer? _tick;
  RideStatus? _status;
  // Set when the driver approves the passenger's cancel here, so the end of
  // the ride isn't announced back to them.
  bool _approvedHere = false;
  DateTime _lastPublish = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false;
  late final VoiceProtectionController _voice;

  @override
  void initState() {
    super.initState();
    _voice = ref.read(voiceProtectionProvider.notifier);
    _gps = ref.read(tripPositionStreamProvider)().listen(_onPosition, onError: (_) {});
    // VoiceProtection records the trip from the moment it starts (gated by the
    // driver's own switch inside the controller) and files it when it ends.
    ref.listenManual(rideStreamProvider(widget.requestId), (_, next) {
      final r = next.value;
      if (r == null) return;
      final before = _status;
      _status = r.status;
      if (r.status == RideStatus.onTrip) {
        unawaited(_voice.startTrip(rideId: r.id, label: _tripLabel(r)));
        if (before != RideStatus.onTrip) _beginTrip();
      } else {
        _tick?.cancel();
        _tick = null;
        if (r.status.isFinished) unawaited(_voice.stopTrip());
      }
      final notice = passengerCancelNotice(before, r, approvedHere: _approvedHere);
      if (notice != null) WidgetsBinding.instance.addPostFrameCallback((_) => _showCancelled(notice));
      WidgetsBinding.instance.addPostFrameCallback((_) => _askAboutCancel(r));
    }, fireImmediately: true);
  }

  DateTime get _now => ref.read(tripClockProvider)();

  final _cancelPrompt = CancelRequestPrompt();

  /// The passenger's request to cancel, as a popup the driver answers.
  void _askAboutCancel(RideRequest r) {
    if (!mounted) return;
    final asking = r.cancelRequestedAt != null && r.cancelRequestedBy == 'rider' && r.status.isOngoing;
    final why = cancelReasonLabel(r.cancelReason);
    final repo = ref.read(rideRepositoryProvider);
    _cancelPrompt.update(
      context,
      askedAt: asking ? r.cancelRequestedAt : null,
      message: why == null ? 'The passenger asked to cancel.' : 'The passenger asked to cancel: $why',
      onDecline: () => _run(() => repo.declineCancellation(r.id)),
      onApprove: () => _run(() async {
        _approvedHere = true;
        try {
          await repo.approveCancellation(r.id);
        } catch (_) {
          _approvedHere = false;
          rethrow;
        }
      }),
    );
  }

  void _beginTrip() {
    _onTripSince = _now;
    _metres = 0;
    _legFrom = _me;
    _legAt = _me == null ? null : _onTripSince;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _showCancelled(String notice) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('trip-cancelled'),
        title: const Text('Ride cancelled'),
        content: Text(notice),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Back to requests'))],
      ),
    );
    if (mounted) context.go('/drive');
  }

  static String _tripLabel(RideRequest r) => '${r.pickupLabel} → ${r.dropLabel}';

  void _onPosition(TripFix p) {
    if (!mounted) return;
    final now = _now;
    setState(() {
      _me = p.at;
      _heading = p.heading;
      // Only the trip itself counts toward the distance driven.
      if (_status == RideStatus.onTrip) {
        if (_legFrom != null && _legAt != null) {
          _metres += tripLegMetres(_legFrom!, p.at, now.difference(_legAt!), accuracy: p.accuracy);
        }
        if (p.accuracy == null || p.accuracy! <= tripFixMaxAccuracyMetres) {
          _legFrom = p.at;
          _legAt = now;
        }
      }
    });
    // Share the driver's live position with the rider at most every 5 s.
    if (now.difference(_lastPublish) < const Duration(seconds: 5)) return;
    _lastPublish = now;
    ref
        .read(rideRepositoryProvider)
        .publishPartnerLocation(widget.requestId, p.at.latitude, p.at.longitude, p.heading)
        .catchError((_) {});
  }

  @override
  void dispose() {
    _gps?.cancel();
    _tick?.cancel();
    // Leaving the trip screen always files whatever was recorded — after the
    // unmount, since a provider can't change while the tree is being torn down.
    unawaited(Future.microtask(_voice.stopTrip));
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start(RideRequest r) async {
    if (r.otp != null && r.otp!.isNotEmpty) {
      final code = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final c = TextEditingController();
          return AlertDialog(
            title: const Text('Enter trip code'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Ask the passenger for the 4-digit code shown in their app.'),
              const SizedBox(height: 12),
              CodeField(controller: c, length: 4),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Start trip')),
            ],
          );
        },
      );
      if (code == null) return;
      if (code != r.otp) {
        if (mounted) showInfo(context, 'That code is not correct.');
        return;
      }
    }
    await _run(() => ref.read(rideRepositoryProvider).updateStatus(r.id, RideStatus.onTrip));
  }

  /// The driver cancels before pickup, with a reason; the passenger is told
  /// (see [driverCancelNotice]). Once the passenger is on board there is no
  /// cancel key: the trip is completed or ended early.
  Future<void> _cancel(RideRequest r) async {
    final reason = await showDialog<String>(context: context, builder: (_) => const _DriverCancelDialog());
    if (reason == null || !mounted) return;
    RideRequest? done;
    var answered = false;
    _approvedHere = true;
    await _run(() async {
      done = await ref.read(rideRepositoryProvider).cancelAsDriver(r.id, reason);
      answered = true;
    });
    if (!mounted) return;
    if (done != null) return context.go('/drive');
    _approvedHere = false;
    // A failed write has already been reported by _run.
    if (answered) showInfo(context, "This ride can't be cancelled now: the passenger is on board or it has ended.");
  }

  /// Records where the driver is at [checkpoint] (Expo
  /// `recordPartnerCheckpoint`) for the admin fraud checks. Fire-and-forget:
  /// the trip never waits on it.
  Future<void> _checkpoint(String id, TripCheckpoint checkpoint) async {
    final fix = _me ?? await ref.read(tripFixProvider)();
    if (fix == null) return;
    await ref.read(rideRepositoryProvider).recordCheckpoint(id, checkpoint, fix.latitude, fix.longitude);
  }

  Future<void> _arrive(RideRequest r) => _run(() async {
    await ref.read(rideRepositoryProvider).updateStatus(r.id, RideStatus.arrived);
    unawaited(_checkpoint(r.id, TripCheckpoint.arrive));
  });

  /// Completing asks first for the tolls and other charges the meter of a
  /// fare can't know (Expo's tolls popup); they go on the ride for the rider.
  ///
  /// Completing away from the drop-off ends the trip early (Expo's "End ride
  /// early?"): the fare is recalculated for the distance actually covered and
  /// confirmed first, then stored on the ride.
  Future<void> _complete(RideRequest r) async {
    double? earlyFare;
    final here = _me;
    if (endsEarly(here, _ll(r.dropLat, r.dropLng))) {
      earlyFare = await _confirmEarlyEnd(r, here!);
      if (earlyFare == null || !mounted) return;
    }
    final charges = await showDialog<TripCharges>(
      context: context,
      builder: (_) => _ChargesDialog(fare: earlyFare ?? r.effectiveFare ?? 0, currency: r.currency),
    );
    if (charges == null || !mounted) return;
    await _run(() async {
      // Stamped before the status change, as Expo does, so the drop point is
      // where the driver stood when they pressed complete.
      unawaited(_checkpoint(r.id, TripCheckpoint.drop));
      await ref.read(rideRepositoryProvider).complete(r, charges: charges, earlyFare: earlyFare);
    });
  }

  /// Works out the early-end fare and asks the driver to confirm it; null
  /// keeps driving. The distance covered is the road route from the pickup
  /// to here (as Expo measured it), else what this screen counted.
  Future<double?> _confirmEarlyEnd(RideRequest r, LatLng here) async {
    final geo = ref.read(geoServiceProvider);
    final pickup = _ll(r.pickupLat, r.pickupLng), drop = _ll(r.dropLat, r.dropLng);
    Future<double?> km(LatLng? a, LatLng? b) async {
      if (a == null || b == null) return null;
      try {
        return (await geo.route(a, b)).distanceKm;
      } catch (_) {
        return null;
      }
    }

    setState(() => _busy = true);
    final (routed, planned) = await (km(pickup, here), r.distanceKm != null ? Future.value(r.distanceKm) : km(pickup, drop)).wait;
    if (!mounted) return null;
    setState(() => _busy = false);
    final driven = routed ?? (_metres > 0 ? _metres / 1000 : null);
    final agreed = r.effectiveFare ?? 0;
    final fare = earlyEndFare(agreed: agreed, plannedKm: planned, drivenKm: driven);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('early-end'),
        title: const Text('End ride early?'),
        content: Text(
          [
            "You haven't reached the drop-off yet.",
            if (driven != null && planned != null)
              'The fare is recalculated for the ${driven.toStringAsFixed(1)} km driven of the '
                  '${planned.toStringAsFixed(1)} km booked: ${formatMoney(fare, r.currency)} '
                  'instead of ${formatMoney(agreed, r.currency)}.'
            else
              "The distance driven can't be measured, so the booked fare of ${formatMoney(agreed, r.currency)} stands.",
          ].join('\n\n'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep driving')),
          FilledButton(
            key: const ValueKey('early-end-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End ride here'),
          ),
        ],
      ),
    );
    return go == true ? fare : null;
  }

  void _navigate(LatLng to) {
    final url = navigationUri(ref.read(navigationAppProvider), to.latitude, to.longitude);
    launchUrl(url, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final ride = ref.watch(rideStreamProvider(widget.requestId));
    // While the trip is on there is no way back off this screen: the ride
    // ends by completing it (or cancelling before pickup), not by leaving.
    final onTrip = ride.value?.status.isOngoing ?? false;
    return PopScope(
      canPop: !onTrip,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !onTrip) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Finish the trip to leave this screen.')));
      },
      child: _scaffold(ride, onTrip),
    );
  }

  Widget _scaffold(AsyncValue<RideRequest> ride, bool onTrip) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Current trip'),
        automaticallyImplyLeading: false,
        leading: onTrip
            ? null
            : BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/drive')),
      ),
      body: AsyncView(
        value: ride,
        onRetry: () => ref.invalidate(rideStreamProvider(widget.requestId)),
        data: (r) {
          final map = LiveRideMap(ride: r, driverAt: _me, driverHeading: _heading, now: ref.read(tripClockProvider));
          final panel = _panel(r);
          if (MediaQuery.sizeOf(context).width >= 900) {
            return Row(children: [
              SizedBox(width: 420, child: SingleChildScrollView(child: panel)),
              const VerticalDivider(width: 1),
              Expanded(child: map),
            ]);
          }
          return MapSheetLayout(map: map, sheet: panel);
        },
      ),
    );
  }

  Widget _panel(RideRequest r) {
    final t = Theme.of(context);
    final target = r.status == RideStatus.onTrip ? _ll(r.dropLat, r.dropLng) : _ll(r.pickupLat, r.pickupLng);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(switch (r.status) {
          RideStatus.accepted => 'Head to pickup',
          RideStatus.arrived => 'Waiting for passenger',
          RideStatus.onTrip => 'Drive to destination',
          _ => r.status.label,
        }, style: t.textTheme.headlineSmall),
        const SizedBox(height: 12),
        Card(
          child: Column(children: [
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(r.passengerName),
              subtitle: Text([
                '${r.passengers} passenger${r.passengers == 1 ? '' : 's'} · ${r.paymentMode}',
                if (r.isForOthers) 'Booked by ${r.riderName ?? 'another rider'}',
              ].join('\n')),
              isThreeLine: r.isForOthers,
              trailing: r.passengerPhone == null
                  ? null
                  : IconButton(
                      tooltip: 'Call ${r.passengerName}',
                      icon: const Icon(Icons.call),
                      onPressed: () => launchUrl(Uri(scheme: 'tel', path: r.passengerPhone)),
                    ),
            ),
            ListTile(
              leading: Icon(Icons.trip_origin, color: Colors.green.shade700),
              title: Text(r.pickupLabel),
              subtitle: r.pickupAddress == null ? null : Text(r.pickupAddress!, maxLines: 2),
            ),
            RideStopTiles(stops: r.stops, onNavigate: r.status.isOngoing ? (s) => _navigate(s.point) : null),
            ListTile(
              leading: Icon(Icons.location_on, color: Colors.red.shade700),
              title: Text(r.dropLabel),
              subtitle: r.dropAddress == null ? null : Text(r.dropAddress!, maxLines: 2),
            ),
            if (r.note != null) ListTile(leading: const Icon(Icons.notes), title: Text(r.note!)),
            const Divider(height: 1),
            ListTile(
              title: Text(r.service ?? 'Ride'),
              subtitle: Text('${formatDistance(r.distanceKm)} · ${formatDuration(r.durationMin)}'),
              trailing: Text(formatMoney(r.effectiveFare, r.currency),
                  style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
        if (r.status == RideStatus.onTrip) ...[
          const SizedBox(height: 8),
          Row(key: const ValueKey('trip-meter'), children: [
            const Icon(Icons.timer_outlined, size: 18),
            const SizedBox(width: 6),
            Text(formatTripElapsed(tripElapsed(startedAt: r.startedAt, firstSeen: _onTripSince, now: _now)),
                style: t.textTheme.titleMedium),
            const SizedBox(width: 16),
            const Icon(Icons.route_outlined, size: 18),
            const SizedBox(width: 6),
            Text('${(_metres / 1000).toStringAsFixed(1)} km driven', style: t.textTheme.titleMedium),
          ]),
        ],
        const SizedBox(height: 12),
        const _VoiceProtectionPill(),
        if (r.status.isOngoing && target != null)
          OutlinedButton.icon(
            icon: const Icon(Icons.navigation_outlined),
            label: const Text('Navigate'),
            onPressed: () => _navigate(target),
          ),
        const SizedBox(height: 8),
        if (r.status == RideStatus.accepted)
          FilledButton(
            key: const ValueKey('trip-arrive'),
            onPressed: _busy ? null : () => _arrive(r),
            child: const Text("I've arrived"),
          ),
        if (r.status == RideStatus.arrived)
          FilledButton(onPressed: _busy ? null : () => _start(r), child: const Text('Start trip')),
        if (r.status == RideStatus.onTrip)
          FilledButton(
            key: const ValueKey('trip-complete'),
            onPressed: _busy ? null : () => _complete(r),
            child: Text('Complete trip · collect ${formatMoney(r.effectiveFare, r.currency)}'),
          ),
        if (driverMayCancel(r.status))
          TextButton(
            key: const ValueKey('trip-cancel'),
            onPressed: _busy ? null : () => _cancel(r),
            child: const Text('Cancel ride'),
          ),
        if (r.status == RideStatus.completed) _CollectCard(ride: r),
        if (r.status == RideStatus.completed)
          OutlinedButton.icon(
            key: const ValueKey('trip-receipt'),
            icon: const Icon(Icons.receipt_long_outlined),
            label: const Text('View receipt'),
            onPressed: () => context.push('/trips/${r.id}'),
          ),
        if (r.status.isFinished)
          FilledButton(onPressed: () => context.go('/drive'), child: const Text('Back to requests')),
      ]),
    );
  }
}

/// Shown while VoiceProtection is recording the trip (or says why it isn't).
class _VoiceProtectionPill extends ConsumerWidget {
  const _VoiceProtectionPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(voiceProtectionProvider);
    if (!v.recording && v.error == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(v.recording ? Icons.fiber_manual_record : Icons.mic_off_outlined,
            size: 16, color: v.recording ? t.colorScheme.error : t.colorScheme.outline),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            v.recording ? 'VoiceProtection recording' : v.error!,
            style: t.textTheme.bodySmall,
          ),
        ),
      ]),
    );
  }
}

/// Tolls and other charges, declared on Complete. Blank means none.
class _ChargesDialog extends StatefulWidget {
  const _ChargesDialog({required this.fare, required this.currency});
  final double fare;
  final String currency;

  @override
  State<_ChargesDialog> createState() => _ChargesDialogState();
}

class _ChargesDialogState extends State<_ChargesDialog> {
  final _tolls = TextEditingController();
  final _other = TextEditingController();
  final _note = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _tolls.dispose();
    _other.dispose();
    _note.dispose();
    super.dispose();
  }

  ({TripCharges? charges, String? problem}) get _resolved =>
      resolveTripCharges(tolls: _tolls.text, other: _other.text, note: _note.text);

  @override
  Widget build(BuildContext context) {
    // The running total counts whatever amounts read, before the note is in.
    final total = widget.fare + (parseChargeAmount(_tolls.text) ?? 0) + (parseChargeAmount(_other.text) ?? 0);
    const amount = TextInputType.numberWithOptions(decimal: true);
    return AlertDialog(
      key: const ValueKey('trip-charges'),
      title: const Text('Complete trip'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Add any tolls or other charges the passenger owes on top of the fare.'),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('charges-tolls'),
            controller: _tolls,
            keyboardType: amount,
            decoration: const InputDecoration(labelText: 'Tolls', hintText: '0.00'),
            onChanged: (_) => setState(() => _problem = null),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('charges-other'),
            controller: _other,
            keyboardType: amount,
            decoration: const InputDecoration(labelText: 'Other charges', hintText: '0.00'),
            onChanged: (_) => setState(() => _problem = null),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('charges-note'),
            controller: _note,
            maxLength: tripChargeNoteMax,
            decoration: const InputDecoration(labelText: 'What the other charges are for', hintText: 'e.g. Parking'),
            onChanged: (_) => setState(() => _problem = null),
          ),
          if (_problem != null)
            Text(_problem!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 4),
          Text('Collect ${formatMoney(total, widget.currency)}',
              key: const ValueKey('charges-total'), style: Theme.of(context).textTheme.titleMedium),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('charges-confirm'),
          onPressed: () {
            final r = _resolved;
            if (r.charges == null) return setState(() => _problem = r.problem);
            Navigator.pop(context, r.charges);
          },
          child: const Text('Complete'),
        ),
      ],
    );
  }
}

/// What the driver collects once the trip is complete: the total due, less
/// whatever the rider paid with GET.coin, which is credited to the driver's
/// GET.wallet (migration 0101) and updates here live when it lands.
class _CollectCard extends StatelessWidget {
  const _CollectCard({required this.ride});
  final RideRequest ride;

  @override
  Widget build(BuildContext context) {
    final r = ride, t = Theme.of(context);
    final coins = r.fareCoinsValue;
    return Card(
      key: const ValueKey('trip-collect'),
      child: Column(children: [
        ListTile(
          title: const Text('Total due'),
          trailing: Text(formatMoney(r.totalDue, r.currency)),
        ),
        if (coins > 0)
          ListTile(
            key: const ValueKey('trip-collect-coins'),
            leading: const Icon(Icons.toll_outlined, color: Color(0xFFB8860B)),
            title: const Text('Paid with GET.coin'),
            subtitle: const Text('Added to your GET.wallet'),
            trailing: Text('−${formatMoney(coins, r.currency)}'),
          ),
        const Divider(height: 1),
        ListTile(
          title: const Text('Collect from passenger', style: TextStyle(fontWeight: FontWeight.w700)),
          trailing: Text(formatMoney(r.cashDue, r.currency),
              style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}

/// Expo's driver "Why are you cancelling?" sheet: one reason, required;
/// "Other" needs the driver's own words. Pops the value to store, or null to
/// keep the ride.
class _DriverCancelDialog extends StatefulWidget {
  const _DriverCancelDialog();

  @override
  State<_DriverCancelDialog> createState() => _DriverCancelDialogState();
}

class _DriverCancelDialogState extends State<_DriverCancelDialog> {
  String? _picked;
  final _other = TextEditingController();

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = cancelReasonValue(_picked, _other.text);
    return AlertDialog(
      key: const ValueKey('driver-cancel-dialog'),
      title: const Text('Cancel this ride?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("The passenger will be told you cancelled. You can't cancel once they're on board."),
            const SizedBox(height: 8),
            Text('Why are you cancelling?', style: Theme.of(context).textTheme.titleSmall),
            RadioGroup<String>(
              groupValue: _picked,
              onChanged: (v) => setState(() => _picked = v),
              child: Column(
                children: [
                  for (final reason in driverCancelReasons)
                    RadioListTile<String>(
                      key: ValueKey('driver-cancel-reason-${reason.id}'),
                      value: reason.id,
                      title: Text(reason.label),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            if (_picked == otherCancelReason)
              TextField(
                key: const ValueKey('driver-cancel-reason-text'),
                controller: _other,
                autofocus: true,
                maxLength: 200,
                decoration: const InputDecoration(labelText: 'Tell us more'),
                onChanged: (_) => setState(() {}),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Keep ride')),
        FilledButton(
          key: const ValueKey('driver-cancel-confirm'),
          onPressed: value == null ? null : () => Navigator.pop(context, value),
          child: const Text('Cancel ride'),
        ),
      ],
    );
  }
}
