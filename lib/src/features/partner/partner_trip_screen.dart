import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/ride_map.dart';
import '../ride/ride_tracking_screen.dart' show rideStreamProvider;

LatLng? _ll(double? lat, double? lng) => lat == null || lng == null ? null : LatLng(lat, lng);

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

  @override
  void initState() {
    super.initState();
    _startGps();
  }

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

  void _navigate(LatLng to) {
    final url = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${to.latitude},${to.longitude}');
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
                Text('The passenger asked to cancel${r.raw['cancel_reason'] != null ? ': ${r.raw['cancel_reason']}' : '.'}'),
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
        if (r.status.isOngoing && target != null)
          OutlinedButton.icon(
            icon: const Icon(Icons.navigation_outlined),
            label: const Text('Navigate'),
            onPressed: () => _navigate(target),
          ),
        const SizedBox(height: 8),
        if (r.status == RideStatus.accepted)
          FilledButton(
            onPressed: _busy ? null : () => _run(() => repo.updateStatus(r.id, RideStatus.arrived)),
            child: const Text("I've arrived"),
          ),
        if (r.status == RideStatus.arrived)
          FilledButton(onPressed: _busy ? null : () => _start(r), child: const Text('Start trip')),
        if (r.status == RideStatus.onTrip)
          FilledButton(
            onPressed: _busy ? null : () => _run(() => repo.complete(r)),
            child: Text('Complete trip · collect ${formatMoney(r.effectiveFare, r.currency)}'),
          ),
        if (r.status == RideStatus.accepted || r.status == RideStatus.arrived)
          TextButton(
            onPressed: _busy || r.cancelRequestedAt != null
                ? null
                : () => _run(() => repo.cancel(r, by: 'partner', reason: 'Cancelled by driver')),
            child: Text(r.cancelRequestedBy == 'partner' ? 'Cancellation requested' : 'Ask passenger to cancel'),
          ),
        if (r.status.isFinished)
          FilledButton(onPressed: () => context.go('/drive'), child: const Text('Back to requests')),
      ]),
    );
  }
}
