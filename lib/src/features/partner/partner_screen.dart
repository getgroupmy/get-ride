import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/format.dart';
import '../../core/partner_onboarding.dart';
import '../../core/taxi_meter.dart';
import '../../data/geo_service.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import 'fare_offer.dart';
import 'vehicle_picker.dart';

final openRequestsProvider = StreamProvider.autoDispose<List<RideRequest>>(
  (ref) => ref.watch(rideRepositoryProvider).watchOpen(),
);

/// Partners whose record lets them take jobs.
bool partnerCanDrive(Partner p) {
  final s = p.status ?? '';
  return s == 'approved' || s.startsWith('permit-');
}

/// Driver mode: go online, see open requests live, accept one.
class PartnerScreen extends ConsumerStatefulWidget {
  const PartnerScreen({super.key});

  @override
  ConsumerState<PartnerScreen> createState() => _PartnerScreenState();
}

class _PartnerScreenState extends ConsumerState<PartnerScreen> {
  bool _online = false;
  LatLng? _me;
  String? _accepting;

  @override
  void initState() {
    super.initState();
    _resume();
  }

  Future<void> _resume() async {
    final trip = await ref.read(rideRepositoryProvider).ongoingForPartner().catchError((_) => null);
    if (trip != null && mounted) context.push('/drive/trip/${trip.id}');
  }

  Future<void> _toggle(bool v) async {
    setState(() => _online = v);
    if (v) {
      final p = await currentPosition();
      if (mounted) setState(() => _me = p);
    }
  }

  Future<void> _accept(RideRequest r, Partner partner) async {
    setState(() => _accepting = r.id);
    try {
      final profile = await ref.read(profileProvider.future);
      final won = await ref.read(rideRepositoryProvider).accept(
            r.id,
            partner,
            lat: _me?.latitude,
            lng: _me?.longitude,
            fallbackName: profile?.name,
            fallbackPhone: profile?.phone,
          );
      if (!mounted) return;
      if (won == null) {
        showInfo(context, 'Another driver already took this request.');
      } else {
        context.push('/drive/trip/${won.id}');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _accepting = null);
    }
  }

  Future<void> _offer(RideRequest r, Partner partner) async {
    final amount = await askCounterOffer(context, r);
    if (amount == null || !mounted) return;
    setState(() => _accepting = r.id);
    final repo = ref.read(rideRepositoryProvider);
    RideRequest? sent;
    try {
      final profile = await ref.read(profileProvider.future);
      sent = await repo.submitOffer(
        r.id,
        amount,
        partner,
        lat: _me?.latitude,
        lng: _me?.longitude,
        fallbackName: profile?.name,
        fallbackPhone: profile?.phone,
      );
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    } finally {
      if (mounted) setState(() => _accepting = null);
    }
    if (!mounted) return;
    if (sent == null) {
      showInfo(context, 'This request is no longer open.');
      return;
    }
    final me = ref.read(currentUserIdProvider);
    if (me == null) return;
    final won = await showDialog<RideRequest>(
      context: context,
      barrierDismissible: false,
      builder: (_) => OfferPendingDialog(repo: repo, ride: r, me: me, amount: amount),
    );
    if (won != null && mounted) context.push('/drive/trip/${won.id}');
  }

  double? _distanceTo(RideRequest r) {
    if (_me == null || r.pickupLat == null || r.pickupLng == null) return null;
    return const Distance().as(LengthUnit.Meter, _me!, LatLng(r.pickupLat!, r.pickupLng!)) / 1000;
  }

