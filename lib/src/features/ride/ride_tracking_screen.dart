import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../admin/screens/commerce/get_coin.dart' show formatCoins;
import '../../core/fare_coins.dart';
import '../../core/format.dart';
import '../../core/ride_bidding.dart';
import '../../core/sos.dart';
import '../../data/fare_coin_store.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/ride_map.dart';
import '../../widgets/ride_stop_tiles.dart';
import '../profile/emergency_contacts_screen.dart';
import '../safety/safety_screen.dart';
import '../wallet/wallet_screen.dart';

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
            stops: [for (final s in r.stops) s.point],
            driver: _ll(r.partnerLiveLat, r.partnerLiveLng),
          );
          final panel = _RidePanel(ride: r);
          if (MediaQuery.sizeOf(context).width >= 900) {
            return Row(
              children: [
                SizedBox(width: 420, child: SingleChildScrollView(child: panel)),
                const VerticalDivider(width: 1),
                Expanded(child: map),
              ],
            );
          }
          return Column(
            children: [
              Expanded(flex: 5, child: map),
              Expanded(flex: 6, child: SingleChildScrollView(child: panel)),
            ],
          );
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

  /// GET.coin earned on this trip, once it completes (null until claimed).
  double? _reward;
  bool _rewardClaimed = false;

  /// Whether this ride was booked with "Use GET.coin" on, and what the coins
  /// paid once applied at drop-off.
  bool _coinsChosen = false;
  FareCoinRedemption? _redeemed;

  @override
  void initState() {
    super.initState();
    ref.read(fareCoinChoiceStoreProvider).chosen(widget.ride.id).then((v) {
      if (mounted && v) setState(() => _coinsChosen = true);
    }, onError: (_) {});
    _maybeClaimReward();
  }

  @override
  void didUpdateWidget(covariant _RidePanel old) {
    super.didUpdateWidget(old);
    _maybeClaimReward();
  }

  void _maybeClaimReward() {
    if (_rewardClaimed || widget.ride.status != RideStatus.completed) return;
    _rewardClaimed = true;
    final repo = ref.read(rideRepositoryProvider);
    final ride = widget.ride;
    // Coins toward the fare and the ride reward are independent (the reward
    // is priced on the stored fare server-side), so each shows as it lands.
    void refreshWallet() {
      ref.invalidate(walletBalancesProvider);
      ref.invalidate(walletTxProvider);
    }

    repo.claimRideReward(ride).then((coins) {
      if (!mounted) return;
      setState(() => _reward = coins);
      if (coins > 0) refreshWallet();
    });
    redeemChosenFareCoins(repo, ref.read(fareCoinChoiceStoreProvider), ride).then((redeemed) {
      if (!mounted || redeemed == null || redeemed.coinsUsed <= 0) return;
      setState(() => _redeemed = redeemed);
      refreshWallet();
    });
  }

  /// The fare first seen on this screen: raises are capped against it.
  late final double? _quoted = widget.ride.fare;

  Future<void> _raise(double step) async {
    final r = widget.ride;
    final current = r.fare ?? 0;
    final next = raisedFare(current, step, quoted: _quoted ?? current);
    if (next <= current) {
      showInfo(context, 'The fare cannot go any higher.');
      return;
    }
    await _run(() async {
      final updated = await ref.read(rideRepositoryProvider).raiseFare(r.id, next);
      if (updated == null && mounted) showInfo(context, 'This request is no longer open.');
    });
  }

  Future<void> _acceptOffer(RideOffer o) async {
    await _run(() async {
      final won = await ref
          .read(rideRepositoryProvider)
          .acceptOffer(widget.ride.id, partnerId: o.partnerId, amount: o.amount);
      if (won == null && mounted) showInfo(context, 'That offer changed before you accepted it.');
    });
  }

  Future<void> _declineOffer(RideOffer o) =>
      _run(() => ref.read(rideRepositoryProvider).declineOffer(widget.ride.id, partnerId: o.partnerId));

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

  /// Emergency options during a ride: call the emergency number (Expo's
  /// SOS button dialled 999) or alert emergency contacts with the location,
  /// driver and car.
  Future<void> _sos(RideRequest r) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            key: const ValueKey('sos-call'),
            leading: const Icon(Icons.call),
            title: const Text('Call $emergencyNumber'),
            subtitle: const Text('Police, ambulance and fire'),
            onTap: () => Navigator.pop(c, 'call'),
          ),
          ListTile(
            key: const ValueKey('sos-contacts'),
            leading: const Icon(Icons.sms_outlined),
            title: const Text('Alert my emergency contacts'),
            subtitle: const Text('SMS with your location, driver and car'),
            onTap: () => Navigator.pop(c, 'contacts'),
          ),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'call') {
      await launchUrl(Uri(scheme: 'tel', path: emergencyNumber));
      return;
    }
    List<EmergencyContact> contacts;
    try {
      contacts = await ref.read(emergencyContactsProvider.future);
    } catch (_) {
      contacts = const [];
    }
    if (!mounted) return;
    await sendSos(context, contacts, driver: r.partnerName, plate: r.partnerPlate);
  }

  Future<void> _cancel() async {
    final r = widget.ride;
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController();
        return AlertDialog(
          title: Text(r.status == RideStatus.open ? 'Cancel request?' : 'Request cancellation?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (r.status != RideStatus.open)
                const Text('Your driver has accepted. They will be asked to approve the cancellation.'),
              TextField(
                controller: c,
                decoration: const InputDecoration(labelText: 'Reason (optional)'),
              ),
            ],
          ),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (r.status == RideStatus.open)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              Expanded(child: Text(r.status.label, style: t.textTheme.headlineSmall)),
            ],
          ),
          if (r.status == RideStatus.open)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Notifying nearby drivers…', style: t.textTheme.bodyMedium),
            ),
          const SizedBox(height: 16),
          if (standingOffer(r) case final offer?)
            Card(
              key: const ValueKey('ride-offer'),
              color: t.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${offer.name ?? 'A driver'} offers ${formatMoney(offer.amount, r.currency)}',
                      style: t.textTheme.titleMedium,
                    ),
                    Text(
                      [
                        offer.vehicle,
                        offer.plate,
                        if (offer.rating != null) '★ ${offer.rating!.toStringAsFixed(1)}',
                      ].whereType<String>().join(' · '),
                      style: t.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _busy ? null : () => _declineOffer(offer),
                            child: const Text('Decline'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            key: const ValueKey('accept-offer'),
                            onPressed: _busy ? null : () => _acceptOffer(offer),
                            child: Text('Accept ${formatMoney(offer.amount, r.currency)}'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (r.status == RideStatus.open)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('No takers yet? Raise your fare', style: t.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final step in fareRaiseSteps)
                          ActionChip(
                            key: ValueKey('raise-${step.toStringAsFixed(0)}'),
                            avatar: const Icon(Icons.arrow_upward, size: 16),
                            label: Text('+${formatMoney(step, r.currency)}'),
                            onPressed: _busy ? null : () => _raise(step),
                          ),
                      ],
                    ),
                    if (r.offerMe)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Drivers can also offer you a price. You choose whether to accept.',
                          style: t.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (r.partnerId != null && r.status.isOngoing)
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.person)),
                    title: Text(r.partnerName ?? 'Your driver'),
                    subtitle: Text([r.partnerVehicle, r.partnerPlate].whereType<String>().join(' · ')),
                    trailing: r.partnerRating == null
                        ? null
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.star, size: 18, color: Colors.amber),
                              Text(r.partnerRating!.toStringAsFixed(1)),
                            ],
                          ),
                  ),
                  if (r.otp != null && r.status != RideStatus.onTrip)
                    ListTile(
                      leading: const Icon(Icons.pin_outlined),
                      title: const Text('Trip code'),
                      subtitle: const Text('Share with your driver at pickup'),
                      trailing: Text(r.otp!, style: t.textTheme.headlineSmall?.copyWith(letterSpacing: 4)),
                    ),
                  if (r.partnerPhone != null)
                    OverflowBar(
                      children: [
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
                      ],
                    ),
                ],
              ),
            ),
          if (partnerCancelAsk && r.status.isOngoing)
            Card(
              color: t.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Your driver asked to cancel this ride.'),
                    const SizedBox(height: 8),
                    Row(
                      children: [
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
                      ],
                    ),
                  ],
                ),
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
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.trip_origin, color: Colors.green.shade700),
                  title: Text(r.pickupLabel),
                  subtitle: r.pickupAddress == null ? null : Text(r.pickupAddress!, maxLines: 2),
                ),
                RideStopTiles(stops: r.stops),
                ListTile(
                  leading: Icon(Icons.location_on, color: Colors.red.shade700),
                  title: Text(r.dropLabel),
                  subtitle: r.dropAddress == null ? null : Text(r.dropAddress!, maxLines: 2),
                ),
                const Divider(height: 1),
                ListTile(
                  title: Text(r.service ?? 'Ride'),
                  subtitle: Text(
                    '${formatDistance(r.distanceKm)} · ${formatDuration(r.durationMin)} · ${r.paymentMode}',
                  ),
                  trailing: Text(
                    formatMoney(r.effectiveFare, r.currency),
                    style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (r.status.isOngoing && r.status != RideStatus.open)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FilledButton.icon(
                key: const ValueKey('ride-sos'),
                style: FilledButton.styleFrom(
                  backgroundColor: t.colorScheme.error,
                  foregroundColor: t.colorScheme.onError,
                ),
                icon: const Icon(Icons.sos),
                label: const Text('SOS · Emergency'),
                onPressed: () => _sos(r),
              ),
            ),
          if (r.status.isOngoing && r.status != RideStatus.onTrip && !riderCancelAsk)
            OutlinedButton.icon(
              icon: const Icon(Icons.close),
              label: const Text('Cancel ride'),
              onPressed: _busy ? null : _cancel,
            ),
          if (r.status == RideStatus.completed &&
              ((r.tollCharges ?? 0) > 0 || (r.otherCharges ?? 0) > 0 || r.fareCoinsValue > 0))
            Card(
              key: const ValueKey('ride-charges'),
              child: Column(children: [
                ListTile(dense: true, title: const Text('Trip fare'),
                    trailing: Text(formatMoney(r.effectiveFare, r.currency))),
                if ((r.tollCharges ?? 0) > 0)
                  ListTile(dense: true, title: const Text('Tolls'),
                      trailing: Text(formatMoney(r.tollCharges, r.currency))),
                if ((r.otherCharges ?? 0) > 0)
                  ListTile(
                    dense: true,
                    title: const Text('Other charges'),
                    subtitle: r.otherChargesNote == null ? null : Text(r.otherChargesNote!),
                    trailing: Text(formatMoney(r.otherCharges, r.currency)),
                  ),
                if (r.fareCoinsValue > 0)
                  ListTile(dense: true, title: const Text('Paid with GET.coin'),
                      trailing: Text('−${formatMoney(r.fareCoinsValue, r.currency)}')),
                const Divider(height: 1),
                ListTile(
                  title: Text(r.fareCoinsValue > 0 ? 'Left to pay' : 'Total to pay',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  trailing: Text(formatMoney(r.cashDue, r.currency),
                      style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          if (_coinsChosen && r.status.isOngoing)
            const ListTile(
              key: ValueKey('coins-pending'),
              dense: true,
              leading: Icon(Icons.toll_outlined, color: Color(0xFFB8860B)),
              title: Text('GET.coin will be applied at drop-off'),
            ),
          if (_redeemed != null)
            Card(
              key: const ValueKey('coins-redeemed'),
              color: const Color(0xFFF5B301).withValues(alpha: 0.18),
              child: ListTile(
                leading: const Icon(Icons.toll_outlined, color: Color(0xFFB8860B)),
                title: Text('${formatMoney(_redeemed!.coinValue, r.currency)} paid with GET.coin'),
                subtitle: Text('${formatCoins(_redeemed!.coinsUsed)} used · pay the rest as usual'),
              ),
            ),
          if (_reward != null && _reward! > 0)
            Card(
              key: const ValueKey('ride-reward'),
              color: const Color(0xFFF5B301).withValues(alpha: 0.18),
              child: ListTile(
                leading: const Icon(Icons.toll_outlined, color: Color(0xFFB8860B)),
                title: Text('You earned ${formatCoins(_reward!)}'),
                subtitle: const Text('Ride reward, added to your GET.coin'),
              ),
            ),
          if (r.status.isFinished) FilledButton(onPressed: () => context.go('/'), child: const Text('Done')),
        ],
      ),
    );
  }
}
