import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../data/permits_repository.dart';
import '../../data/dispatch_repository.dart' show dispatchRepositoryProvider;
import '../../data/scheduled_ride_repository.dart';
import '../../data/active_location.dart';
import '../../core/destination_mode.dart';
import '../../core/driver_request_radius.dart';
import '../../core/my_ride.dart' show pinStarredFirst;
import '../../core/driver_permit.dart';
import '../../core/format.dart';
import '../../core/partner_doc_check.dart';
import '../../core/partner_queue.dart';
import '../../core/request_alert.dart';
import '../../core/taxi_meter.dart';
import '../../data/destination_store.dart';
import '../../data/device_access.dart';
import '../../data/geo_service.dart';
import '../../data/models.dart';
import '../../data/obd/obd_session.dart';
import '../../data/my_ride_repository.dart' show favouriteRiderIdsProvider, serviceDispatchConfigsProvider;
import '../../data/partner_doc_check.dart';
import '../../data/partner_type_check.dart';
import '../../core/partner_type_rules.dart' show PartnerTypeCheck, hailNotOfferedMessage;
import '../../providers.dart';
import '../../data/driver_presence.dart' show driverPresenceProvider;
import '../../core/ride_offers.dart';
import '../../data/city_ride_repository.dart';
import '../../core/rider_rating.dart';
import '../../widgets/rider_badge.dart';
import '../../widgets/offer_motion.dart';
import '../../widgets/place_type_badge.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/fly_in_list.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/ride_map.dart' show mapAttributionClearance;
import '../ride/freight_parts.dart' show FreightCargoView;
import '../ride/place_search.dart';
import '../ride/demo_ride.dart';
import 'demo_jobs.dart';
import 'direct_booking_badge.dart';
import 'stand_order_label.dart';
import 'driver_home_map.dart';
import '../support/call/mic_gate.dart' show primeMicForCalls;
import 'driver_online.dart';
import 'driver_permit_screen.dart' show currentPlateProvider, driverPermitProvider, showPermitBlock;
import 'driver_wallet_pills.dart';
import 'fare_offer.dart';
import 'my_ride_badges.dart';
import 'online_gate.dart';
import 'online_selfie_check.dart';
import 'partner_menu.dart';
import 'partner_mode_picker.dart' show pendingPartnerModeProvider;
import 'request_sheet.dart';
import 'ride_extras_parts.dart';
import 'partner_status_panel.dart';
import 'scheduled_jobs_screen.dart' show PartnerUpcomingBookingCard;
import 'vehicle_picker.dart';
import 'remote_action.dart';
import '../../core/partner_remote_action.dart' show DriverRemoteActions;
import '../../core/partner_modes.dart';
import '../../core/vehicle_assignment.dart';
import '../../core/saved_drafts.dart';
import '../../core/vehicle_onboarding.dart' show VehicleStep, firstVehicleStep;
import '../../data/ride_draft_store.dart';
import '../../data/vehicle_onboarding_repository.dart' show vehicleOnboardingRepositoryProvider;
import '../ride/welcome_back_sheet.dart' show showWelcomeBackSaved;
import '../../data/vehicle_assignment_repository.dart';
import '../../admin/screens/people/people_logic.dart' show parseStringList;
import '../../widgets/side_menu_host.dart';
import '../shell/app_side_menu.dart' show AppSideMenuHost;
import '../../widgets/trip_safety.dart';
import '../../widgets/net_image.dart';
import 'trip_handover_panel.dart' show HandoverOffersCard;
import '../../widgets/page_style_host.dart';
import '../ride/promo_parts.dart' show PromoAppliedIcon, rideHasPromo;
import '../../widgets/focus_order.dart';
import 'airport_queue_card.dart';

final openRequestsProvider = StreamProvider.autoDispose<List<RideRequest>>(
  (ref) => ref.watch(rideRepositoryProvider).watchOpen(),
);

/// Partners whose record lets them take jobs.
/// The driver home sheet's lowest height, as a share of [screenHeight]:
/// 20%, or on a short screen enough for the online switch card (128 px),
/// at most half.
double driverSheetRest(double screenHeight) {
  if (screenHeight <= 0) return 0.2;
  final needed = 128 / screenHeight;
  return needed <= 0.2 ? 0.2 : (needed >= 0.5 ? 0.5 : needed);
}

/// Whether the requests floating on the driver's map run down beside the
/// map's buttons rather than stopping above them: on a phone on its side,
/// where above them left a card a strip ~60 high.
bool floatingRequestsBeside(Size size) => size.width > size.height && size.height < 500;

bool partnerCanDrive(Partner p) {
  final s = p.status ?? '';
  return s == 'approved' || s.startsWith('permit-');
}

/// Below this height the wide driver panel scrolls as a whole instead of
/// holding its settings fixed over the queue.
const wideDriverPanelScrollBelow = 640.0;

/// Driver mode: go online, see open requests live, accept one.

class PartnerScreen extends ConsumerStatefulWidget {
  const PartnerScreen({super.key, this.remoteActionId});

  /// Support's request (Edit Partner › Change status, 0286) the driver
  /// tapped to confirm: run through this screen's own switch once it is up.
  final String? remoteActionId;

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
      locationSettings: activeLocationSettings(
        ActiveLocationUse.driverOnline,
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).map((p) => LatLng(p.latitude, p.longitude));
  } catch (_) {}
});

/// The clock the request alert's countdown reads (overridden in tests).
final requestAlertClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// How long going online (or starting the meter) waits on each of its checks
/// -- the device's access, the documents, the vehicle -- before treating it
/// as unanswered, which lets the driver through as a failed read already did.
const goOnlineCheckTimeout = Duration(seconds: 8);

class _PartnerScreenState extends ConsumerState<PartnerScreen> {
  bool _online = false;

  /// A demo request (Admin → Demo → mock incoming requests) is up: it
  /// floats on the map and holds the sheet down as a real one does.
  bool _demoShowing = false;

  void _onDemo(bool on) {
    if (mounted && on != _demoShowing) setState(() => _demoShowing = on);
  }

  // Only the admin's demo drivers (Admin → Display Settings → Demo drivers).
  bool get _demoOn => _online && ref.watch(demoDriverProvider);

  bool get _demoShown => _demoShowing && _demoOn;
  late final DriverOnline _onlineState;
  LatLng? _me;

  /// None of the driver's types is offered where they are (0245): online,
  /// but no requests show. Set on each build.
  bool _notHere = false;
  StreamSubscription<LatLng>? _fixes;
  String? _accepting;

  /// A vehicle question is on screen ([_askForVehicle]).
  bool _askingVehicle = false;

  /// Why the last check held the driver offline, in the words its dialog
  /// showed: what support's "Go online" reports back (0286).
  String? _refusal;

  /// This screen's own buttons, for support's requests (remote_action.dart).
  late final DriverScreenActions _remoteSlot;
  late final _ScreenRemoteActions _remote = _ScreenRemoteActions(this);
  bool _autoAccept = false;
  bool _allowOfferMe = true;

  /// The request whose pin was tapped on the map, shown first in the queue.
  String? _focusId;

  /// Requests auto-accept must not take: those already queued when it was
  /// switched on (or when going online with it on), and those it has tried.
  final _seen = <String>{};

  /// The incoming-request alert (Expo's request modal): the request being
  /// spotlighted, since when, and those already spotlighted. A skipped
  /// request stays on the queue; it just doesn't pop up again.
  String? _alertId;
  DateTime? _alertAt;
  final _alertSeen = <String>{};