  @override
  Widget build(BuildContext context) {
    final partner = ref.watch(partnerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Drive'), actions: [
        if (partner.value != null && partnerCanDrive(partner.value!) && hasTeksiPartnerType(partner.value!.raw['partner_types']))
          IconButton(
            tooltip: 'Meter Digital',
            icon: const Icon(Icons.speed),
            onPressed: () => context.push('/meter'),
          ),
        if (partner.value != null)
          IconButton(
            tooltip: 'My vehicles',
            icon: const Icon(Icons.directions_car_outlined),
            onPressed: () => context.push('/drive/vehicles'),
          ),
      ]),
      body: AsyncView(
        value: partner,
        onRetry: () => ref.invalidate(partnerProvider),
        data: (p) {
          void openOnboarding() => context.push('/drive/onboarding');
          if (p == null) {
            return EmptyState(
              icon: Icons.badge_outlined,
              title: 'Become a GET.ride partner',
              message: 'Earn by driving with GET.ride. Add your details and documents, and you can take jobs '
                  'here once an admin approves your account.',
              action: FilledButton(onPressed: openOnboarding, child: const Text('Get started')),
            );
          }
          if (!partnerCanDrive(p)) {
            if (partnerSetupIncomplete(p.raw)) {
              return EmptyState(
                icon: Icons.assignment_outlined,
                title: 'Finish your partner application',
                message: 'A few steps are still missing before an admin can review your account.',
                action: FilledButton(onPressed: openOnboarding, child: const Text('Continue')),
              );
            }
            return EmptyState(
              icon: Icons.hourglass_empty,
              title: 'Account not active yet',
              message: 'Your partner status is "${p.status ?? 'unknown'}". '
                  'You can go online once an admin approves your account.',
              action: OutlinedButton(onPressed: openOnboarding, child: const Text('View application')),
            );
          }
          return ResponsiveCenter(
            maxWidth: 760,
            child: Column(children: [
              Card(
                child: SwitchListTile(
                  value: _online,
                  onChanged: _toggle,
                  secondary: Icon(_online ? Icons.wifi_tethering : Icons.wifi_tethering_off),
                  title: Text(_online ? 'You are online' : 'You are offline'),
                  subtitle: Text([p.name, p.vehicle, p.plate].whereType<String>().join(' · ')),
                ),
              ),
              const CurrentVehicleCard(),
              Expanded(child: _online ? _queue(p) : const EmptyState(
                icon: Icons.local_taxi_outlined,
                title: 'Go online to receive ride requests',
              )),
            ]),
          );
        },
      ),
    );
  }

  Widget _queue(Partner partner) {
    final t = Theme.of(context);
    return AsyncView(
      value: ref.watch(openRequestsProvider),
      onRetry: () => ref.invalidate(openRequestsProvider),
      data: (list) {
        if (list.isEmpty) {
          return const EmptyState(icon: Icons.radar, title: 'Waiting for requests…', message: 'New requests appear here instantly.');
        }
        final sorted = [...list]
          ..sort((a, b) => (_distanceTo(a) ?? 1e9).compareTo(_distanceTo(b) ?? 1e9));
        return ListView.builder(
          itemCount: sorted.length,
          itemBuilder: (_, i) {
            final r = sorted[i];
            final away = _distanceTo(r);
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(child: Text(r.service ?? 'Ride', style: t.textTheme.titleMedium)),
                    Text(formatMoney(r.effectiveFare, r.currency),
                        style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  ]),
                  const SizedBox(height: 4),
                  Text([
                    if (away != null) '${formatDistance(away)} away',
                    '${formatDistance(r.distanceKm)} trip',
                    r.paymentMode,
                    '${r.passengers} pax',
                  ].join(' · '), style: t.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Row(children: [
                    Icon(Icons.trip_origin, size: 16, color: Colors.green.shade700),
                    const SizedBox(width: 8),
                    Expanded(child: Text(r.pickupLabel, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
                  Row(children: [
                    Icon(Icons.location_on, size: 16, color: Colors.red.shade700),
                    const SizedBox(width: 8),
                    Expanded(child: Text(r.dropLabel, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
                  if (r.note != null) Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('“${r.note}”', style: t.textTheme.bodySmall),
                  ),
                  if (r.offeredFare != null && r.partnerId != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('A driver has offered ${formatMoney(r.offeredFare, r.currency)}',
                          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.primary)),
                    ),
                  const SizedBox(height: 8),
                  Row(children: [
                    if (r.offerMe) ...[
                      Expanded(
                        child: OutlinedButton(
                          key: ValueKey('offer-${r.id}'),
                          onPressed: _accepting != null ? null : () => _offer(r, partner),
                          child: const Text('Offer price'),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: FilledButton(
                        onPressed: _accepting != null ? null : () => _accept(r, partner),
                        child: _accepting == r.id
                            ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text('Accept ${formatMoney(r.effectiveFare, r.currency)}'),
                      ),
                    ),
                  ]),
                ]),
              ),
            );
          },
        );
      },
    );
  }
}
