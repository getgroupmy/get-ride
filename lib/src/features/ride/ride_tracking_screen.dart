import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/ride_map.dart';

final rideStreamProvider = StreamProvider.autoDispose.family<RideRequest, String>(
  (ref, id) => ref.watch(rideRepositoryProvider).watch(id),
);

LatLng? _ll(double? lat, double? lng) => lat == null || lng == null ? null : LatLng(lat, lng);

/// Rider view of one request: searching → driver assigned → on trip → done.
class RideTrackingScreen extends ConsumerWidget {
  const RideTrackingScreen({super.key, required this.requestId});
  final String requestId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ride = ref.watch(rideStreamProvider(requestId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your ride'),
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/')),
      ),
      body: AsyncView(
        value: ride,
        onRetry: () => ref.invalidate(rideStreamProvider(requestId)),
        data: (r) {
          final map = RideMap(
            pickup: _ll(r.pickupLat, r.pickupLng),
            drop: _ll(r.dropLat, r.dropLng),
            driver: _ll(r.partnerLiveLat, r.partnerLiveLng),
          );
          final panel = _RidePanel(ride: r);
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
}

class _RidePanel extends ConsumerStatefulWidget {
  const _RidePanel({required this.ride});
  final RideRequest ride;

  @override
  ConsumerState<_RidePanel> createState() => _RidePanelState();
}

class _RidePanelState extends ConsumerState<_RidePanel> {
  bool _busy = false;

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

  Future<void> _cancel() async {
    final r = widget.ride;
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController();
        return AlertDialog(
          title: Text(r.status == RideStatus.open ? 'Cancel request?' : 'Request cancellation?'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            if (r.status != RideStatus.open)
              const Text('Your driver has accepted. They will be asked to approve the cancellation.'),
            TextField(controller: c, decoration: const InputDecoration(labelText: 'Reason (optional)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Keep ride')),
            FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Cancel ride')),
          ],
        );
      },
    );
    if (reason == null) return;
    await _run(() => ref.read(rideRepositoryProvider).cancel(r, reason: reason, by: 'rider'));
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    final t = Theme.of(context);
    final repo = ref.read(rideRepositoryProvider);
    final partnerCancelAsk = r.cancelRequestedAt != null && r.cancelRequestedBy == 'partner';
    final riderCancelAsk = r.cancelRequestedAt != null && r.cancelRequestedBy == 'rider';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (r.status == RideStatus.open)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          Expanded(child: Text(r.status.label, style: t.textTheme.headlineSmall)),
        ]),
        if (r.status == RideStatus.open)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Notifying nearby drivers…', style: t.textTheme.bodyMedium),
          ),
        const SizedBox(height: 16),
        if (r.partnerId != null && r.status.isOngoing)
          Card(
            child: Column(children: [
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: Text(r.partnerName ?? 'Your driver'),
                subtitle: Text([r.partnerVehicle, r.partnerPlate].whereType<String>().join(' · ')),
                trailing: r.partnerRating == null
                    ? null
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.star, size: 18, color: Colors.amber),
                        Text(r.partnerRating!.toStringAsFixed(1)),
                      ]),
              ),
              if (r.otp != null && r.status != RideStatus.onTrip)
                ListTile(
                  leading: const Icon(Icons.pin_outlined),
                  title: const Text('Trip code'),
                  subtitle: const Text('Share with your driver at pickup'),
                  trailing: Text(r.otp!, style: t.textTheme.headlineSmall?.copyWith(letterSpacing: 4)),
                ),
              if (r.partnerPhone != null)
                OverflowBar(children: [
                  TextButton.icon(
                    icon: const Icon(Icons.call),
                    label: const Text('Call'),
                    onPressed: () => launchUrl(Uri(scheme: 'tel', path: r.partnerPhone)),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.sms_outlined),
                    label: const Text('Message'),
                    onPressed: () => launchUrl(Uri(scheme: 'sms', path: r.partnerPhone)),
                  ),
                ]),
            ]),
          ),
        if (partnerCancelAsk && r.status.isOngoing)
          Card(
            color: t.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Your driver asked to cancel this ride.'),
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
        if (riderCancelAsk && r.status.isOngoing)
          const Card(
            child: ListTile(
              leading: Icon(Icons.hourglass_top),
              title: Text('Cancellation requested'),
              subtitle: Text('Waiting for the driver to confirm.'),
            ),
          ),
        Card(
          child: Column(children: [
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
            const Divider(height: 1),
            ListTile(
              title: Text(r.service ?? 'Ride'),
              subtitle: Text('${formatDistance(r.distanceKm)} · ${formatDuration(r.durationMin)} · ${r.paymentMode}'),
              trailing: Text(formatMoney(r.effectiveFare, r.currency),
                  style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        if (r.status.isOngoing && r.status != RideStatus.onTrip && !riderCancelAsk)
          OutlinedButton.icon(
            icon: const Icon(Icons.close),
            label: const Text('Cancel ride'),
            onPressed: _busy ? null : _cancel,
          ),
        if (r.status.isFinished)
          FilledButton(onPressed: () => context.go('/'), child: const Text('Done')),
      ]),
    );
  }
}