  /// The fare each skipped request asked when it was skipped; a raise over
  /// it pops the request up again (Expo). [_raisedFrom] keeps the old fare
  /// of those brought back, for the alert's "was" line.
  final _declinedFare = <String, double>{};
  final _raisedFrom = <String, double>{};
  Timer? _alertTick;

  /// The alert's one-second clock: only the countdowns read it, so a tick
  /// rebuilds them and not the screen.
  late final ValueNotifier<DateTime> _alertClock;
  DateTime get _alertNow => _alertClock.value;
  set _alertNow(DateTime v) => _alertClock.value = v;

  /// The driver's position for the map: a fix that changes nothing on the
  /// queue moves the map alone ([_onFix]).
  final _meFix = ValueNotifier<LatLng?>(null);

  /// Back online from before this screen was built (a trip just ended):
  /// what is already waiting goes in the list, only new requests pop up.
  bool _restoredOnline = false;

  /// Put back online as the app opened, as the driver left it.
  bool _backOnline = false;

  @override
  void dispose() {
    _fixes?.cancel();
    _alertTick?.cancel();
    _alertClock.dispose();
    _meFix.dispose();
    // Online stays as the driver left it (driverOnlineProvider): a trip
    // that ends comes back to the Drive screen still online.
    final slot = _remoteSlot, mine = _remote;
    unawaited(Future.microtask(() => slot.clear(mine)));
    super.dispose();
  }

