import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/destination_mode.dart';
import '../../core/driver_permit.dart';
import '../../core/format.dart';
import '../../core/partner_doc_check.dart';
import '../../core/partner_onboarding.dart';
import '../../core/partner_queue.dart';
import '../../core/request_alert.dart';
import '../../core/taxi_meter.dart';
import '../../data/destination_store.dart';
import '../../data/device_access.dart';
import '../../data/geo_service.dart';
import '../../data/models.dart';
import '../../data/partner_doc_check.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/fly_in_list.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/ride_map.dart' show mapAttributionClearance;
import '../ride/place_search.dart';
import '../ride/demo_ride.dart';
import 'demo_jobs.dart';
import 'driver_home_map.dart';
import 'driver_online.dart';
import 'driver_permit_screen.dart' show currentPlateProvider, driverPermitProvider, showPermitBlock;
import 'driver_wallet_pills.dart';
import 'fare_offer.dart';
import 'partner_menu.dart';
import 'partner_mode_picker.dart' show pendingPartnerModeProvider;
import 'request_sheet.dart';
import 'vehicle_picker.dart';
import '../../core/partner_modes.dart';
import '../../core/vehicle_assignment.dart';
import '../../data/vehicle_assignment_repository.dart';
import '../../admin/screens/people/people_logic.dart' show parseStringList;
import '../../widgets/side_menu_host.dart';
import '../../widgets/net_image.dart';

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

/// The driver's position for the home map and request distances
/// (overridden in tests).
final driverPositionProvider = Provider<Future<LatLng?> Function()>((ref) => currentPosition);

/// The driver's position as it changes, so the home map follows them.
/// Empty when location is unavailable or refused.
final driverPositionStreamProvider = Provider<Stream<LatLng> Function()>((ref) => () async* {
  try {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
    yield* Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
    ).map((p) => LatLng(p.latitude, p.longitude));
  } catch (_) {}
});

/// The clock the request alert's countdown reads (overridden in tests).
final requestAlertClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

class _PartnerScreenState extends ConsumerState<PartnerScreen> {
  bool _online = false;
  late final DriverOnline _onlineState;
  LatLng? _me;
  StreamSubscription<LatLng>? _fixes;
  String? _accepting;
  bool _autoAccept = false;
  bool _allowOfferMe = true;

  /// The request whose pin was tapped on the map, shown first in the queue.
  String? _focusId;

  /// Requests auto-accept must not take: those already queued when it was
  /// switched on (or when going online with it on), and those it has tried.
  final _seen = <String>{};

  /// The incoming-request alert (Expo's request modal): the request being
  /// spotlighted, since when, those already spotlighted, and those the
  /// driver declined (gone from the queue on this device).
  String? _alertId;
  DateTime? _alertAt;
  final _alertSeen = <String>{};
  final _hidden = <String>{};

  /// The fare each declined request asked when it was declined; a raise
  /// over it brings the request back (Expo). [_raisedFrom] keeps the old fare
  /// of those brought back, for the alert's "was" line.
  final _declinedFare = <String, double>{};
  final _raisedFrom = <String, double>{};
  Timer? _alertTick;
  late DateTime _alertNow = ref.read(requestAlertClockProvider)();

  @override
  void dispose() {
    _fixes?.cancel();
    _alertTick?.cancel();
    // Leaving the Drive screen (signing out) takes the driver offline.
    final online = _onlineState;
    Future.microtask(() => online.set(false));
    super.dispose();
  }

