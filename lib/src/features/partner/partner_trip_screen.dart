import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/navigation_app.dart';
import '../../core/trip_charges.dart';
import '../../core/trip_checkpoint.dart';
import '../../core/ride_cancel.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/ride_map.dart';
import '../../widgets/ride_stop_tiles.dart';
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

/// Driver view of an accepted trip: navigate, arrive, verify code, start, complete.
class PartnerTripScreen extends ConsumerStatefulWidget {
  const PartnerTripScreen({super.key, required this.requestId});
  final String requestId;

  @override
  ConsumerState<PartnerTripScreen> createState() => _PartnerTripScreenState();
}

class _PartnerTripScreenState extends ConsumerState<PartnerTripScreen> {
  StreamSubscription<Position>? _gps;
  LatLng? _me;
  DateTime _lastPublish = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false;
  late final VoiceProtectionController _voice;

  @override
  void initState() {
    super.initState();
    _voice = ref.read(voiceProtectionProvider.notifier);
    _startGps();
    // VoiceProtection records the trip from the moment it starts (gated by the
    // driver's own switch inside the controller) and files it when it ends.
    ref.listenManual(rideStreamProvider(widget.requestId), (_, next) {
      final r = next.value;
      if (r == null) return;
      if (r.status == RideStatus.onTrip) {
        unawaited(_voice.startTrip(rideId: r.id, label: _tripLabel(r)));
      } else if (r.status.isFinished) {
        unawaited(_voice.stopTrip());
      }
    }, fireImmediately: true);
  }

  static String _tripLabel(RideRequest r) => '${r.pickupLabel} → ${r.dropLabel}';

  Future<void> _startGps() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      _gps = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 15),
      ).listen(_onPosition, onError: (_) {});
    } catch (_) {}
  }

  void _onPosition(Position p) {
    if (!mounted) return;
    setState(() => _me = LatLng(p.latitude, p.longitude));
    // Share the driver's live position with the rider at most every 5 s.
    if (DateTime.now().difference(_lastPublish) < const Duration(seconds: 5)) return;
    _lastPublish = DateTime.now();
    ref
        .read(rideRepositoryProvider)
        .publishPartnerLocation(widget.requestId, p.latitude, p.longitude, p.heading)
        .catchError((_) {});
  }

  @override
  void dispose() {
    _gps?.cancel();
    // Leaving the trip screen always files whatever was recorded.
    unawaited(_voice.stopTrip());
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
  Future<void> _complete(RideRequest r) async {
    final charges = await showDialog<TripCharges>(
      context: context,
      builder: (_) => _ChargesDialog(fare: r.effectiveFare ?? 0, currency: r.currency),
    );
    if (charges == null || !mounted) return;
    await _run(() async {
      // Stamped before the status change, as Expo does, so the drop point is
      // where the driver stood when they pressed complete.
      unawaited(_checkpoint(r.id, TripCheckpoint.drop));
      await ref.read(rideRepositoryProvider).complete(r, charges: charges);
    });
  }

  void _navigate(LatLng to) {
    final url = navigationUri(ref.read(navigationAppProvider), to.latitude, to.longitude);
    launchUrl(url, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final ride = ref.watch(rideStreamProvider(widget.requestId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Current trip'),
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/drive')),
      ),
      body: AsyncView(
        value: ride,
        onRetry: () => ref.invalidate(rideStreamProvider(widget.requestId)),
        data: (r) {
          final map = RideMap(
            me: _me,
            pickup: _ll(r.pickupLat, r.pickupLng),
            drop: _ll(r.dropLat, r.dropLng),
            stops: [for (final s in r.stops) s.point],
          );
          final panel = _panel(r);
          if (MediaQuery.sizeOf(context).width >= 900) {
            return Row(children: [
              SizedBox(width: 420, child: SingleChildScrollView(child: panel)),
              const VerticalDivider(width: 1),
              Expanded(child: map),
            ]);
          }
          return Column(children: [
            Expanded(flex: 5, child: map),
            Expanded(flex: 6, child: SingleChildScrollView(child: panel)),
          ]);
        },
      ),
    );
  }

  Widget _panel(RideRequest r) {
    final t = Theme.of(context);
    final repo = ref.read(rideRepositoryProvider);
    final riderAskedCancel = r.cancelRequestedAt != null && r.cancelRequestedBy == 'rider';
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
        if (riderAskedCancel && r.status.isOngoing)
          Card(
            color: t.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(() {
                  final why = cancelReasonLabel(r.cancelReason);
                  return why == null ? 'The passenger asked to cancel.' : 'The passenger asked to cancel: $why';
                }()),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => _run(() => repo.declineCancellation(r.id)),
                      child: const Text('Decline'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : () => _run(() => repo.approveCancellation(r.id)),
                      child: const Text('Approve'),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        Card(
          child: Column(children: [
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(r.riderName ?? 'Passenger'),
              subtitle: Text('${r.passengers} passenger${r.passengers == 1 ? '' : 's'} · ${r.paymentMode}'),
              trailing: r.riderPhone == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.call),
                      onPressed: () => launchUrl(Uri(scheme: 'tel', path: r.riderPhone)),
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
        if (r.status == RideStatus.accepted || r.status == RideStatus.arrived)
          TextButton(
            onPressed: _busy || r.cancelRequestedAt != null
                ? null
                : () => _run(() => repo.cancel(r, by: 'partner', reason: 'Cancelled by driver')),
            child: Text(r.cancelRequestedBy == 'partner' ? 'Cancellation requested' : 'Ask passenger to cancel'),
          ),
        if (r.status == RideStatus.completed) _CollectCard(ride: r),
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