  /// Spotlights the next new request, or clears the alert when there is
  /// none (offline, auto-accept on, or nothing new).
  void _syncAlert(List<RideRequest> open) {
    if (!mounted) return;
    // Once the queue has loaded: requests already in it are not new.
    if (_restoredOnline && ref.read(openRequestsProvider).hasValue) {
      _restoredOnline = false;
      _alertSeen.addAll(open.map((r) => r.id));
    }
    for (final id in raisedAfterDecline(_declinedFare, [for (final r in open) (id: r.id, fare: r.effectiveFare)])) {
      _raisedFrom[id] = _declinedFare.remove(id)!;
      _alertSeen.remove(id);
    }
    String? next;
    if (_online && !_autoAccept) {
      // Only what is on the driver's list pops up: booked directly with this
      // driver (GET.now) first, then starred requests. The list is the whole
      // open queue as it is now, whatever change brought it (watchOpen
      // refetches on any event), so a request first seen in an UPDATE — a
      // My Ride request opening to everybody when its favourites window
      // ends — pops up as new just as an INSERT does.
      final ordered = pinDirectFirst(
        pinStarredFirst(
          destinationOrder(_pinned(open), toward: (r) => _destinationOn && _towardDestination(r), awayKm: _distanceTo),
          _starred,
        ),
        _myId,
      );
      next = nextRequestAlert(
        openIds: [for (final r in ordered) r.id],
        seen: _alertSeen,
        hidden: const {},
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
    _alertNow = ref.read(requestAlertClockProvider)();
    // Left alone, the request drops back into the queue below.
    if (requestAlertExpired(_alertNow.difference(_alertAt!))) _dismissAlert(skipped: false);
  }

  /// Ends the spotlight. Skipped or timed out, the request stays on the
  /// queue below; a skip also remembers its fare, so a raise brings it up
  /// again.
  void _dismissAlert({required bool skipped}) {
    final id = _alertId;
    if (id == null) return;
    if (skipped) {
      final req = (ref.read(openRequestsProvider).value ?? const <RideRequest>[]).where((r) => r.id == id).firstOrNull;
      final fare = req?.effectiveFare;
      if (fare != null) _declinedFare[id] = fare;
      // An airport order passed on goes to the next driver now (0249).
      if (req != null && req.airportHold) unawaited(declineAirportOffer(ref, id));
      // A stand order said no to goes back to the stand at once (0251).
      if (req != null && standOrderOf(req, _myId) != null) unawaited(ref.read(dispatchRepositoryProvider).decline(id));
    }
    setState(() => _alertId = null);
    _syncAlert(ref.read(openRequestsProvider).value ?? const []);
  }

  @override
  void initState() {
    super.initState();
    _alertClock = ValueNotifier(ref.read(requestAlertClockProvider)());
    _onlineState = ref.read(driverOnlineProvider.notifier);
    _online = _restoredOnline = ref.read(driverOnlineProvider);
    _remoteSlot = ref.read(driverScreenActionsProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _remoteSlot.set(_remote);
      _runRemote(widget.remoteActionId);
    });
    _resume();
    _locate();
    unawaited(_restoreOnline());
    // A vehicle being added when the app closed: Welcome back.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_offerVehicleDraft());
    });
    // A saved OBD-II reader comes up with the driver home, as Expo's did on
    // the Teksi screen, so the menu's Vehicle information row (shown only on
    // a live link) appears without opening the meter first. No-op without one.
    if (!kIsWeb) {
      unawaited(
        Future.microtask(() => ref.read(obdSessionProvider.notifier).ensureConnected()).catchError((Object _) {}),
      );
    }
    // Live: the map follows the driver as they move.
    _fixes = ref.read(driverPositionStreamProvider)().listen(_onFix, onError: (_) {});
  }

  @override
  void didUpdateWidget(PartnerScreen old) {
    super.didUpdateWidget(old);
    if (widget.remoteActionId != old.remoteActionId) _runRemote(widget.remoteActionId);
  }

  /// Support's request [id], tapped to confirm: this screen is up, so it
  /// runs through the switch itself.
  void _runRemote(String? id) {
    if (id == null || id.isEmpty) return;
    unawaited(ref.read(remoteActionHandlerProvider).handle(id).then((_) {}, onError: (Object _) {}));
  }

  /// A GPS fix: the map, the request sheet and the cards' distances follow
  /// it on their own; the screen rebuilds only when the queue itself moves
  /// with it (which requests, in what order, with a distance or not).
  void _onFix(LatLng p) {
    if (!mounted) return;
    final before = _queueView();
    _me = p;
    if (_queueView() != before) setState(() {});
    _meFix.value = p;
  }

  /// The queue as the driver's position decides it.
  String _queueView() {
    if (!_online) return '';
    final open = ref.read(openRequestsProvider).value ?? const <RideRequest>[];
    final order = destinationOrder(_pinned(open), toward: (r) => _destinationOn && _towardDestination(r), awayKm: _distanceTo);
    return [for (final r in order) '${r.id}${_distanceTo(r) == null ? '' : '+'}'].join('|');
  }

  Future<void> _locate() async {
    final p = await ref.read(driverPositionProvider)();
    if (p != null && mounted) setState(() => _me = p);
  }

  Future<void> _resume() async {
    final trip = await ref.read(rideRepositoryProvider).ongoingForPartner().catchError((_) => null);
    if (trip != null && mounted) context.push('/drive/trip/${trip.id}');
  }

  /// Online when the app last closed (driverOnlineProvider remembers it):
  /// back online now, through the same checks as the switch. When a check
  /// stops it, the server is told this driver is offline too.
  /// "Welcome back" for a vehicle being added (saved_drafts.dart): once per
  /// launch, within [rideDraftKeep], while that vehicle is still unfinished.
  /// Continue opens it at its next step; Not now leaves it in My vehicles.
  Future<void> _offerVehicleDraft() async {
    if (vehicleDraftOfferedThisRun) return;
    vehicleDraftOfferedThisRun = true;
    String? uid;
    try {
      uid = ref.read(currentUserIdProvider);
    } catch (_) {}
    if (uid == null) return;
    final store = ref.read(rideDraftStoreProvider);
    final d = await store.readSaved(SavedDraftKind.vehicle, uid);
    if (d == null) return;
    final id = draftText(d.data['id']);
    Map<String, dynamic>? v;
    if (id != null && d.freshAt(DateTime.now())) {
      try {
        v = await ref.read(vehicleOnboardingRepositoryProvider).vehicle(id);
      } catch (_) {}
    }
    // Gone, finished since or run out: nothing to offer.
    if (v == null || firstVehicleStep(v) == VehicleStep.done) {
      await store.clearSaved(SavedDraftKind.vehicle, uid);
      return;
    }
    if (!mounted) return;
    final go = await showWelcomeBackSaved(context, d);
    if (!mounted || go == null) return;
    await store.clearSaved(SavedDraftKind.vehicle, uid);
    if (go && mounted) unawaited(context.push('/drive/vehicles/$id'));
  }

  Future<void> _restoreOnline() async {
    if (_online || !await _onlineState.wasOnline() || !mounted || _online) return;
    try {
      await ref.read(partnerProvider.future).timeout(goOnlineCheckTimeout);
    } catch (_) {}
    if (!mounted || _online) return;
    final why = await _toggle(true);
    if (!mounted) return;
    if (why == null) {
      setState(() => _backOnline = true);
    } else {
      _onlineState.set(false);
      ref.read(driverPresenceProvider).tellOffline();
    }
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
    if (!_online || _notHere || !_autoAccept || !mounted) return;
    final partner = ref.read(partnerProvider).value;
    if (partner == null || !partnerCanDrive(partner)) return;
    // In destination mode only trips heading that way are taken unasked.
    final mine = _pinned(open);
    final eligible = _destinationOn ? mine.where(_towardDestination).toList() : mine;
    final pick = autoAcceptPick(
      [for (final r in eligible) (id: r.id, offerMe: r.offerMe, awayKm: _distanceTo(r))],
      _seen,
      busy: _accepting != null,
    );
    if (pick == null) return;
    _seen.add(pick);
    _accept(open.firstWhere((r) => r.id == pick), partner);
  }

  /// The Drive switch. Null once it is where it was asked to be, else why
  /// it stayed offline (what support's "Go online" reports, 0286).
  Future<String?> _toggle(bool v) async {
    _refusal = null;
    const gone = 'The Drive screen was closed.';
    // Each check below lets the driver through when it cannot be answered;
    // [goOnlineCheckTimeout] makes a check that hangs (a slow API) count as
    // one that could not be answered, instead of a switch that spins on.
    if (v && await ref.read(deviceBlockedProvider.future).timeout(goOnlineCheckTimeout, onTimeout: () => false)) {
      const why = '$serviceNotAvailable. This device cannot go online.';
      if (mounted) showInfo(context, why);
      return why;
    }
    if (v) {
      // Location on (Always on an iPhone) and notifications allowed, first.
      if (!mounted) return gone;
      if (!await ensureOnlineReady(context, ref, onBlock: (b) => _refusal = 'To go online: ${b.message}')) {
        return _refusal ?? 'Location or notifications are not set up to go online.';
      }
      if (!mounted) return gone;
      final partner = ref.read(partnerProvider).value;
      if (partner != null && !await _documentsCleared(partner, teksi: false)) {
        return _refusal ?? 'Required documents need updating before going online.';
      }
      if (!mounted) return gone;
      if (partner != null) {
        final needed = await _vehicleNeeded(partner, teksi: false);
        if (!mounted) return gone;
        if (needed != null) {
          // Asked once the switch has settled back (no spinner behind the
          // dialog); a vehicle picked there turns it on.
          unawaited(_askForVehicle(needed, teksi: false).then((ok) {
            if (ok && mounted) unawaited(_toggle(true));
          }));
          return vehicleNeededReason(needed);
        }
      }
    }
    if (v && !await _typeRulesCleared(teksi: false)) return _refusal ?? 'Your Partner Service type is not offered here.';
    if (!mounted) return gone;
    if (v && !await _vehiclePermitCleared()) return _refusal ?? "You can't go online yet.";
    if (!mounted) return gone;
    // Last, so nobody takes a selfie only to be held up by another check:
    // the selfie check on a phone (0290). Once taken they go online
    // whatever the match.
    if (v && !await ensureOnlineSelfie(context, ref, onRefusal: (r) => _refusal = r)) {
      return _refusal ?? 'A selfie check is waiting.';
    }
    if (!mounted) return gone;
    if (v && _autoAccept) _markQueueSeen();
    // Requests already waiting are in the list; only new ones pop up.
    if (v) _alertSeen.addAll(ref.read(openRequestsProvider).value?.map((r) => r.id) ?? const <String>[]);
    setState(() {
      _online = v;
      _demoShowing = false;
      if (!v) _backOnline = false;
    });
    _onlineState.set(v);
    if (!v) _syncAlert(const []);
    if (v) unawaited(_locate());
    // Online, calls may come: ask for the microphone now, on screen, if it
    // was never asked (a call answered from the phone's call screen can't).
    if (v) unawaited(primeMicForCalls(ref).catchError((_) {}));
    return null;
  }

  /// Expo's check before a service mode: compulsory documents that are
  /// missing, rejected or expired keep the partner offline, with a way to
  /// update them. When the documents cannot be read it lets them through, as
  /// Expo did, rather than locking a driver out over a network error.
  Future<bool> _documentsCleared(Partner partner, {required bool teksi}) async {
    List<DocIssue> blocking;
    try {
      blocking = blockingDocIssues(
        await ref.read(partnerDocCheckProvider)(partner.raw, teksi: teksi).timeout(goOnlineCheckTimeout),
      );
    } catch (_) {
      return true;
    }
    if (blocking.isEmpty) return true;
    if (!mounted) return false;
    _refusal = 'Before you can ${teksi ? 'start the meter' : 'go online'}, please update the following: '
        '${summarizeDocIssues(blocking)}';
    final update = await showAppDialog<bool>(id: 'partner.documents-cleared',
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

  /// Admin → Partner Type rules (0245), as the server judges them where the
  /// driver is: for e-hailing, one of their types offered here with its
  /// permit and a vehicle young enough; for the meter ([teksi]), street hail
  /// offered here too. Unanswered lets the driver through (the server still
  /// keeps them offline and refuses bids where it must).
  Future<bool> _typeRulesCleared({required bool teksi}) async {
    final PartnerTypeCheck check;
    try {
      check = await ref.read(partnerTypeCheckerProvider)(lat: _me?.latitude, lng: _me?.longitude, teksi: teksi);
    } catch (_) {
      return true;
    }
    final String? why = teksi && check.hailBlocked ? hailNotOfferedMessage : (check.ok ? null : check.reason);
    if (why == null && check.ok) return true;
    if (!mounted) return false;
    _refusal = why ?? 'Your Partner Service type is not offered here.';
    await showAppDialog<void>(
      id: 'partner.type-rules-blocked',
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('type-rules-blocked'),
        title: Text(teksi ? 'Street hail not available here' : 'Not available here'),
        content: Text(why ?? 'Your Partner Service type is not offered here.'),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return false;
  }

  /// The country's permits (0254): where they are required, a vehicle
  /// without a valid one (and no bypass) stays offline; say why and where to
  /// see it. Unanswered lets the driver through (the server still keeps them
  /// offline).
  Future<bool> _vehiclePermitCleared() async {
    String? problem;
    try {
      problem = (await ref.read(permitsRepositoryProvider).myPermits().timeout(goOnlineCheckTimeout)).problem;
    } catch (_) {
      return true;
    }
    final why = problem;
    if (why == null) return true;
    if (!mounted) return false;
    _refusal = why;
    final open = await showAppDialog<bool>(
      id: 'partner.vehicle-permit-blocked',
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('vehicle-permit-blocked'),
        title: const Text("You can't go online yet"),
        content: Text(why),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('OK')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('My permit'),
          ),
        ],
      ),
    );
    if (open == true && mounted) unawaited(context.push('/drive/permits'));
    return false;
  }

  /// TEKSI from the mode picker or the service list (Expo `partner-teksi`):
  /// the documents and the vehicle, then the permit screen, where Start
  /// Pickup holds the hire to the permit's checks.
  Future<void> _openTeksi(Partner partner) async {
    if (!await _typeRulesCleared(teksi: true)) return;
    if (!mounted || !await _documentsCleared(partner, teksi: true)) return;
    if (!mounted || !await _vehicleReady(partner, teksi: true)) return;
    if (mounted) context.push('/drive/permit');
  }

  Future<void> _openMeter(Partner partner) async {
    if (!await _typeRulesCleared(teksi: true)) return;
    if (!mounted || !await _documentsCleared(partner, teksi: true)) return;
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
    final needed = await _vehicleNeeded(partner, teksi: teksi);
    if (needed == null) return true;
    if (!mounted) return false;
    return _askForVehicle(needed, teksi: teksi);
  }

  /// The vehicle under the online switch: the one this driver has taken,
  /// else "No vehicle chosen" (not the car on their profile, which they may
  /// not be driving: going online then asked them to pick one). Where the
  /// vehicles can't be read, the profile's, as before.
  List<String?> _vehicleLine(Partner p) {
    final vehicles = ref.watch(assignableVehiclesProvider);
    if (vehicles.hasError) return [p.vehicle, p.plate];
    final list = vehicles.value;
    if (list == null) return const [];
    final mine = list.where((v) => v.inUseByMe).firstOrNull;
    return mine == null ? const ['No vehicle chosen'] : [mine.title, mine.plate];
  }

  /// Street hail (the meter) is not offered for the driver's types where
  /// they are (0245). False while unknown.
  bool _hailBlockedHere() =>
      ref.watch(partnerTypeCheckProvider(partnerTypeCheckKey(_me?.latitude, _me?.longitude, teksi: true))).value?.hailBlocked ??
      false;

  /// [_vehicleReady]'s check alone: null when the driver may start, else
  /// the vehicles to choose from (maybe none).
  Future<List<AssignableVehicle>?> _vehicleNeeded(Partner partner, {required bool teksi}) async {
    if (await _vehicleRequired(partner, teksi: teksi) != true) return null;
    List<AssignableVehicle> vehicles;
    try {
      vehicles = await ref.read(assignableVehiclesProvider.future).timeout(goOnlineCheckTimeout);
    } catch (_) {
      return null;
    }
    if (vehicles.any((v) => v.inUseByMe)) return null;
    return vehicles;
  }

  /// Whether the driver's modes (the meter's, for [teksi]) need a vehicle;
  /// null when the catalogue can't be read.
  Future<bool?> _vehicleRequired(Partner partner, {required bool teksi}) async {
    try {
      final entries = await ref.read(partnerTypeEntriesProvider.future).timeout(goOnlineCheckTimeout);
      final modes = [
        for (final m in partnerModeOptions(parseStringList(partner.raw['partner_types']), entries))
          if (m.isTeksi == teksi) m.name,
      ];
      return (modes.isEmpty ? [teksi ? 'teksi' : 'ehailing'] : modes).any((m) => vehicleRequiredFor(m, entries));
    } catch (_) {
      return null;
    }
  }

  /// Asks for a vehicle ([vehicleGateFor]): the only one that can be driven
  /// is taken for the driver; else pick one, finish the one this driver
  /// added but left half set up (saying what is missing), see why none can
  /// be driven yet, or add one. True once one is taken. [action] is what
  /// waits for it ("go online" when not given).
  Future<bool> _askForVehicle(List<AssignableVehicle> vehicles, {required bool teksi, String? action}) async {
    // One question at a time (auto-accept may ask while a dialog is up).
    if (_askingVehicle) return false;
    _askingVehicle = true;
    try {
      return await _askForVehicleNow(vehicles, teksi: teksi, action: action);
    } finally {
      _askingVehicle = false;
    }
  }

  Future<bool> _askForVehicleNow(List<AssignableVehicle> vehicles, {required bool teksi, String? action}) async {
    final gate = vehicleGateFor(vehicles);
    switch (gate.kind) {
      case VehicleGateKind.ready:
        return true;
      case VehicleGateKind.takeOnly:
        final only = gate.vehicle!;
        try {
          await ref.read(vehicleAssignmentRepositoryProvider).claim(only.id);
        } catch (e) {
          if (mounted) showInfo(context, claimVehicleErrorMessage(e));
          return false;
        }
        ref.invalidate(assignableVehiclesProvider);
        if (mounted) showInfo(context, 'Driving ${only.plate.isEmpty ? only.title : only.plate}');
        return true;
      case VehicleGateKind.choose:
      case VehicleGateKind.finish:
      case VehicleGateKind.waiting:
      case VehicleGateKind.add:
        break;
    }
    final unfinished = gate.kind == VehicleGateKind.finish ? gate.vehicle : null;
    final start = action ?? (teksi ? 'start the meter' : 'go online');
    final String title;
    final String message;
    final String button;
    switch (gate.kind) {
      case VehicleGateKind.finish:
        final name = unfinished!.plate.isEmpty ? 'Your vehicle' : unfinished.plate;
        title = 'Finish your vehicle';
        message = "$name isn't set up yet: ${firstVehicleStep(unfinished.vehicle).label} is still missing. "
            'Finish it before you can $start.';
        button = 'Finish vehicle';
      case VehicleGateKind.waiting:
        title = 'No vehicle ready to drive';
        message = 'You need a vehicle before you can $start, and none of yours can be driven yet.\n\n'
            '${vehicleGateWaitingLines(vehicles)}';
        button = 'My vehicles';
      case VehicleGateKind.add:
        title = 'Choose a vehicle';
        message = 'You need a vehicle before you can $start. Add the vehicle you drive.';
        button = 'Add a vehicle';
      default:
        title = 'Choose a vehicle';
        message = 'You need a vehicle before you can $start. Pick the one you are driving.';
        button = 'Choose vehicle';
    }
    if (!mounted) return false;
    final choose = await showAppDialog<bool>(id: 'partner.vehicle-ready',
      context: context,
      builder: (c) => AlertDialog(
        key: const ValueKey('vehicle-required'),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          FilledButton(
            key: const ValueKey('vehicle-required-go'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(c, true),
            child: Text(button),
          ),
        ],
      ),
    );
    if (choose != true || !mounted) return false;
    switch (gate.kind) {
      case VehicleGateKind.finish:
        unawaited(context.push('/drive/vehicles/${unfinished!.id}'));
        return false;
      case VehicleGateKind.waiting:
        unawaited(context.push('/drive/vehicles'));
        return false;
      case VehicleGateKind.add:
        unawaited(context.push('/drive/vehicles/new'));
        return false;
      default:
        break;
    }
    final picked = await showAppSheet<AssignableVehicle>(id: 'partner.vehicle-ready-2',
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

  /// Before an offer or an accept: a driver whose mode needs a vehicle has
  /// a vehicle session, so the rider sees the plate and car with the offer.
  /// The session is read fresh (it may have ended on another phone or by an
  /// admin); without one the vehicles are read again and the driver asked
  /// as when going online, and nothing is sent. Unanswered lets the offer
  /// through, as going online does (the server fills the car in once a
  /// vehicle is taken, 0260).
  Future<bool> _vehicleReadyToOffer(Partner partner, {required bool accepting}) async {
    if (await _vehicleRequired(partner, teksi: false) != true) return mounted;
    try {
      final has = await ref.read(vehicleAssignmentRepositoryProvider).hasSession().timeout(goOnlineCheckTimeout);
      if (has) return mounted;
    } catch (_) {
      return mounted;
    }
    ref.invalidate(assignableVehiclesProvider);
    final needed = await _vehicleNeeded(partner, teksi: false);
    if (needed == null || !mounted) return mounted;
    return _askForVehicle(needed, teksi: false, action: accepting ? 'accept a request' : 'send an offer');
  }

  /// Accept: an offer at the rider's own fare. The rider still says yes,
  /// unless they booked with "Auto-accept offer of RM x" at that fare or
  /// more, which the database takes at once (migration 0141).
  Future<void> _accept(RideRequest r, Partner partner) async {
    final fare = r.effectiveFare ?? r.fare;
    if (fare == null) return;
    await _offer(r, partner, preset: fare, accepting: true);
  }

  /// A counter-offer on [r]: [preset] when one was tapped, else the amount
  /// the driver types. [accepting] is an Accept at the rider's own fare.
  Future<void> _offer(RideRequest r, Partner partner, {double? preset, bool accepting = false}) async {
    // A vehicle first (no offer goes without one), then the questions.
    if (!await _vehicleReadyToOffer(partner, accepting: accepting) || !mounted) return;
    // "Passenger added extras" first (0253). The extras ticked to stop
    // showing are saved either way: at once on Cancel, after the answer
    // went through otherwise (saved first, the request would be hidden
    // from this driver before they answer it).
    var stop = const <String>{};
    final extras = await askRideExtras(context, r, accepting: accepting);
    if (extras != null) {
      if (!extras.go) return stopRideExtras(ref, extras.stop);
      stop = extras.stop;
    }
    if (!mounted) return stopRideExtras(ref, stop);
    final amount = preset ?? await askCounterOffer(context, r);
    if (amount == null || !mounted) return stopRideExtras(ref, stop);
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
      if (mounted) {
        // The server's reasons (0269): declined already, offers paused for
        // cancelling too much, an amount out of range.
        '$e'.contains('OFFER') ? showInfo(context, rideOfferError(e)) : showError(context, e);
      }
      return;
    } finally {
      if (mounted) setState(() => _accepting = null);
      unawaited(stopRideExtras(ref, stop));
    }
    if (!mounted) return;
    final me = ref.read(currentUserIdProvider);
    if (sent == null) {
      showInfo(context, accepting ? 'Another driver already took this request.' : 'This request is no longer open.');
      return;
    }
    if (me == null) return;
    // Taken in the same write: the rider auto-accepts offers like this one.
    if (sent.status != RideStatus.open && sent.partnerId == me) {
      context.push('/drive/trip/${sent.id}');
      return;
    }
    final won = await showAppDialog<RideRequest>(id: 'partner.offer',
      context: context,
      barrierDismissible: false,
      builder: (_) => OfferPendingDialog(
        repo: repo,
        ride: r,
        me: me,
        amount: amount,
        accepting: accepting,
        myOffers: _myOfferRows(me),
      ),
    );
    if (won != null && mounted) context.push('/drive/trip/${won.id}');
  }

  /// This driver's offer rows (0269); null where they can't be read.
  Stream<List<RideOfferRow>>? _myOfferRows(String me) {
    try {
      return ref.read(cityRideRepositoryProvider).myOffers(me);
    } catch (_) {
      return null;
    }
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
    final add = await showAppSheet<bool>(id: 'partner.choose-destination',
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
    // A phone-sized page (the side menu's): the menu button top left. On a
    // wide one with the rail it joins the page buttons on the right, clear
    // of the "You are offline" panel.
    final size = MediaQuery.sizeOf(context);
    final sideMenu = SideMenuHost.of(context) != null || AppSideMenuHost.appliesAt(size.width, size.height);
    // My Ride's stars and the services' search radii: the queue re-sorts
    // and re-filters as they arrive (both empty when unavailable).
    ref.watch(favouriteRiderIdsProvider);
    ref.watch(serviceDispatchConfigsProvider);
    ref.listen(openRequestsProvider, (_, next) {
      final open = _notHere ? const <RideRequest>[] : next.value;
      if (open != null) {
        _maybeAutoAccept(open);
        _syncAlert(open);
      }
    });
    final page = Scaffold(
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
                  return PartnerStatusPanel(partner: p, onOpenApplication: openOnboarding);
                }
                // The service picked from the rider menu's Partner Mode button:
                // TEKSI goes on to its permit screen, through the checks.
                if (ref.watch(pendingPartnerModeProvider) != null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    final mode = ref.read(pendingPartnerModeProvider.notifier).take();
                    if (mode != null && mode.isTeksi) _openTeksi(p);
                  });
                }
                final modes = partnerModeOptions(
                  parseStringList(p.raw['partner_types']),
                  ref.watch(partnerTypeEntriesProvider).value ?? const [],
                );
                final wide = MediaQuery.sizeOf(context).width >= 900;
                // Admin → Partner Type → Service availability (0245): where
                // none of the driver's types is offered, no requests show
                // (the server stops pushing them and refuses bids there).
                final here = _online
                    ? ref.watch(partnerTypeCheckProvider(partnerTypeCheckKey(_me?.latitude, _me?.longitude, teksi: false))).value
                    : null;
                _notHere = here != null && !here.ok;
                final showRequests = _online && !_notHere;
                final notHereCard = EmptyState(
                  key: const ValueKey('partner-type-not-here'),
                  icon: Icons.location_off_outlined,
                  title: 'No jobs for your Partner Service type here',
                  message: here?.reason ?? 'Your Partner Service type is not offered in this area.',
                );
                final pins = showRequests ? _pinned(ref.watch(openRequestsProvider).value ?? const []) : const <RideRequest>[];
                final map = ValueListenableBuilder(
                  valueListenable: _meFix,
                  builder: (_, _, _) => DriverHomeMap(
                    key: const ValueKey('driver-home-map'),
                    me: _me,
                    requests: pins,
                    onSelect: (r) => setState(() => _focusId = r.id),
                  ),
                );
                final head = <Widget>[
                    // Online first, above the service types.
                    Card(
                      key: const ValueKey('partner-online'),
                      child: BusySwitchListTile(
                        value: _online,
                        onChanged: _toggle,
                        secondary: Icon(_online ? Icons.wifi_tethering : Icons.wifi_tethering_off),
                        title: Text(_online ? (_backOnline ? "You're back online" : 'You are online') : 'You are offline'),
                        // One line: on a phone on its side the card must fit
                        // the sheet's lowest height.
                        subtitle: Text(
                          [p.name, ..._vehicleLine(p)].whereType<String>().where((s) => s.trim().isNotEmpty).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    // A driver asking this partner to take over their trip (0199).
                    const HandoverOffersCard(),
                    // At an airport: the waiting queue (0249).
                    if (_online) const AirportQueueCard(),
                    // The next scheduled ride the driver took, under the switch.
                    const PartnerUpcomingBookingCard(),
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
                              onTap: () => m.isTeksi ? _openTeksi(p) : (_online ? null : _toggle(true)),
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
                    // Lost item reports to answer (Phase D4).
                    const DriverLostItemsCard(),
                    const CurrentVehicleCard(),
                    // On a phone the demo request floats on the map instead,
                    // with the real ones ([_floatingRequests]).
                    if (wide && _demoOn) DemoJobFeed(key: const ValueKey('demo-job-feed'), onShowing: _onDemo),
                  ];
                const offline = EmptyState(icon: Icons.local_taxi_outlined, title: 'Go online to receive ride requests');
                if (wide) {
                  // Tall enough, the settings stand over the queue, which
                  // takes the rest; short (a phone on its side, 915 × 412),
                  // the whole panel scrolls, the queue a screenful below the
                  // settings, so nothing overflows.
                  final panel = LayoutBuilder(
                    builder: (_, c) => c.maxHeight >= wideDriverPanelScrollBelow
                        ? Column(children: [...head, Expanded(child: showRequests ? _queue(p, wide: true) : (_online ? notHereCard : offline))])
                        : CustomScrollView(
                            key: const ValueKey('partner-panel-scroll'),
                            slivers: [
                              SliverList.list(children: head),
                              SliverToBoxAdapter(
                                child: SizedBox(
                                  height: c.maxHeight,
                                  child: showRequests ? _queue(p, wide: true) : (_online ? notHereCard : offline),
                                ),
                              ),
                            ],
                          ),
                  );
                  return Row(children: [
                    SizedBox(width: 520, child: panel),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: Stack(children: [
                        Positioned.fill(child: map),
                        // A new request flies in over the map on a desktop screen.
                        if (showRequests) Positioned(top: 16, right: 16, width: 400, child: _alertOverlay(p)),
                      ]),
                    ),
                  ]);
                }
                // A phone: the map fills the screen, the requests float on it and
                // the sheet holds the driver's settings. While there are requests
                // the sheet is held down so the list on the map has the room.
                final open = showRequests ? ref.watch(openRequestsProvider).value ?? const <RideRequest>[] : const <RideRequest>[];
                final queue = _queueOrder(open, wide: false);
                // The new request is the sheet up from the bottom, not a card here.
                final floating = queue.sorted;
                // Fully down (just the online switch) until the driver drags
                // it up; on a short screen (a phone on its side) low enough
                // still holds the whole switch card, so the map buttons
                // stand clear above it.
                final rest = driverSheetRest(MediaQuery.sizeOf(context).height);
                return MapSheetLayout(
                  initial: rest,
                  min: rest,
                  locked: floating.isNotEmpty || _demoShown,
                  map: Stack(children: [
                    Positioned.fill(child: map),
                    if (showRequests) _floatingRequests(p, null, floating),
                  ]),
                  // All the way down only the online switch shows.
                  // The sheet rests no lower than the whole switch card, over
                  // the home bar too (on its side its foot was cut off).
                  peek: ResponsiveCenter(maxWidth: 760, child: MapSheetRestLine(child: head.first)),
                  sheet: ResponsiveCenter(
                    maxWidth: 760,
                    child: Column(children: [...head.skip(1), if (!_online) offline, if (_online && _notHere) notHereCard]),
                  ),
                );
              },
            ),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          // Floating shortcuts: reached by keyboard after the rail and the
          // panel, with the map's own buttons (FocusLast).
          child: FocusLast(child: SafeArea(
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
                    hasTeksiPartnerType(partner.value!.raw['partner_types']) &&
                    !_hailBlockedHere())
                  _floatingButton(
                    tooltip: 'Meter Digital',
                    icon: Icons.speed,
                    onPressed: () => _openMeter(partner.value!),
                  ),
                if (partner.value != null &&
                    partnerCanDrive(partner.value!) &&
                    (ref.watch(scheduledRidesConfigProvider).value?.enabled ?? false))
                  _floatingButton(
                    tooltip: 'Scheduled rides',
                    icon: Icons.event_outlined,
                    onPressed: () {
                      context.push('/drive/scheduled');
                    },
                  ),
                // After approval: an application in progress adds its vehicle
                // from the application itself.
                if (partner.value != null && partnerCanDrive(partner.value!))
                  _floatingButton(
                    tooltip: 'My vehicles',
                    icon: Icons.directions_car_outlined,
                    onPressed: () {
                      context.push('/drive/vehicles');
                    },
                  ),
                // No side menu (a wide screen with the rail): the menu joins
                // these buttons instead of sitting over the panel's corner.
                if (!sideMenu)
                  _floatingButton(
                    key: const ValueKey('partner-menu-button'),
                    tooltip: 'Menu',
                    icon: Icons.menu,
                    onPressed: () => showPartnerMenu(context),
                  ),
              ]),
            ),
          )),
        ),
        // The menu: top left, exactly where the home map has it (on a
        // phone, with its side menu).
        if (sideMenu)
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
    // No app bar to set the status bar: its icons follow the theme.
    return ThemedStatusBar(child: page);
  }

  /// The new request on a phone ([RideRequestSheet]): up from the bottom
  /// over a dimmed page, and back down when it is answered, taken or times
  /// out.
  Widget _requestSheet(Partner partner) {
    final list = ref.watch(openRequestsProvider).value ?? const <RideRequest>[];
    final r = list.where((r) => r.id == _alertId).firstOrNull;
    // While the sheet is up nothing behind it (the demo request card with
    // its Accept and Decline, the map's buttons) is reachable by a screen
    // reader (141).
    return BlockSemantics(blocking: r != null, child: Stack(children: [
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
              : ListenableBuilder(
                  key: ValueKey('request-sheet-slot-${r.id}'),
                  listenable: Listenable.merge([_alertClock, _meFix]),
                  builder: (_, _) => RideRequestSheet(
                  key: ValueKey('request-sheet-${r.id}'),
                  request: r,
                  shown: _alertNow.difference(_alertAt ?? _alertNow),
                  now: _alertNow,
                  me: _me,
                  awayKm: _distanceTo(r),
                  raisedFrom: _raisedFrom[r.id],
                  towardDestination: _destinationOn && _towardDestination(r),
                  starred: _starred(r),
                  driverId: _myId,
                  busy: _accepting != null,
                  onAccept: () => _accept(r, partner),
                  onSkip: () => _dismissAlert(skipped: true),
                  onOffer: canCounterOffer(requestOfferMe: r.offerMe, allowOfferMe: _allowOfferMe)
                      ? (amount) => _offer(r, partner, preset: amount)
                      : null,
                ),
                ),
        ),
      ),
    ]));
  }

  /// One of the round buttons floating at the top of the page (in place of
  /// a top bar), like the map's own. One whose action does work (the Meter
  /// Digital checks) spins until it is done; opening a page or the menu is
  /// instant.
  Widget _floatingButton({Key? key, required String tooltip, required IconData icon, required BusyAction onPressed}) =>
      BusyFab(key: key, tooltip: tooltip, onPressed: onPressed, child: Icon(icon));

  /// The requests on this driver's queue (skipped ones included), which are
  /// also the map's pins: those whose pickup is inside their service's max
  /// search radius ([filterByPickupRadius]), starred ones wherever they are,
  /// and every one while the driver's position is not known.
  List<RideRequest> _pinned(List<RideRequest> open) {
    final configs = ref.read(serviceDispatchConfigsProvider).value ?? const {};
    return filterByPickupRadius(
      open,
      awayKm: _distanceTo,
      maxKm: (r) => dispatchConfigFor(configs, r.service).searchRadiusMaxKm,
      uncapped: _starred,
    );
  }

  /// My Ride's gold star: offered to this driver as a favourite, or from a
  /// rider who has them as one (and isn't hidden).
  bool _starred(RideRequest r) => r.starredFor(_myId, ref.read(favouriteRiderIdsProvider).value ?? const {});

  /// The signed-in driver's account id (what My Ride targets); null when
  /// it can't be read.
  String? get _myId {
    try {
      return ref.read(currentUserIdProvider);
    } catch (_) {
      return null;
    }
  }

  /// The new request over the map (desktop), with the app's one offer
  /// motion: it slides in from the right and out to the left, tilting, when
  /// it is accepted, declined, taken or times out.
  Widget _alertOverlay(Partner partner) {
    final list = ref.watch(openRequestsProvider).value ?? const <RideRequest>[];
    final alert = list.where((r) => r.id == _alertId).firstOrNull;
    return OfferMotionSwitcher(
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
    // Booked directly with this driver (GET.now) on top, then starred (My
    // Ride) requests; the one tapped on the map above all.
    final sorted = focusFirst(
      pinAssignedFirst(
        pinDirectFirst(
          pinStarredFirst(
            destinationOrder(queued, toward: (r) => destinationOn && _towardDestination(r), awayKm: _distanceTo),
            _starred,
          ),
          _myId,
        ),
        _myId,
      ),
      _focusId,
    );
    return (alert: alert, sorted: sorted);
  }

  /// The requests floating on the phone's map, flying in as they arrive and
  /// out as they go, scrolled up and down to pick one; a "waiting" pill
  /// while there are none.
  Widget _floatingRequests(Partner partner, RideRequest? alert, List<RideRequest> items) {
    final t = Theme.of(context);
    final sideways = floatingRequestsBeside(MediaQuery.sizeOf(context));
    final demoOn = _demoOn, demoShown = _demoShown;
    // Inside the map, so the list keeps clear of the sheet and the map
    // buttons; mounted even when empty, so the last card flies out too.
    return Positioned.fill(
      child: Builder(
        builder: (context) => Stack(children: [
          MapBottomInset.listen(
            context,
            (inset) => Positioned(
              key: const ValueKey('floating-requests'),
              // Below the page's floating buttons (under the status bar) and
              // above the map's own column of buttons (traffic, map view,
              // recenter): on a short screen the list scrolls between them.
              top: MediaQuery.paddingOf(context).top + 64,
              left: 12 + MediaQuery.paddingOf(context).left,
              // On a phone on its side there is no room above the map's
              // buttons (the card was cut): the list runs down beside them
              // instead, as far as the sheet.
              right: 12 + MediaQuery.paddingOf(context).right + (sideways ? 64 : 0),
              bottom: inset + mapAttributionClearance + (sideways ? 0 : 168),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // A demo request, as the real ones float (it sat unseen in
                // the sheet held down under them).
                if (demoOn) DemoJobFeed(key: const ValueKey('demo-job-feed'), onShowing: _onDemo),
                Expanded(
                  key: const ValueKey('floating-requests-list'),
                  child: FlyInList<RideRequest>(
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    items: items,
                    idOf: (r) => r.id == alert?.id ? 'alert-${r.id}' : r.id,
                    itemBuilder: (_, r) => r.id == alert?.id ? _alertCard(r, partner) : _requestCard(r, partner),
                  ),
                ),
              ]),
            ),
          ),
          if (items.isEmpty && !demoShown)
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
                      Flexible(
                        child: Text(
                          'Waiting for requests…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
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
    final demoShown = _demoShown;
    return AsyncView(
      value: ref.watch(openRequestsProvider),
      onRetry: () => ref.invalidate(openRequestsProvider),
      data: (list) {
        final (:alert, :sorted) = _queueOrder(list, wide: wide);
        if (alert == null && sorted.isEmpty) {
          // A request showing (a demo one above, or a real one over the
          // map on a desktop): not "waiting" beside it.
          if (demoShown || list.any((r) => r.id == _alertId)) return const SizedBox.shrink();
          return Column(children: [
            HiddenExtrasLine(feed: [for (final r in list) r.id].join(',')),
            const Expanded(
              child: EmptyState(icon: Icons.radar, title: 'Waiting for requests…', message: 'New requests appear here instantly.'),
            ),
          ]);
        }
        // "1 request not shown: it includes an extra you turned off" (0253).
        final hidden = HiddenExtrasLine(feed: [for (final r in list) r.id].join(','));
        return ListView.builder(
          itemCount: sorted.length + (alert == null ? 0 : 1) + 1,
          itemBuilder: (_, index) {
            if (index == 0) return hidden;
            index--;
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
            if (_starred(r)) ...[
              MyRideStar(key: ValueKey('my-ride-star-${r.id}')),
              const SizedBox(width: 6),
            ],
            Expanded(child: Text(r.service ?? 'Ride', style: t.textTheme.titleMedium)),
            // The full fare; a promo is paid to the driver by the platform (0242).
            if (rideHasPromo(r)) ...[
              PromoAppliedIcon(key: ValueKey('promo-applied-${r.id}')),
              const SizedBox(width: 6),
            ],
            Text(r.fareText(r.effectiveFare),
                style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          ]),
          MyRideForYouLabel(request: r, me: _myId, clock: ref.read(requestAlertClockProvider)),
          DirectBookingLabel(request: r, me: _myId),
          StandOrderLabel(request: r, me: _myId),
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
          // How far away moves with every fix: this line alone rebuilds.
          ValueListenableBuilder(
            valueListenable: _meFix,
            builder: (_, _, _) {
              final away = _distanceTo(r);
              return Text([
                if (away != null) '${formatDistance(away)} away',
                '${formatDistance(r.distanceKm)} trip',
                r.paymentMode,
                '${r.passengers} pax',
                // Checked against the card it is on, not the page.
              ].join(' · '), style: t.textTheme.bodySmall?.copyWith(
                color: mutedTextColor(t, background: t.cardTheme.color ?? t.colorScheme.surfaceContainerLow),
              ));
            },
          ),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.trip_origin, size: 16, color: Colors.green.shade700),
            const SizedBox(width: 8),
            Expanded(child: Text(r.pickupLabel, maxLines: 2, overflow: TextOverflow.ellipsis)),
          ]),
          // The pickup's place type at a Multi-Gate place or airport (0264).
          RidePlaceTypeTag(
            key: ValueKey('queue-pickup-type-${r.id}'),
            typeKey: r.pickupPlaceType,
            padding: const EdgeInsetsDirectional.only(start: 24, top: 2, bottom: 2),
          ),
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
            Expanded(child: Text(r.dropLabel, maxLines: 2, overflow: TextOverflow.ellipsis)),
          ]),
          RidePlaceTypeTag(
            key: ValueKey('queue-drop-type-${r.id}'),
            typeKey: r.dropPlaceType,
            padding: const EdgeInsetsDirectional.only(start: 24, top: 2),
          ),
          if (r.note != null) Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('“${r.note}”', style: t.textTheme.bodySmall),
          ),
          // Freight (0267): the cargo, the size and the options.
          if (r.isFreight)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: FreightCargoView(request: r, locked: r.status == RideStatus.open),
            ),
          if (r.offeredFare != null && r.partnerId != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('A driver has offered ${r.fareText(r.offeredFare)}',
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
                    : Text(acceptLabel(r), textAlign: TextAlign.center),
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
    Duration shown() => _alertNow.difference(_alertAt ?? _alertNow);
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
            if (_starred(r)) ...[
              MyRideStar(key: ValueKey('my-ride-star-${r.id}')),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                _raisedFrom.containsKey(r.id) ? 'Fare raised' : 'New request',
                key: const ValueKey('request-alert-title'),
                style: t.textTheme.titleMedium,
              ),
            ),
            ValueListenableBuilder(
              valueListenable: _alertClock,
              builder: (_, _, _) => Text('${requestAlertSecondsLeft(shown())} s', style: t.textTheme.labelLarge),
            ),
          ]),
          const SizedBox(height: 6),
          ValueListenableBuilder(
            valueListenable: _alertClock,
            builder: (_, _, _) => LinearProgressIndicator(
              key: const ValueKey('request-alert-countdown'),
              value: requestAlertProgress(shown()),
            ),
          ),
          MyRideForYouLabel(request: r, me: _myId, clock: ref.read(requestAlertClockProvider)),
          DirectBookingLabel(request: r, me: _myId),
          StandOrderLabel(request: r, me: _myId),
          if (_raisedFrom[r.id] case final was?)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'The passenger raised the fare from ${r.fareText(was)} '
                'to ${r.fareText(r.effectiveFare)}.',
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
                Row(
                  children: [
                    Flexible(child: Text(r.firstNameForDrivers, style: t.textTheme.titleSmall)),
                    // "New rider" or "Low" (0269).
                    Padding(padding: const EdgeInsets.only(left: 6), child: RiderBadgeChip(ride: r)),
                    if (r.isForOthers)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Tooltip(
                          message: 'Booked for someone else',
                          child: Icon(Icons.group_outlined, key: ValueKey('for-others-${r.id}'), size: 16),
                        ),
                      ),
                  ],
                ),
                ValueListenableBuilder(
                  valueListenable: _meFix,
                  builder: (_, _, _) {
                    final away = _distanceTo(r);
                    return Text(
                      [
                        if (showRiderStars(r, ref.read(cityRideConfigProvider).value?.riderRating ??
                            RiderRatingSettings.standard))
                          '★ ${r.riderRating!.toStringAsFixed(1)}',
                        // The rider's trips (0269).
                        if (r.riderTrips case final n?) '$n ${n == 1 ? 'trip' : 'trips'}',
                        if (away != null) '${formatDistance(away)} away',
                        if (away != null) '~${pickupMinutes(away)} min',
                      ].join(' · '),
                      style: t.textTheme.bodySmall,
                    );
                  },
                ),
              ]),
            ),
            if (rideHasPromo(r)) ...[
              PromoAppliedIcon(key: ValueKey('promo-applied-${r.id}'), size: 20),
              const SizedBox(width: 6),
            ],
            Text(r.fareText(r.effectiveFare),
                style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 10),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.trip_origin, color: Colors.green.shade700),
            title: Text(r.pickupLabel, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: r.pickupAddress == null ? null : Text(r.pickupAddress!, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          // The pickup's place type at a Multi-Gate place or airport (0264).
          RidePlaceTypeTag(
            key: ValueKey('request-card-pickup-type-${r.id}'),
            typeKey: r.pickupPlaceType,
            padding: const EdgeInsetsDirectional.only(start: 40, bottom: 4),
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.location_on, color: Colors.red.shade700),
            title: Text(r.dropLabel, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                '${formatDistance(r.distanceKm)} trip',
                if (r.durationMin != null) '${r.durationMin} min',
              ].join(' · '),
            ),
          ),
          RidePlaceTypeTag(
            key: ValueKey('request-card-drop-type-${r.id}'),
            typeKey: r.dropPlaceType,
            padding: const EdgeInsetsDirectional.only(start: 40, bottom: 4),
          ),
          // Facts, not choices: plain text to a screen reader (a Chip read
          // as an unchecked checkbox on the web).
          Wrap(spacing: 6, runSpacing: 6, children: [
            _InfoPill(r.paymentMode),
            _InfoPill('${r.passengers} pax'),
            if ((r.luggage ?? 0) > 0) _InfoPill('${r.luggage} ${r.luggage == 1 ? 'bag' : 'bags'}'),
            if (r.stops.isNotEmpty) _InfoPill('${r.stops.length} stop${r.stops.length == 1 ? '' : 's'}'),
          ]),
          if (r.note != null) Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('“${r.note}”', style: t.textTheme.bodySmall),
          ),
          const SizedBox(height: 10),
          // The phone's request sheet's own buttons: Accept for the fare,
          // the fare offers where the rider takes them, and Skip.
          RequestAnswerButtons(
            request: r,
            busy: _accepting != null,
            onAccept: () => _accept(r, partner),
            onSkip: () => _dismissAlert(skipped: true),
            onOffer: canCounterOffer(requestOfferMe: r.offerMe, allowOfferMe: _allowOfferMe)
                ? (amount) => _offer(r, partner, preset: amount)
                : null,
          ),
        ]),
      ),
    );
  }
}