  /// Spotlights the next new request, or clears the alert when there is
  /// none (offline, auto-accept on, or nothing new).
  void _syncAlert(List<RideRequest> open) {
    if (!mounted) return;
    for (final id in raisedAfterDecline(_declinedFare, [for (final r in open) (id: r.id, fare: r.effectiveFare)])) {
      _raisedFrom[id] = _declinedFare.remove(id)!;
      _hidden.remove(id);
      _alertSeen.remove(id);
    }
    String? next;
    if (_online && !_autoAccept) {
      final ordered = destinationOrder(open, toward: (r) => _destinationOn && _towardDestination(r), awayKm: _distanceTo);
      next = nextRequestAlert(
        openIds: [for (final r in ordered) r.id],
        seen: _alertSeen,
        hidden: _hidden,
        current: _alertId,
      );
    }
    if (next == _alertId) return;
    setState(() {
      _alertId = next;
      _alertAt = _alertNow = ref.read(requestAlertClockProvider)();
    });
    if (next != null) {
      _alertSeen.add(next);
      unawaited(HapticFeedback.heavyImpact());
      unawaited(SystemSound.play(SystemSoundType.alert));
      _alertTick ??= Timer.periodic(const Duration(seconds: 1), (_) => _onAlertTick());
    } else {
      _alertTick?.cancel();
      _alertTick = null;
    }
  }

  /// A request on the queue tapped: it comes up in the request sheet
  /// (inDrive's), with a fresh countdown, as a new one would.
  void _openRequest(RideRequest r) {
    if (_accepting != null) return;
    _alertSeen.add(r.id);
    setState(() {
      _alertId = r.id;
      _alertAt = _alertNow = ref.read(requestAlertClockProvider)();
    });
    _alertTick ??= Timer.periodic(const Duration(seconds: 1), (_) => _onAlertTick());
  }

  void _onAlertTick() {
    if (!mounted || _alertAt == null) return;
    setState(() => _alertNow = ref.read(requestAlertClockProvider)());
    // Left alone, the request drops back into the queue below.
    if (requestAlertExpired(_alertNow.difference(_alertAt!))) _dismissAlert(hide: false);
  }

  /// Ends the spotlight: a decline also takes the request off this
  /// driver's queue; a timeout leaves it there.
  void _dismissAlert({required bool hide}) {
    final id = _alertId;
    if (id == null) return;
    if (hide) {
      _hidden.add(id);
      final fare = (ref.read(openRequestsProvider).value ?? const <RideRequest>[])
          .where((r) => r.id == id)
          .firstOrNull
          ?.effectiveFare;
      if (fare != null) _declinedFare[id] = fare;
    }
    setState(() => _alertId = null);
    _syncAlert(ref.read(openRequestsProvider).value ?? const []);
  }

  @override
  void initState() {
    super.initState();
    _onlineState = ref.read(driverOnlineProvider.notifier);
    _resume();
    _locate();
    // Live: the map follows the driver as they move.
    _fixes = ref.read(driverPositionStreamProvider)().listen((p) {
      if (mounted) setState(() => _me = p);
    }, onError: (_) {});
  }

