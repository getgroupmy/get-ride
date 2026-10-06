import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/destination_mode.dart';
import '../../core/format.dart';
import '../../core/partner_doc_check.dart';
import '../../core/partner_onboarding.dart';
import '../../core/partner_queue.dart';
import '../../core/taxi_meter.dart';
import '../../data/destination_store.dart';
import '../../data/device_access.dart';
import '../../data/geo_service.dart';
import '../../data/models.dart';
import '../../data/partner_doc_check.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../ride/place_search.dart';
import '../ride/demo_ride.dart';
import 'demo_jobs.dart';
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
  bool _autoAccept = false;
  bool _allowOfferMe = true;

  /// Requests auto-accept must not take: those already queued when it was
  /// switched on (or when going online with it on), and those it has tried.
  final _seen = <String>{};

  @override
  void initState() {
    super.initState();
    _resume();
  }

  Future<void> _resume() async {
    final trip = await ref.read(rideRepositoryProvider).ongoingForPartner().catchError((_) => null);
    if (trip != null && mounted) context.push('/drive/trip/${trip.id}');
  }

  void _markQueueSeen() {
    _seen.addAll(ref.read(openRequestsProvider).value?.map((r) => r.id) ?? const <String>[]);
  }

  void _setAutoAccept(bool v) {
    if (v) _markQueueSeen();
    setState(() => _autoAccept = v);
  }

  /// Takes the nearest request that arrived since auto-accept went on.
  void _maybeAutoAccept(List<RideRequest> open) {
    if (!_online || !_autoAccept || !mounted) return;
    final partner = ref.read(partnerProvider).value;
    if (partner == null || !partnerCanDrive(partner)) return;
    // In destination mode only trips heading that way are taken unasked.
    final eligible = _destinationOn ? open.where(_towardDestination).toList() : open;
    final pick = autoAcceptPick(
      [for (final r in eligible) (id: r.id, offerMe: r.offerMe, awayKm: _distanceTo(r))],
      _seen,
      busy: _accepting != null,
    );
    if (pick == null) return;
    _seen.add(pick);
    _accept(open.firstWhere((r) => r.id == pick), partner);
  }

  Future<void> _toggle(bool v) async {
    if (v && await ref.read(deviceBlockedProvider.future)) {
      if (mounted) showInfo(context, '$serviceNotAvailable. This device cannot go online.');
      return;
    }
    if (v) {
      final partner = ref.read(partnerProvider).value;
      if (partner != null && !await _documentsCleared(partner, teksi: false)) return;
      if (!mounted) return;
    }
    if (v && _autoAccept) _markQueueSeen();
    setState(() => _online = v);
    if (v) {
      final p = await currentPosition();
      if (mounted) setState(() => _me = p);
    }
  }

  /// Expo's check before a service mode: compulsory documents that are
  /// missing, rejected or expired keep the partner offline, with a way to
  /// update them. When the documents cannot be read it lets them through, as
  /// Expo did, rather than locking a driver out over a network error.
  Future<bool> _documentsCleared(Partner partner, {required bool teksi}) async {
    List<DocIssue> blocking;
    try {
      blocking = blockingDocIssues(await ref.read(partnerDocCheckProvider)(partner.raw, teksi: teksi));
    } catch (_) {
      return true;
    }
    if (blocking.isEmpty) return true;
    if (!mounted) return false;
    final update = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('docs-blocked'),
        title: const Text('Update required documents'),
        content: Text(
          'Before you can ${teksi ? 'start the meter' : 'go online'}, please update the following:\n\n'
          '${summarizeDocIssues(blocking)}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          FilledButton(
            key: const ValueKey('docs-update'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Update documents'),
          ),
        ],
      ),
    );
    if (update == true && mounted) context.push('/drive/onboarding');
    return false;
  }

  Future<void> _openMeter(Partner partner) async {
    if (!await _documentsCleared(partner, teksi: true)) return;
    if (mounted) context.push('/meter');
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

  bool get _destinationOn {
    final d = ref.read(destinationModeProvider);
    return d.on && d.place != null;
  }

  bool _towardDestination(RideRequest r) {
    final dest = ref.read(destinationModeProvider).place;
    if (dest == null || r.pickupLat == null || r.pickupLng == null || r.dropLat == null || r.dropLng == null) {
      return false;
    }
    return headsToward(
      pickup: LatLng(r.pickupLat!, r.pickupLng!),
      drop: LatLng(r.dropLat!, r.dropLng!),
      destination: dest.point,
    );
  }

  Future<void> _chooseDestination() async {
    final pick = await showPlaceSearch(context, title: 'Your destination', near: _me);
    final place = pick?.place;
    if (place != null) await ref.read(destinationModeProvider.notifier).setPlace(place);
  }

  Widget _destinationTile() {
    final d = ref.watch(destinationModeProvider);
    final place = d.place;
    return ListTile(
      key: const ValueKey('queue-destination'),
      leading: const Icon(Icons.flag_outlined),
      title: Text(place == null ? 'Destination mode' : 'Heading to ${place.name}'),
      subtitle: Text(place == null
          ? 'Set where you are heading to see trips that way first'
          : d.on
              ? 'Trips toward it come first; auto-accept takes only those'
              : 'Off. Tap to change the destination'),
      onTap: _chooseDestination,
      trailing: Switch(
        key: const ValueKey('queue-destination-switch'),
        value: d.on && place != null,
        onChanged: place == null ? null : (v) => ref.read(destinationModeProvider.notifier).setOn(v),
      ),
    );
  }

  double? _distanceTo(RideRequest r) {
    if (_me == null || r.pickupLat == null || r.pickupLng == null) return null;
    return const Distance().as(LengthUnit.Meter, _me!, LatLng(r.pickupLat!, r.pickupLng!)) / 1000;
  }

  @override
  Widget build(BuildContext context) {
    final partner = ref.watch(partnerProvider);
    ref.listen(openRequestsProvider, (_, next) {
      final open = next.value;
      if (open != null) _maybeAutoAccept(open);
    });
    return Scaffold(
      appBar: AppBar(title: const Text('Drive'), actions: [
        if (partner.value != null && hasTeksiPartnerType(partner.value!.raw['partner_types']))
          IconButton(
            tooltip: 'Driver permit',
            icon: const Icon(Icons.badge_outlined),
            onPressed: () => context.push('/drive/permit'),
          ),
        if (partner.value != null && partnerCanDrive(partner.value!) && hasTeksiPartnerType(partner.value!.raw['partner_types']))
          IconButton(
            tooltip: 'Meter Digital',
            icon: const Icon(Icons.speed),
            onPressed: () => _openMeter(partner.value!),
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
              if (_online)
                Card(
                  child: Column(children: [
                    SwitchListTile(
                      key: const ValueKey('queue-auto-accept'),
                      value: _autoAccept,
                      onChanged: _setAutoAccept,
                      secondary: const Icon(Icons.flash_auto),
                      title: const Text('Auto-accept'),
                      subtitle: Text(_autoAccept
                          ? 'Accepting new requests automatically, nearest first'
                          : 'Manually review each request'),
                    ),
                    SwitchListTile(
                      key: const ValueKey('queue-allow-offer'),
                      value: _allowOfferMe,
                      onChanged: (v) => setState(() => _allowOfferMe = v),
                      secondary: const Icon(Icons.gavel),
                      title: const Text('Allow OfferMe requests'),
                      subtitle: Text(_allowOfferMe
                          ? 'You can offer your own price where the rider allows it'
                          : 'Take requests at the rider\'s price only'),
                    ),
                    _destinationTile(),
                  ]),
                ),
              const CurrentVehicleCard(),
              if (_online && ref.watch(demoSettingsProvider).partnerRequests) const DemoJobFeed(),
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
        ref.watch(destinationModeProvider);
        final destinationOn = _destinationOn;
        final sorted = destinationOrder(
          list,
          toward: (r) => destinationOn && _towardDestination(r),
          awayKm: _distanceTo,
        );
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
                  if (destinationOn && _towardDestination(r))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(children: [
                        Icon(Icons.flag, size: 16, color: t.colorScheme.primary),
                        const SizedBox(width: 6),
                        Text('Toward your destination',
                            key: ValueKey('toward-${r.id}'),
                            style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.primary)),
                      ]),
                    ),
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
                  if (r.stops.isNotEmpty)
                    Row(key: ValueKey('queue-stops-${r.id}'), children: [
                      Icon(Icons.more_vert, size: 16, color: Colors.orange.shade800),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${r.stops.length} stop${r.stops.length == 1 ? '' : 's'} on the way',
                          style: t.textTheme.bodySmall,
                        ),
                      ),
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
                    if (canCounterOffer(requestOfferMe: r.offerMe, allowOfferMe: _allowOfferMe)) ...[
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