/// A fact about a request (cash, 1 pax) in a rounded outline: read as its
/// text, not as a chip that could be ticked.
class _InfoPill extends StatelessWidget {
  const _InfoPill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: t.colorScheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: t.textTheme.labelLarge),
    );
  }
}

/// The Accept button's words: the fare when the ride has one, else how it is
/// charged (a counter or call-centre order on the meter has no fare yet).
String acceptLabel(RideRequest r) {
  final f = r.effectiveFare;
  if (f != null) return 'Accept ${r.fareText(f)}';
  return '${r.raw['fare_mode']}' == 'meter' ? 'Accept · by meter' : 'Accept';
}

/// The Drive screen's own buttons, for support's requests (0286): the switch
/// with every check it makes, and the vehicle card's Select / Hand back.
class _ScreenRemoteActions implements DriverRemoteActions {
  _ScreenRemoteActions(this._screen);
  final _PartnerScreenState _screen;

  @override
  Future<String?> goOnline() => _screen._toggle(true);

  @override
  Future<String?> goOffline() => _screen._toggle(false);

  @override
  Future<String?> linkVehicle(String vehicleId) async {
    final why = await driverTakeVehicle(_screen.ref.read(vehicleAssignmentRepositoryProvider), vehicleId);
    if (_screen.mounted) _screen.ref.invalidate(assignableVehiclesProvider);
    return why;
  }

  @override
  Future<String?> unlinkVehicle() async {
    final why = await driverHandBackVehicle(_screen.ref.read(vehicleAssignmentRepositoryProvider));
    if (_screen.mounted) _screen.ref.invalidate(assignableVehiclesProvider);
    return why;
  }
}