  Future<void> _locate() async {
    final p = await ref.read(driverPositionProvider)();
    if (p != null && mounted) setState(() => _me = p);
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
      if (partner != null && !await _vehicleReady(partner, teksi: false)) return;
      if (!mounted) return;
    }
    if (v && _autoAccept) _markQueueSeen();
    // Requests already waiting are in the list; only new ones pop up.
    if (v) _alertSeen.addAll(ref.read(openRequestsProvider).value?.map((r) => r.id) ?? const <String>[]);
    setState(() => _online = v);
    _onlineState.set(v);
    if (!v) _syncAlert(const []);
    if (v) unawaited(_locate());
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
    if (!mounted || !await _vehicleReady(partner, teksi: true)) return;
    if (!mounted || !await _permitCleared()) return;
    if (mounted) context.push('/meter');
  }

  /// The permit checks the Driver permit screen holds a hire to (Expo
  /// `attemptStartPickup`): IC matches the profile, not expired, and the
  /// vehicle driven is the one on the permit. When the permit cannot be read
  /// it lets the driver through, as the document check does.
  Future<bool> _permitCleared() async {
    // Both are auto-dispose: held open for the length of the check.
    final permitSub = ref.listenManual(driverPermitProvider.future, (_, _) {});
    final plateSub = ref.listenManual(currentPlateProvider.future, (_, _) {});
    final DriverPermit permit;
    final String? plate;
    try {
      permit = await permitSub.read();
      plate = await plateSub.read();
    } catch (_) {
      return true;
    } finally {
      permitSub.close();
      plateSub.close();
    }
    final block = permitStartBlock(permit, today: ref.read(requestAlertClockProvider)(), vehiclePlate: plate);
    if (block == null) return true;
    if (mounted) await showPermitBlock(context, block, permit, plate);
    return false;
  }

  /// Admin → Partner Type → Vehicle required (Expo `isVehicleRequiredForMode`):
  /// a mode that needs a vehicle starts only once the driver has taken one.
  /// When the catalogue or the vehicles cannot be read it lets them through,
  /// as the document check does.
  Future<bool> _vehicleReady(Partner partner, {required bool teksi}) async {
    List<AssignableVehicle> vehicles;
    bool required;
    try {
      final entries = await ref.read(partnerTypeEntriesProvider.future);
      final modes = [
        for (final m in partnerModeOptions(parseStringList(partner.raw['partner_types']), entries))
          if (m.isTeksi == teksi) m.name,
      ];
      required = (modes.isEmpty ? [teksi ? 'teksi' : 'ehailing'] : modes).any((m) => vehicleRequiredFor(m, entries));
      if (!required) return true;
      vehicles = await ref.read(assignableVehiclesProvider.future);
    } catch (_) {
      return true;
    }
    if (vehicles.any((v) => v.inUseByMe)) return true;
    if (!mounted) return false;
    final usable = vehicles.where((v) => v.selectable).toList();
    final choose = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        key: const ValueKey('vehicle-required'),
        title: const Text('Choose a vehicle'),
        content: Text(usable.isEmpty
            ? 'You need a vehicle before you can ${teksi ? 'start the meter' : 'go online'}. Add the vehicle you drive.'
            : 'You need a vehicle before you can ${teksi ? 'start the meter' : 'go online'}. Pick the one you are driving.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(c, true),
            child: Text(usable.isEmpty ? 'Add a vehicle' : 'Choose vehicle'),
          ),
        ],
      ),
    );
    if (choose != true || !mounted) return false;
    if (usable.isEmpty) {
      context.push('/drive/vehicles/new');
      return false;
    }
    final picked = await showModalBottomSheet<AssignableVehicle>(
      context: context,
      isScrollControlled: true,
      builder: (_) => VehiclePickerSheet(vehicles: vehicles),
    );
    if (picked == null || !mounted) return false;
    if (picked.inUseByMe) return true;
    try {
      await ref.read(vehicleAssignmentRepositoryProvider).claim(picked.id);
      ref.invalidate(assignableVehiclesProvider);
      return true;
    } catch (e) {
      if (mounted) showInfo(context, claimVehicleErrorMessage(e));
      return false;
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

  /// A counter-offer on [r]: [preset] when one was tapped, else the amount
  /// the driver types.
  Future<void> _offer(RideRequest r, Partner partner, {double? preset}) async {
    final amount = preset ?? await askCounterOffer(context, r);
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

  Future<void> _addDestination() async {
    final pick = await showPlaceSearch(context, title: 'Your destination', near: _me);
    final place = pick?.place;
    if (place != null) await ref.read(destinationModeProvider.notifier).setPlace(place);
  }

  /// The saved destinations (Expo's destination sheet): pick the one being
  /// headed to, forget one, or add another while there is room. With none
  /// saved yet it goes straight to the search.
  Future<void> _chooseDestination() async {
    if (ref.read(destinationModeProvider).saved.isEmpty) return _addDestination();
    final add = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => Consumer(
        builder: (context, ref, _) {
          final d = ref.watch(destinationModeProvider);
          final notifier = ref.read(destinationModeProvider.notifier);
          bool active(Place p) => d.on && d.place != null && samePlace(d.place!, p);
          return SafeArea(
            child: Column(
              key: const ValueKey('destination-sheet'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ListTile(
                  title: Text('Your destinations'),
                  subtitle: Text("Save up to $maxSavedDestinations. Requests heading to the one you pick come first."),
                ),
                for (final (i, p) in d.saved.indexed)
                  ListTile(
                    key: ValueKey('destination-$i'),
                    leading: Icon(active(p) ? Icons.flag : Icons.outlined_flag,
                        color: active(p) ? Theme.of(context).colorScheme.primary : null),
                    title: Text(p.name),
                    subtitle: p.address.isEmpty ? null : Text(p.address, maxLines: 1, overflow: TextOverflow.ellipsis),
                    selected: active(p),
                    onTap: () => notifier.select(p),
                    trailing: BusyIconButton(
                      key: ValueKey('destination-remove-$i'),
                      tooltip: 'Remove',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => notifier.remove(p),
                    ),
                  ),
                if (d.saved.length < maxSavedDestinations)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: OutlinedButton.icon(
                      key: const ValueKey('destination-add'),
                      icon: const Icon(Icons.add_location_alt_outlined),
                      label: const Text('Add destination'),
                      onPressed: () => Navigator.pop(sheet, true),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
    if (add == true && mounted) await _addDestination();
  }

  Widget _destinationTile() {
    final d = ref.watch(destinationModeProvider);
    final place = d.place;
    return BusyListTile(
      key: const ValueKey('queue-destination'),
      leading: const Icon(Icons.flag_outlined),
      title: Text(place == null ? 'Destination mode' : 'Heading to ${place.name}'),
      subtitle: Text(place == null
          ? (d.saved.isEmpty
              ? 'Set where you are heading to see trips that way first'
              : '${d.saved.length} saved. Tap to pick where you are heading')
          : d.on
              ? 'Trips toward it come first; auto-accept takes only those'
              : 'Off. Tap to change the destination'),
      onTap: _chooseDestination,
      trailing: BusySwitch(
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
      if (open != null) {
        _maybeAutoAccept(open);
        _syncAlert(open);
      }
    });
    return Scaffold(
      // No top bar: the page's buttons float over it, top right.
      body: Stack(children: [
        Positioned.fill(
          child: SafeArea(
            bottom: false,
            child: AsyncView(
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
                // The service picked from the rider menu's Partner Mode button:
                // TEKSI goes on to the meter, through its checks.
                if (ref.watch(pendingPartnerModeProvider) != null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    final mode = ref.read(pendingPartnerModeProvider.notifier).take();
                    if (mode != null && mode.isTeksi) _openMeter(p);
                  });
                }
                final modes = partnerModeOptions(
                  parseStringList(p.raw['partner_types']),
                  ref.watch(partnerTypeEntriesProvider).value ?? const [],
                );
                final wide = MediaQuery.sizeOf(context).width >= 900;
                final map = DriverHomeMap(
                  key: const ValueKey('driver-home-map'),
                  me: _me,
                  requests: _online ? _pinned(ref.watch(openRequestsProvider).value ?? const []) : const [],
                  onSelect: (r) => setState(() => _focusId = r.id),
                );
                final head = <Widget>[
                    // Online first, above the service types.
                    Card(
                      key: const ValueKey('partner-online'),
                      child: BusySwitchListTile(
                        value: _online,
                        onChanged: _toggle,
                        secondary: Icon(_online ? Icons.wifi_tethering : Icons.wifi_tethering_off),
                        title: Text(_online ? 'You are online' : 'You are offline'),
                        subtitle: Text(
                          [p.name, p.vehicle, p.plate].whereType<String>().where((s) => s.trim().isNotEmpty).join(' · '),
                        ),
                      ),
                    ),
                    if (modes.length > 1 || modes.any((m) => m.isTeksi))
                      Card(
                        key: const ValueKey('partner-modes'),
                        child: Column(children: [
                          for (final m in modes)
                            BusyListTile(
                              key: ValueKey('partner-mode-${m.name}'),
                              leading: m.iconUrl == null
                                  ? Icon(m.isTeksi ? Icons.local_taxi : Icons.directions_car_outlined)
                                  : SizedBox.square(
                                      dimension: 36,
                                      child: Image.network(m.iconUrl!,
                                          frameBuilder: boneUntilPainted(),
                                          errorBuilder: (_, _, _) => const Icon(Icons.directions_car_outlined)),
                                    ),
                              title: Text(m.name),
                              subtitle: m.description == null ? null : Text(m.description!),
                              trailing: Icon(m.isTeksi ? Icons.speed : (_online ? Icons.check_circle : Icons.chevron_right)),
                              onTap: () => m.isTeksi ? _openMeter(p) : (_online ? null : _toggle(true)),
                            ),
                        ]),
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
                    const DriverWalletPills(),
                    const CurrentVehicleCard(),
                    if (_online && ref.watch(demoSettingsProvider).partnerRequests) const DemoJobFeed(),
                  ];
                const offline = EmptyState(icon: Icons.local_taxi_outlined, title: 'Go online to receive ride requests');
                if (wide) {
                  final panel = Column(children: [...head, Expanded(child: _online ? _queue(p, wide: true) : offline)]);
                  return Row(children: [
                    SizedBox(width: 520, child: panel),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: Stack(children: [
                        Positioned.fill(child: map),
                        // A new request flies in over the map on a desktop screen.
                        if (_online) Positioned(top: 16, right: 16, width: 400, child: _alertOverlay(p)),
                      ]),
                    ),
                  ]);
                }
                // A phone: the map fills the screen, the requests float on it and
                // the sheet holds the driver's settings. While there are requests
                // the sheet is held down so the list on the map has the room.
                final open = _online ? ref.watch(openRequestsProvider).value ?? const <RideRequest>[] : const <RideRequest>[];
                final queue = _queueOrder(open, wide: false);
                // The new request is the sheet up from the bottom, not a card here.
                final floating = queue.sorted;
                return MapSheetLayout(
                  // Fully down (just the online switch) until the driver
                  // drags it up.
                  initial: 0.2,
                  min: 0.2,
                  locked: floating.isNotEmpty,
                  map: Stack(children: [
                    Positioned.fill(child: map),
                    if (_online) _floatingRequests(p, null, floating),
                  ]),
                  // All the way down only the online switch shows.
                  peek: ResponsiveCenter(maxWidth: 760, child: head.first),
                  sheet: ResponsiveCenter(
                    maxWidth: 760,
                    child: Column(children: [...head.skip(1), if (!_online) offline]),
                  ),
                );
              },
            ),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
              child: Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: [
                if (partner.value != null && hasTeksiPartnerType(partner.value!.raw['partner_types']))
                  _floatingButton(
                    tooltip: 'Driver permit',
                    icon: Icons.badge_outlined,
                    onPressed: () {
                      context.push('/drive/permit');
                    },
                  ),
                if (partner.value != null &&
                    partnerCanDrive(partner.value!) &&
                    hasTeksiPartnerType(partner.value!.raw['partner_types']))
                  _floatingButton(
                    tooltip: 'Meter Digital',
                    icon: Icons.speed,
                    onPressed: () => _openMeter(partner.value!),
                  ),
                if (partner.value != null)
                  _floatingButton(
                    tooltip: 'My vehicles',
                    icon: Icons.directions_car_outlined,
                    onPressed: () {
                      context.push('/drive/vehicles');
                    },
                  ),
              ]),
            ),
          ),
        ),
        // The menu: top left, exactly where the home map has it.
        Positioned(
          left: 16,
          top: 16,
          child: SafeArea(
            child: FloatingActionButton.small(
              key: const ValueKey('partner-menu-button'),
              heroTag: 'partner-menu',
              tooltip: 'Menu',
              onPressed: () {
                // The side menu on phones; a sheet where there is none.
                final menu = SideMenuHost.of(context);
                menu == null ? showPartnerMenu(context) : menu.open();
              },
              child: const Icon(Icons.menu),
            ),
          ),
        ),
        // A new request on a phone: inDrive's sheet up from the bottom, over
        // everything (the desktop has it over the map instead).
        if (partner.value case final p? when _online && MediaQuery.sizeOf(context).width < 900)
          Positioned.fill(child: _requestSheet(p)),
      ]),
    );
  }

  /// The new request on a phone ([RideRequestSheet]): up from the bottom
  /// over a dimmed page, and back down when it is answered, taken or times
  /// out.
  Widget _requestSheet(Partner partner) {
    final list = ref.watch(openRequestsProvider).value ?? const <RideRequest>[];
    final r = list.where((r) => r.id == _alertId).firstOrNull;
    return Stack(children: [
      IgnorePointer(
        child: AnimatedOpacity(
          opacity: r == null ? 0 : 1,
          duration: const Duration(milliseconds: 300),
          child: const ColoredBox(color: Colors.black54, child: SizedBox.expand()),
        ),
      ),
      Align(
        alignment: Alignment.bottomCenter,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(animation),
            child: child,
          ),
          child: r == null
              ? const SizedBox.shrink(key: ValueKey('no-request-sheet'))
              : RideRequestSheet(
                  key: ValueKey('request-sheet-${r.id}'),
                  request: r,
                  shown: _alertNow.difference(_alertAt ?? _alertNow),
                  now: _alertNow,
                  me: _me,
                  awayKm: _distanceTo(r),
                  raisedFrom: _raisedFrom[r.id],
                  towardDestination: _destinationOn && _towardDestination(r),
                  busy: _accepting != null,
                  onAccept: () => _accept(r, partner),
                  onSkip: () => _dismissAlert(hide: true),
                  onOffer: canCounterOffer(requestOfferMe: r.offerMe, allowOfferMe: _allowOfferMe)
                      ? (amount) => _offer(r, partner, preset: amount)
                      : null,
                ),
        ),
      ),
    ]);
  }

  /// One of the round buttons floating at the top of the page (in place of
  /// a top bar), like the map's own. One whose action does work (the Meter
  /// Digital checks) spins until it is done; opening a page or the menu is
  /// instant.
  Widget _floatingButton({Key? key, required String tooltip, required IconData icon, required BusyAction onPressed}) =>
      BusyFab(key: key, tooltip: tooltip, onPressed: onPressed, child: Icon(icon));

  /// The requests on this driver's queue (all open ones but those declined
  /// here), which are also the map's pins.
  List<RideRequest> _pinned(List<RideRequest> open) => [for (final r in open) if (!_hidden.contains(r.id)) r];

  /// The new request over the map (desktop): it flies in from the right and
  /// back out when it is accepted, declined, taken or times out.
  Widget _alertOverlay(Partner partner) {
    final list = ref.watch(openRequestsProvider).value ?? const <RideRequest>[];
    final alert = list.where((r) => r.id == _alertId).firstOrNull;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => SlideTransition(
        position: Tween(begin: const Offset(1.25, 0), end: Offset.zero).animate(animation),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: alert == null
          ? const SizedBox.shrink(key: ValueKey('no-alert'))
          : Material(
              key: ValueKey('alert-overlay-${alert.id}'),
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: _alertCard(alert, partner),
            ),
    );
  }

  /// [wide]: the new request is over the map ([_alertOverlay]), not here.
  /// The spotlighted request (none when [wide]: it is over the map) and the
  /// rest of the queue in the order the driver sees them.
  ({RideRequest? alert, List<RideRequest> sorted}) _queueOrder(List<RideRequest> list, {required bool wide}) {
    final alert = wide ? null : list.where((r) => r.id == _alertId).firstOrNull;
    final queued = [for (final r in _pinned(list)) if (r.id != _alertId) r];
    ref.watch(destinationModeProvider);
    final destinationOn = _destinationOn;
    final sorted = focusFirst(
      destinationOrder(queued, toward: (r) => destinationOn && _towardDestination(r), awayKm: _distanceTo),
      _focusId,
    );
    return (alert: alert, sorted: sorted);
  }

  /// The requests floating on the phone's map, flying in as they arrive and
  /// out as they go, scrolled up and down to pick one; a "waiting" pill
  /// while there are none.
  Widget _floatingRequests(Partner partner, RideRequest? alert, List<RideRequest> items) {
    final t = Theme.of(context);
    // Inside the map, so the list keeps clear of the sheet and the map
    // buttons; mounted even when empty, so the last card flies out too.
    return Positioned.fill(
      child: Builder(
        builder: (context) => Stack(children: [
          MapBottomInset.listen(
            context,
            (inset) => Positioned(
              key: const ValueKey('floating-requests'),
              // Below the page's floating buttons.
              top: 56,
              left: 12,
              right: 12,
              bottom: inset + mapAttributionClearance + 104,
              child: FlyInList<RideRequest>(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                items: items,
                idOf: (r) => r.id == alert?.id ? 'alert-${r.id}' : r.id,
                itemBuilder: (_, r) => r.id == alert?.id ? _alertCard(r, partner) : _requestCard(r, partner),
              ),
            ),
          ),
          if (items.isEmpty)
            Positioned(
              top: 64,
              left: 0,
              right: 0,
              child: Center(
                child: Material(
                  key: const ValueKey('waiting-for-requests'),
                  elevation: 4,
                  borderRadius: BorderRadius.circular(24),
                  color: t.colorScheme.surface,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.radar, size: 18),
                      SizedBox(width: 8),
                      Text('Waiting for requests…', style: TextStyle(fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  /// The queue as a list (the wide layout's panel).
  Widget _queue(Partner partner, {bool wide = false}) {
    return AsyncView(
      value: ref.watch(openRequestsProvider),
      onRetry: () => ref.invalidate(openRequestsProvider),
      data: (list) {
        final (:alert, :sorted) = _queueOrder(list, wide: wide);
        if (alert == null && sorted.isEmpty) {
          return const EmptyState(icon: Icons.radar, title: 'Waiting for requests…', message: 'New requests appear here instantly.');
        }
        return ListView.builder(
          itemCount: sorted.length + (alert == null ? 0 : 1),
          itemBuilder: (_, index) {
            if (alert != null && index == 0) return _alertCard(alert, partner);
            return _requestCard(sorted[alert == null ? index : index - 1], partner);
          },
        );
      },
    );
  }

  /// One request on the queue: the trip, its fare, and accept / offer.
  Widget _requestCard(RideRequest r, Partner partner) {
    final t = Theme.of(context);
    final destinationOn = _destinationOn;
    final away = _distanceTo(r);
    final focused = r.id == _focusId;
    return Card(
      key: ValueKey('queue-${r.id}'),
      clipBehavior: Clip.antiAlias,
      shape: focused
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: t.colorScheme.primary, width: 2),
            )
          : null,
      // Tapped (anywhere but its buttons): the request sheet, to look it
      // over on the map before answering.
      child: InkWell(
        key: ValueKey('queue-open-${r.id}'),
        onTap: () => _openRequest(r),
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
                child: BusyButton.outlined(
                  key: ValueKey('offer-${r.id}'),
                  onPressed: _accepting != null ? null : () => _offer(r, partner),
                  child: const Text('Offer price'),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: BusyButton.filled(
                onPressed: _accepting != null ? null : () => _accept(r, partner),
                child: _accepting == r.id
                    ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text('Accept ${formatMoney(r.effectiveFare, r.currency)}', textAlign: TextAlign.center),
              ),
            ),
          ]),
        ]),
      ),
      ),
    );
  }

  /// The spotlighted request (Expo's incoming-request modal): who is asking,
  /// how far and how long to the pickup, the trip, and a countdown.
  Widget _alertCard(RideRequest r, Partner partner) {
    final t = Theme.of(context);
    final shown = _alertNow.difference(_alertAt ?? _alertNow);
    final away = _distanceTo(r);
    return Card(
      key: const ValueKey('request-alert'),
      color: t.colorScheme.primaryContainer,
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.notifications_active, color: t.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _raisedFrom.containsKey(r.id) ? 'Fare raised' : 'New request',
                key: const ValueKey('request-alert-title'),
                style: t.textTheme.titleMedium,
              ),
            ),
            Text('${requestAlertSecondsLeft(shown)} s', style: t.textTheme.labelLarge),
          ]),
          const SizedBox(height: 6),
          LinearProgressIndicator(key: const ValueKey('request-alert-countdown'), value: requestAlertProgress(shown)),
          if (_raisedFrom[r.id] case final was?)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'The passenger raised the fare from ${formatMoney(was, r.currency)} '
                'to ${formatMoney(r.effectiveFare, r.currency)}.',
                key: const ValueKey('request-alert-raised'),
                style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          if (_destinationOn && _towardDestination(r))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                Icon(Icons.flag, size: 16, color: t.colorScheme.primary),
                const SizedBox(width: 6),
                Text('Toward your destination',
                    key: ValueKey('toward-${r.id}'),
                    style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.primary)),
              ]),
            ),
          const SizedBox(height: 10),
          Row(children: [
            const CircleAvatar(radius: 20, child: Icon(Icons.person)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.passengerName, style: t.textTheme.titleSmall),
                if (r.isForOthers)
                  Text('Booked by ${r.riderName ?? 'another rider'}',
                      key: ValueKey('booked-by-${r.id}'), style: t.textTheme.bodySmall),
                Text(
                  [
                    if (r.riderRating != null) '★ ${r.riderRating!.toStringAsFixed(1)}',
                    if (away != null) '${formatDistance(away)} away',
                    if (away != null) '~${pickupMinutes(away)} min',
                  ].join(' · '),
                  style: t.textTheme.bodySmall,
                ),
              ]),
            ),
            Text(formatMoney(r.effectiveFare, r.currency),
                style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 10),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.trip_origin, color: Colors.green.shade700),
            title: Text(r.pickupLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: r.pickupAddress == null ? null : Text(r.pickupAddress!, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.location_on, color: Colors.red.shade700),
            title: Text(r.dropLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                '${formatDistance(r.distanceKm)} trip',
                if (r.durationMin != null) '${r.durationMin} min',
              ].join(' · '),
            ),
          ),
          Wrap(spacing: 6, runSpacing: 6, children: [
            Chip(label: Text(r.paymentMode), visualDensity: VisualDensity.compact),
            Chip(label: Text('${r.passengers} pax'), visualDensity: VisualDensity.compact),
            if ((r.luggage ?? 0) > 0)
              Chip(
                label: Text('${r.luggage} ${r.luggage == 1 ? 'bag' : 'bags'}'),
                visualDensity: VisualDensity.compact,
              ),
            if (r.stops.isNotEmpty)
              Chip(
                label: Text('${r.stops.length} stop${r.stops.length == 1 ? '' : 's'}'),
                visualDensity: VisualDensity.compact,
              ),
          ]),
          if (r.note != null) Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('“${r.note}”', style: t.textTheme.bodySmall),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                key: const ValueKey('request-alert-decline'),
                onPressed: _accepting != null ? null : () => _dismissAlert(hide: true),
                child: const Text('Decline'),
              ),
            ),
            if (canCounterOffer(requestOfferMe: r.offerMe, allowOfferMe: _allowOfferMe)) ...[
              const SizedBox(width: 8),
              Expanded(
                child: BusyButton.outlined(
                  key: ValueKey('offer-${r.id}'),
                  onPressed: _accepting != null ? null : () => _offer(r, partner),
                  child: const Text('Offer price'),
                ),
              ),
            ],
            const SizedBox(width: 8),
            Expanded(
              child: BusyButton.filled(
                key: const ValueKey('request-alert-accept'),
                onPressed: _accepting != null ? null : () => _accept(r, partner),
                child: _accepting == r.id
                    ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text('Accept ${formatMoney(r.effectiveFare, r.currency)}', textAlign: TextAlign.center),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
