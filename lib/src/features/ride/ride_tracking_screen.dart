import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../data/ride_cancel_config.dart';
import '../../data/active_location.dart';
import '../../admin/screens/commerce/get_coin.dart' show formatCoins;
import '../../core/fare_coins.dart';
import '../../core/fare_offer.dart' show fareOfferStep;
import '../../core/format.dart';
import '../../core/auth_utils.dart' show capitaliseName;
import '../../core/payment_types.dart' show paymentModeLabel;
import '../../core/ride_bidding.dart';
import '../../core/ride_cancel.dart';
import '../../core/ride_rebook.dart';
import '../../core/ride_chat.dart' show rideChatAvailable, rideContactAllowed;
import '../../core/ride_confirm.dart';
import '../../core/request_viewers.dart';
import '../../core/search_stage.dart';
import '../../core/ride_payment.dart';
import '../../core/ride_cache.dart' show sameRideApartFromLive;
import '../../core/search_timer.dart';
import '../../core/raise_nudge.dart';
import '../../config.dart';
import '../../data/app_display_repository.dart' show displaySettingsBlobProvider;
import '../../data/fare_coin_store.dart';
import '../../data/models.dart';
import '../../data/push_service.dart';
import '../../providers.dart';
import '../../widgets/ble_handshake_badge.dart';
import '../../widgets/busy.dart';
import '../../widgets/cancel_request_prompt.dart';
import '../../widgets/common.dart';
import '../../widgets/map_recenter.dart' show RecenterButton;
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/trip_safety.dart';
import 'demo_ride.dart';
import 'driver_card.dart';
import 'confirm_parts.dart' show AutoAcceptIcon, ConfirmSwitch;
import 'live_ride_map.dart';
import 'location_share_button.dart';
import '../support/call/mic_gate.dart' show primeMicForCalls;
import 'cancelled_countdown.dart';
import 'ride_call_screen.dart' show RideCallButton;
import 'ride_payment_overlay.dart';
import 'ride_chat_screen.dart' show RideChatBadge;
import 'searching_parts.dart';
import 'home_screen.dart' show nearbyDriversProvider, roundedPoint;
import 'shared_ride_screen.dart' show shareRide;
import '../../widgets/offline_ride_banner.dart';
import '../../widgets/ride_rating_card.dart';
import '../../widgets/ride_stop_tiles.dart';
import '../safety/ride_sos.dart';
import '../wallet/wallet_screen.dart';
import '../../core/demo_mode.dart';
import 'auto_accept.dart';
import '../my_ride/my_ride_parts.dart' show MyRideSearchBanner;
import 'rider_handover_card.dart';
import '../../widgets/page_style_host.dart';

final rideStreamProvider = StreamProvider.autoDispose.family<RideRequest, String>((ref, id) {
  // A demo rider's request lives on the phone alone: it is never asked of
  // the server.
  if (isDemoRideId(id)) {
    final ride = ref.watch(demoRidesProvider.select((m) => m[id]));
    return ride == null ? Stream.error(StateError('This demo request has ended.')) : Stream.value(ride);
  }
  return ref.watch(rideRepositoryProvider).watch(id);
});

/// The ride's trip code, for its rider (migration 0152); null when there is
/// none to read.
final tripCodeProvider = FutureProvider.autoDispose.family<String?, String>((ref, id) async {
  if (isDemoRideId(id)) return null;
  try {
    return await ref.watch(rideRepositoryProvider).tripCode(id);
  } catch (_) {
    return null;
  }
});

/// The clock the search countdowns read (overridden in tests).
final searchClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// The rider's own position while a driver is on the way, for sharing on the
/// request row (overridden in tests). Empty when location is refused.
final riderPositionStreamProvider = Provider<Stream<LatLng> Function()>((ref) => () async* {
  try {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
    yield* Geolocator.getPositionStream(
      locationSettings: activeLocationSettings(
        ActiveLocationUse.riderTrip,
        accuracy: LocationAccuracy.medium,
        distanceFilter: 10,
      ),
    ).map((p) => LatLng(p.latitude, p.longitude));
  } catch (_) {}
});

LatLng? _ll(double? lat, double? lng) => lat == null || lng == null ? null : LatLng(lat, lng);

/// A ride as the tracking screen's sheet follows it: equal to the last one
/// when only the live positions (or `updated_at`) moved, so a position
/// update leaves the sheet alone ([sameRideApartFromLive]).
class SteadyRide {
  SteadyRide(this.value);
  final AsyncValue<RideRequest> value;

  @override
  bool operator ==(Object other) {
    if (other is! SteadyRide) return false;
    final a = value, b = other.value;
    if (identical(a, b)) return true;
    if (a.runtimeType != b.runtimeType || a.isLoading != b.isLoading || a.error != b.error) return false;
    final x = a.value, y = b.value;
    if (x == null || y == null) return identical(x, y);
    return x.cachedAt == y.cachedAt && sameRideApartFromLive(x.raw, y.raw);
  }

  @override
  int get hashCode => value.value?.id.hashCode ?? 0;
}

/// The ride's map, following every change of the ride (the driver's live
/// position included) on its own.
class _TrackingMap extends ConsumerWidget {
  const _TrackingMap({required this.ride});

  /// The ride as the sheet last saw it, until the stream has one.
  final RideRequest ride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(rideStreamProvider(ride.id)).value ?? ride;
    return LiveRideMap(
      ride: r,
      riderPosition: ref.read(riderPositionStreamProvider),
      topButton: LocationShareButton(ride: r),
    );
  }
}

/// Rider view of one request: searching → driver assigned → on trip → done.
class RideTrackingScreen extends ConsumerWidget {
  const RideTrackingScreen({super.key, required this.requestId});
  final String requestId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The positions move every few seconds on a live trip: they only
    // rebuild the map ([_TrackingMap]), not the screen and its sheet.
    final ride = ref.watch(rideStreamProvider(requestId).select(SteadyRide.new)).value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your ride'),
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/')),
        actions: [
          if ((ride.value?.status.isOngoing ?? false) && !isDemoRideId(requestId))
            BusyIconButton(
              key: const ValueKey('share-ride'),
              tooltip: 'Share ride',
              icon: const Icon(Icons.share_outlined),
              onPressed: () => shareRide(context, ref, ride.value!),
            ),
        ],
      ),
      body: AsyncView(
        value: ride,
        onRetry: () => ref.invalidate(rideStreamProvider(requestId)),
        data: (r) {
          // The panel lays the screen out: a driver's offer flies in over
          // the map; on a wide (desktop) screen the panel sits beside it.
          final panel = _RidePanel(
            ride: r,
            map: _TrackingMap(ride: r),
            wide: MediaQuery.sizeOf(context).width >= 900,
          );
          if (!r.fromCache) return panel;
          return Column(
            children: [
              OfflineRideBanner(cachedAt: r.cachedAt!),
              Expanded(child: panel),
            ],
          );
        },
      ),
    );
  }
}

/// How far from the map's right edge the wide layout's offer cards stand:
/// clear of the map's buttons ([LiveRideMap]'s layers and recenter, 12 in
/// from the edge and [RecenterButton.size] wide), with a gap.
double offersClearOfMapButtons(double paddingRight) => 12 + paddingRight + RecenterButton.size + 12;

class _RidePanel extends ConsumerStatefulWidget {
  const _RidePanel({required this.ride, required this.map, this.wide = false});
  final RideRequest ride;
  final Widget map;

  /// Desktop layout: the panel beside the map, offers over the map.
  final bool wide;

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

  /// The rider's live position, shared with the driver at most every 5 s.
  StreamSubscription<LatLng>? _position;
  DateTime _lastShare = DateTime.fromMillisecondsSinceEpoch(0);

  /// The search's one-second clock (Expo ride-confirm): the countdown,
  /// the "Raise your fare and search again" card, the expiry and the offer
  /// window.
  Timer? _tick;
  late final ValueNotifier<DateTime> _clock;
  DateTime get _now => _clock.value;
  bool _expiryShown = false;

  /// When the wait for an offer last started over: the request going out,
  /// a raise, or "Keep waiting" (null: the request's own start).
  DateTime? _nudgeFrom;

  /// The offer on screen, and when the rider first saw it.
  String? _offerKey;
  DateTime? _offerSeen;

  /// How many minutes each offer's driver is from the pickup, by road from
  /// where they made the offer (keyed by [RideOffer.key]).
  final _offerEta = <String, int>{};

  /// The fare the −/+ keys have moved to, not yet confirmed (null: the
  /// request's own fare).
  double? _fareTarget;

  /// Admin → Demo → mock driver offers, while the request is open.
  DemoOfferTimeline? _demo;

  /// A demo rider's request, on this phone alone: nothing about it goes to
  /// the server.
  bool get _isDemo => isDemoRideId(widget.ride.id);

  DemoRides get _demoRides => ref.read(demoRidesProvider.notifier);

  /// Drivers who have looked at the request (the bar over the sheet), and
  /// when they were last asked about.
  RequestViewers _viewers = RequestViewers.none;
  DateTime? _viewersAt;
  bool _viewersBusy = false;

  @override
  void initState() {
    super.initState();
    _openedCancelled = widget.ride.status == RideStatus.cancelled;
    _clock = ValueNotifier(ref.read(searchClockProvider)());
    ref.read(fareCoinChoiceStoreProvider).chosen(widget.ride.id).then((v) {
      if (mounted && v) setState(() => _coinsChosen = true);
    }, onError: (_) {});
    _maybeClaimReward();
    _syncLocationShare();
    _syncSearch();
    _primeMic();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _askAboutCancel();
      unawaited(_pollViewers());
    });
  }

  final _cancelPrompt = CancelRequestPrompt();

  /// A driver took the ride, so a call may come: ask for the microphone now,
  /// while the app is on screen, if it was never asked (see primeMicForCalls).
  bool _micPrimed = false;
  void _primeMic() {
    final r = widget.ride;
    if (_micPrimed || !r.status.isOngoing || r.id.startsWith('demo')) return;
    _micPrimed = true;
    unawaited(primeMicForCalls(ref).catchError((_) {}));
  }

  /// The driver's request to cancel, as a popup the passenger answers.
  void _askAboutCancel() {
    if (!mounted || _isDemo) return;
    final r = widget.ride;
    final asking = r.cancelRequestedAt != null && r.cancelRequestedBy == 'partner' && r.status.isOngoing;
    final repo = ref.read(rideRepositoryProvider);
    _cancelPrompt.update(
      context,
      askedAt: asking ? r.cancelRequestedAt : null,
      message: 'Your driver asked to cancel this ride.',
      onDecline: () => _run(() => repo.declineCancellation(r.id)),
      onApprove: () => _run(() => repo.approveCancellation(r.id)),
    );
  }

  @override
  void didUpdateWidget(covariant _RidePanel old) {
    super.didUpdateWidget(old);
    _maybeClaimReward();
    _syncLocationShare();
    _syncSearch();
    _primeMic();
    WidgetsBinding.instance.addPostFrameCallback((_) => _askAboutCancel());
    // Expired elsewhere (the home screen's timer, or the server's job, 0139)
    // before this screen's own clock got there: say so all the same.
    if (!_expiryShown && requestJustExpired(old.ride.status.db, widget.ride.status.db)) {
      _expiryShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showExpired());
      });
    }
    if (riderCancelDeclined(old.ride, widget.ride)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showInfo(context, 'Your driver declined the cancellation. The ride continues.');
      });
    }
  }

  @override
  void dispose() {
    _demo?.dispose();
    _tick?.cancel();
    _clock.dispose();
    _footerHeight.dispose();
    _position?.cancel();
    super.dispose();
  }

  /// Runs the one-second clock while the request is open and notes a new
  /// offer (a chime and a fresh 45-second window, as Expo's offer cards).
  void _syncSearch() {
    final open = widget.ride.status == RideStatus.open;
    if (open && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    } else if (!open) {
      _tick?.cancel();
      _tick = null;
    }
    // Demo driver offers only on a demo rider's own demo request: never
    // mixed in with a real request's offers, where taking one would have
    // had to withdraw the real request.
    final demo = open && _isDemo && ref.read(demoRiderProvider);
    if (demo && _demo == null) {
      _demo = DemoOfferTimeline(widget.ride.fare ?? 0,
          clock: ref.read(searchClockProvider), bidding: widget.ride.offerMe)
        ..addListener(() {
          if (mounted) setState(() {});
        });
    } else if (!demo && _demo != null) {
      _demo!.dispose();
      _demo = null;
    }
    // A raise landed (or the fare moved some other way): the keys start
    // again from the new fare.
    if (_fareTarget != null && (widget.ride.fare ?? 0) >= _fareTarget!) _fareTarget = null;
    final key = standingOffer(widget.ride)?.key;
    if (key != _offerKey) {
      _offerKey = key;
      _offerSeen = key == null ? null : ref.read(searchClockProvider)();
      if (key != null) {
        _routeOffer(standingOffer(widget.ride)!);
        unawaited(SystemSound.play(SystemSoundType.alert));
        unawaited(HapticFeedback.mediumImpact());
        // Booked with "Auto-accept offer of RM x": an offer at or under it
        // is taken at once.
        final offer = standingOffer(widget.ride);
        if (open && shouldAutoAccept(limit: ref.read(autoAcceptProvider)[widget.ride.id], offer: offer)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _offerKey == offer!.key) _acceptOffer(offer);
          });
        }
      }
    }
  }

  /// Works out how far the offer's driver is from the pickup, once per
  /// offer: by road where the route service answers, else its straight-line
  /// estimate. No card ETA when the offer carries no position (an older
  /// driver app).
  void _routeOffer(RideOffer o) {
    final r = widget.ride;
    final fromLat = o.fromLat, fromLng = o.fromLng, toLat = r.pickupLat, toLng = r.pickupLng;
    if (fromLat == null || fromLng == null || toLat == null || toLng == null) return;
    if (_offerEta.containsKey(o.key)) return;
    unawaited(() async {
      try {
        final route = await ref.read(geoServiceProvider).route(LatLng(fromLat, fromLng), LatLng(toLat, toLng));
        if (mounted) setState(() => _offerEta[o.key] = offerEtaMinutes(route.durationMin));
      } catch (_) {
        // No ETA on the card rather than a guess.
      }
    }());
  }

  /// The offer still inside its window, or null.
  RideOffer? get _visibleOffer {
    final offer = standingOffer(widget.ride);
    final seen = _offerSeen;
    if (offer == null || seen == null) return offer;
    return offerLapsed(_now.difference(seen), counterOfferWindow) ? null : offer;
  }

  /// Asks who has looked at the request, every [requestViewersPoll].
  Future<void> _pollViewers() async {
    final r = widget.ride;
    if (_viewersBusy || r.status != RideStatus.open || r.id.startsWith('demo')) return;
    final at = _viewersAt;
    if (at != null && _now.difference(at) < requestViewersPoll) return;
    _viewersBusy = true;
    _viewersAt = _now;
    try {
      final v = await ref.read(rideRepositoryProvider).viewers(r.id);
      if (mounted && v != _viewers) setState(() => _viewers = v);
    } catch (_) {
      // An older database, or a test double without it: no bar.
    } finally {
      _viewersBusy = false;
    }
  }

  void _onTick() {
    if (!mounted) return;
    // Only what reads the clock rebuilds: the countdown and the offer cards.
    _clock.value = ref.read(searchClockProvider)();
    final r = widget.ride;
    if (r.status != RideStatus.open) return;
    unawaited(_pollViewers());
    final elapsed = searchElapsed(r.createdAt, _now);
    if (!_expiryShown && elapsed >= AppConfig.requestExpiry) {
      _expiryShown = true;
      if (_isDemo) {
        _demoRides.expire(r.id);
      } else {
        unawaited(ref.read(rideRepositoryProvider).expireStaleOpen().catchError((_) {}));
      }
      unawaited(_showExpired());
      return;
    }
  }

  /// How long the rider has waited for an offer since the request went
  /// out, or since their last raise or "Keep waiting".
  Duration _waited(RideRequest r, DateTime now) => searchElapsed(_nudgeFrom ?? r.createdAt, now);

  /// The card's one-tap raise: the usual step, capped as every raise is.
  Future<void> _nudgeRaise() async {
    final r = widget.ride;
    final current = r.fare ?? 0;
    final next = raisedFare(current, fareOfferStep, quoted: _quoted ?? current);
    if (next <= current) return;
    var raised = false;
    await _run(() async {
      final updated = await _raiseFare(r.id, next);
      raised = updated != null;
      if (updated == null && mounted) showInfo(context, 'This request is no longer open.');
    });
    if (!raised || !mounted) return;
    setState(() {
      _nudgeFrom = _now;
      _fareTarget = null;
    });
    showInfo(context, 'You raised the fare to ${r.fareText(next)}. Searching again.');
  }

  /// A raise: on the server, or on the phone for a demo request.
  Future<RideRequest?> _raiseFare(String id, double fare) async =>
      isDemoRideId(id) ? _demoRides.raiseFare(id, fare) : ref.read(rideRepositoryProvider).raiseFare(id, fare);

  bool _closed = false;

  /// The pinned footer (Cancel request), measured so the offers' dim stops
  /// above it.
  final _footerKey = GlobalKey();
  final _footerHeight = ValueNotifier<double>(0);

  void _measureFooter() {
    if (!mounted) return;
    final box = _footerKey.currentContext?.findRenderObject() as RenderBox?;
    final h = box != null && box.attached && box.hasSize ? box.size.height : 0.0;
    if ((h - _footerHeight.value).abs() > 0.5) _footerHeight.value = h;
  }

  /// The ride was cancelled before this screen opened (set in initState).
  bool _openedCancelled = false;

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    context.go('/');
  }

  /// Home, with [trip] filled in on the confirm step ([rideRebookProvider]).
  void _bookAgain(RideRebook? trip) {
    if (_closed || !mounted) return;
    _closed = true;
    ref.read(rideRebookProvider.notifier).set(trip);
    context.go('/');
  }

  Future<void> _showExpired() async {
    await showAppDialog<void>(id: 'ride-tracking.show-expired',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Request expired'),
        content: Text(
          widget.ride.offerMe
              ? "We couldn't find a driver in time. Try again, perhaps with a higher fare."
              : "We couldn't find a driver in time. Please try again.",
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
    if (mounted) context.go('/');
  }

  /// Whether the position already shared was taken off the ride.
  bool _cleared = false;

  void _syncLocationShare() {
    final r = widget.ride;
    final demo = r.id.startsWith('demo');
    final shown = locationSharedFor(ref, r.id);
    final share = shareRiderLocation(r.status, showToDriver: shown) && !demo;
    // Turned off on the way to the pickup: the driver no longer sees the
    // last position shared either.
    final hide = !shown && !demo && (r.status == RideStatus.accepted || r.status == RideStatus.arrived);
    // The live columns as they are now: the sheet's copy of the ride is not
    // rebuilt for a change of position alone.
    final live = ref.read(rideStreamProvider(r.id)).value ?? r;
    if (hide && live.userLiveAt != null && !_cleared) {
      _cleared = true;
      ref.read(rideRepositoryProvider).clearRiderLocation(r.id).catchError((_) {});
    } else if (!hide) {
      _cleared = false;
    }
    if (share && _position == null) {
      _position = ref.read(riderPositionStreamProvider)().listen(_share, onError: (_) {});
    } else if (!share && _position != null) {
      _position!.cancel();
      _position = null;
    }
  }

  void _share(LatLng p) {
    if (DateTime.now().difference(_lastShare) < const Duration(seconds: 5)) return;
    _lastShare = DateTime.now();
    ref.read(rideRepositoryProvider).publishRiderLocation(widget.ride.id, p.latitude, p.longitude).catchError((_) {});
  }

  void _maybeClaimReward() {
    if (_rewardClaimed || widget.ride.status != RideStatus.completed || _isDemo) return;
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

  /// The fare the −/+ keys show.
  double get _target => _fareTarget ?? widget.ride.fare ?? 0;

  void _stepFare(double step) {
    final current = widget.ride.fare ?? 0;
    setState(() {
      final next = stepSearchFare(current: current, target: _target, step: step, quoted: _quoted ?? current);
      _fareTarget = next == current ? null : next;
    });
  }

  /// Confirm under the stepper: the request goes out again at the new fare.
  Future<void> _confirmRaise() async {
    final r = widget.ride;
    final next = _target;
    if (next <= (r.fare ?? 0)) return;
    final messenger = ScaffoldMessenger.of(context);
    var raised = false;
    await _run(() async {
      final updated = await _raiseFare(r.id, next);
      raised = updated != null;
      if (updated == null && mounted) showInfo(context, 'This request is no longer open.');
    });
    if (!raised) return;
    if (mounted) {
      setState(() {
        _fareTarget = null;
        _nudgeFrom = _now;
      });
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        key: ValueKey('fare-raised'),
        content: Row(children: [
          Icon(Icons.check_circle, color: Colors.white),
          SizedBox(width: 12),
          Text('You raised the fare'),
        ]),
      ));
  }

  Future<void> _acceptOffer(RideOffer o) async {
    if (_isDemo) return;
    await _run(() async {
      final won = await ref
          .read(rideRepositoryProvider)
          .acceptOffer(widget.ride.id, partnerId: o.partnerId, amount: o.amount);
      if (won == null && mounted) showInfo(context, 'That offer changed before you accepted it.');
    });
  }

  Future<void> _declineOffer(RideOffer o) async {
    if (_isDemo) return;
    await _run(() => ref.read(rideRepositoryProvider).declineOffer(widget.ride.id, partnerId: o.partnerId));
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

  /// Emergency options during a ride: call the emergency number (Expo's
  /// SOS button dialled 999) or alert emergency contacts with the location,
  /// driver and car.
  Future<void> _sos(RideRequest r) => showRideSos(
    context,
    ref,
    driver: r.hasDriver ? r.partnerName : null,
    plate: r.hasDriver ? r.partnerPlate : null,
    rideId: r.id.startsWith('demo') ? null : r.id,
  );

  /// A demo offer taken (Admin → Demo → mock driver offers, on a demo
  /// request only): the demo trip plays out on the phone alone. A real
  /// request is never touched by a demo.
  Future<void> _acceptDemo(DemoOffer o) async {
    final r = widget.ride;
    if (!r.id.startsWith('demo')) return;
    final pickup = _ll(r.pickupLat, r.pickupLng), drop = _ll(r.dropLat, r.dropLng);
    if (pickup == null || drop == null) return;
    context.go('/ride/demo',
        extra: DemoTripArgs(
          pickup: pickup,
          pickupName: r.pickupLabel,
          drop: drop,
          dropName: r.dropLabel,
          offer: o,
          currency: r.currency,
        ));
  }

  Future<void> _cancel() async {
    final r = widget.ride;
    if (r.status == RideStatus.open) return _cancelSearch();
    final reason = await showAppDialog<String>(id: 'ride-tracking.cancel', context: context, builder: (_) => _CancelReasonDialog(status: r.status));
    if (reason == null) return;
    if (_isDemo) return _demoRides.cancel(r.id, reason: reason);
    await _run(() => ref.read(rideRepositoryProvider).cancel(r, reason: reason, by: 'rider'));
  }

  /// inDrive's two cancel sheets, then back to the map.
  Future<void> _cancelSearch() async {
    final choice = await showSearchCancelSheet(context);
    if (choice == null || !mounted) return;
    final r = widget.ride;
    final messenger = ScaffoldMessenger.of(context);
    var done = false;
    await _run(() async {
      if (_isDemo) {
        _demoRides.cancel(r.id, reason: choice.reason);
      } else {
        await ref.read(rideRepositoryProvider).cancel(r, reason: choice.reason, by: 'rider');
      }
      done = true;
    });
    if (!done || !mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(key: ValueKey('request-cancelled'), content: Text('Request cancelled')));
    GoRouter.maybeOf(context)?.go('/');
  }

  /// Every offer on screen: the real standing bid and any demo ones.
  List<SearchOfferView> _offerViews() {
    final r = widget.ride;
    final views = <SearchOfferView>[];
    final offer = _visibleOffer;
    // "+RM1.00" against the rider's fare; nothing when it is their fare.
    String? difference(double amount) {
      final fare = r.fare;
      if (fare == null || (amount - fare).abs() < 0.005) return null;
      return '${amount > fare ? '+' : '−'}${r.fareText((amount - fare).abs())}';
    }

    int secondsLeft(Duration shownFor, Duration window) {
      final left = window - shownFor;
      return left.isNegative ? 0 : (left.inMilliseconds / 1000).ceil();
    }

    if (offer != null) {
      views.add(SearchOfferView(
        amount: offer.amount,
        difference: difference(offer.amount),
        secondsLeft: _offerSeen == null ? null : secondsLeft(_now.difference(_offerSeen!), counterOfferWindow),
        key: offer.key,
        cardKey: const ValueKey('ride-offer'),
        acceptKey: const ValueKey('accept-offer'),
        declineKey: const ValueKey('decline-offer'),
        price: r.fareText(offer.amount),
        yourFare: r.fare != null && (offer.amount - r.fare!).abs() < 0.005,
        progress: _offerSeen == null ? 1 : offerProgress(_now.difference(_offerSeen!), counterOfferWindow),
        name: offer.name,
        rating: offer.rating,
        vehicle: [offer.vehicle, offer.plate].whereType<String>().isEmpty
            ? null
            : [offer.vehicle, offer.plate].whereType<String>().join(' · '),
        photo: offer.photo,
        etaMin: _offerEta[offer.key],
        onAccept: _busy ? null : () => _acceptOffer(offer),
        onDecline: _busy ? null : () => _declineOffer(offer),
      ));
    }
    for (final (o, at) in _demo?.shown ?? const <(DemoOffer, DateTime)>[]) {
      views.add(SearchOfferView(
        amount: o.price,
        difference: difference(o.price),
        secondsLeft: secondsLeft(_now.difference(at), demoOfferLife),
        key: o.id,
        cardKey: ValueKey('demo-offer-${o.id}'),
        acceptKey: ValueKey('demo-accept-${o.id}'),
        declineKey: ValueKey('demo-decline-${o.id}'),
        price: r.fareText(o.price),
        yourFare: r.fare != null && (o.price - r.fare!).abs() < 0.005,
        progress: offerProgress(_now.difference(at), demoOfferLife),
        name: o.name,
        rating: o.rating,
        rides: o.rides,
        vehicle: o.vehicle,
        etaMin: o.etaMin,
        demo: true,
        onAccept: _busy ? null : () => _acceptDemo(o),
        onDecline: () => _demo?.dismiss(o),
      ));
    }
    return sortOffers(views);
  }

  /// The open request's sheet, as inDrive's: the stage and its countdown,
  /// the fare to raise, auto-accept, payment, the route and Cancel request.
  List<Widget> _searchSheet(RideRequest r) {
    final current = r.fare ?? 0;
    final quoted = _quoted ?? current;
    final target = _target;
    String money(double v) => r.fareText(v);
    final limit = ref.watch(autoAcceptProvider)[r.id];
    // Raising the fare, confirming a raise and auto-accepting an offer are
    // bidding; a fixed-fare request has none of them.
    final bidding = r.offerMe;
    // How near the drivers are, from the nearest online ones to the pickup
    // (the same read the confirm sheet's minutes come from); nothing when
    // that can't be had.
    final pickup = _ll(r.pickupLat, r.pickupLng);
    final waitHint = pickup == null || r.id.startsWith('demo')
        ? null
        : searchWaitHint(
            ref.watch(nearbyDriversProvider(roundedPoint(pickup))).value ?? const <String, double>{},
            service: r.service,
          );
    final nudgeAfter = raiseNudgeAfter(ref.watch(displaySettingsBlobProvider).value);
    final raisedTo = raisedFare(current, fareOfferStep, quoted: quoted);
    return [
      if (_viewers.any)
        DriversViewingBar(viewers: _viewers)
      else if (_demo?.viewers ?? false)
        DriversViewingBar(
          key: const ValueKey('demo-viewers'),
          viewers: const RequestViewers(viewed: 2, viewing: 2),
          demo: true,
          demoNames: demoViewerNames,
        ),
      ValueListenableBuilder(
        valueListenable: _clock,
        builder: (_, now, _) {
          final elapsed = searchElapsed(r.createdAt, now);
          final left = searchTimeLeft(elapsed, AppConfig.requestExpiry);
          final header = SearchHeader(
            bidding: bidding,
            elapsed: elapsed,
            left: formatCountdown(left),
            progress: (left.inMilliseconds / AppConfig.requestExpiry.inMilliseconds).clamp(0.0, 1.0),
            waitHint: waitHint,
            offers: (_visibleOffer == null ? 0 : 1) + (_demo?.shown.length ?? 0),
          );
          // On a phone "Choose a driver" dims the screen over the sheet and
          // carries its own "All drivers verified": the header under it
          // stands down (keeping its room, so the sheet doesn't jump).
          final covered = !widget.wide && _offerViews().isNotEmpty;
          return Visibility(
            key: const ValueKey('search-header-slot'),
            visible: !covered,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: header,
          );
        },
      ),
      // No offer for a while on a request open to offers: raise it in one
      // tap, or keep waiting. A fixed-fare request is never offered a
      // raise: its fare is the fare.
      if (bidding)
        ValueListenableBuilder(
          valueListenable: _clock,
          builder: (_, now, _) => showRaiseNudge(
                  bidding: bidding,
                  offerStanding: _visibleOffer != null,
                  waited: _waited(r, now),
                  after: nudgeAfter)
              ? SearchRaiseCard(
                  fare: money(current),
                  raisedTo: raisedTo > current ? money(raisedTo) : null,
                  onRaise: _busy ? null : _nudgeRaise,
                  onKeepWaiting: () => setState(() => _nudgeFrom = _now),
                )
              : const SizedBox.shrink(),
        ),
      // Booked with My Ride: offered to the rider's favourites first.
      if (r.isMyRide || r.isDirectBooking)
        ValueListenableBuilder(
          valueListenable: _clock,
          builder: (_, now, _) => MyRideSearchBanner(ride: r, now: now),
        ),
      const SizedBox(height: 16),
      if (bidding) ...[
        SearchFareStepper(
          amount: money(target),
          canLower: !_busy && target > current,
          canRaise: !_busy && raisedFare(target, fareOfferStep, quoted: quoted) > target,
          onLower: () => _stepFare(-fareOfferStep),
          onRaise: () => _stepFare(fareOfferStep),
          onConfirm: _busy || target <= current ? null : _confirmRaise,
          confirmLabel: target > current ? 'Confirm ${money(target)}' : 'Confirm',
        ),
        SearchBlock(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(children: [
            const AutoAcceptIcon(),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'Auto-accept an offer of ${money(limit ?? current)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ConfirmSwitch(
              key: const ValueKey('search-auto-accept'),
              semanticLabel: 'Auto-accept an offer of ${money(limit ?? current)}',
              value: limit != null,
              onChanged: (on) {
                final n = ref.read(autoAcceptProvider.notifier);
                on ? n.set(r.id, current) : n.clear(r.id);
                // Kept on the request too, so it holds with the app closed
                // (not a demo request, which the server never sees).
                if (!_isDemo) {
                  unawaited(
                    ref.read(rideRepositoryProvider).setAutoAccept(r.id, on ? current : null).catchError((_) {}),
                  );
                }
                final offer = _visibleOffer;
                if (on && shouldAutoAccept(limit: current, offer: offer)) _acceptOffer(offer!);
              },
            ),
          ]),
        ),
      ],
      SearchBlock(child: SearchPaymentRow(amount: money(r.effectiveFare ?? current), mode: r.paymentMode)),
      // The sheet never rests lower than the drop-off: at 390x844 it sat
      // behind the pinned Cancel request (or rests all the way up where it
      // can't fit).
      MapSheetRestLine(child: SearchBlock(child: SearchRouteCard(ride: r))),
      const SizedBox(height: 12),
      // On a phone it is pinned under the sheet instead ([_cancelFooter]).
      if (widget.wide) ?_cancelAction(r),
    ];
  }

  /// Cancel request while searching, Cancel ride while the driver is on the
  /// way; null otherwise (on the trip itself cancelling is asked, below).
  Widget? _cancelAction(RideRequest r) {
    if (r.status == RideStatus.open) {
      return SearchGreyButton(
        key: const ValueKey('cancel-request'),
        label: 'Cancel request',
        onPressed: _busy ? null : _cancelSearch,
      );
    }
    final asked = r.cancelRequestedAt != null && r.cancelRequestedBy == 'rider';
    if ((r.status == RideStatus.accepted || r.status == RideStatus.arrived) && !asked) {
      return BusyButton.outlined(
        key: const ValueKey('ride-cancel'),
        icon: const Icon(Icons.close),
        onPressed: _busy ? null : _cancel,
        child: const Text('Cancel ride'),
      );
    }
    return null;
  }

  /// On a phone the way to cancel stays in view under the sheet, however
  /// far down the sheet sits.
  Widget? _cancelFooter(RideRequest r) {
    final cancel = _cancelAction(r);
    if (cancel == null) return null;
    return _footer(const ValueKey('ride-cancel-footer'), cancel);
  }

  /// A finished ride's last word: the cancelled countdown and Book another
  /// ride, or Done.
  List<Widget> _finishActions(RideRequest r) => [
        // Cancelled while watching: the screen closes by itself. Opened on a
        // ride already cancelled (a link, a reload): it stays, so the
        // reason can be read.
        // Cancelled by the driver it stays until the rider leaves it (WCAG
        // 2.2.1): the trip is there to book again.
        if (r.status == RideStatus.cancelled && !_openedCancelled && !cancelledByDriver(r)) ...[
          CancelledCountdown(onDone: _close),
          const SizedBox(height: 12),
        ],
        // Once only: the driver's cancel card already gives their reason.
        if (r.status == RideStatus.cancelled &&
            _openedCancelled &&
            !cancelledByDriver(r) &&
            (r.cancelReason ?? '').trim().isNotEmpty) ...[
          Text(
            'Reason: ${cancelReasonLabel(r.cancelReason) ?? r.cancelReason!.trim()}',
            key: const ValueKey('ride-cancel-reason'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: mutedTextColor(Theme.of(context))),
          ),
          const SizedBox(height: 12),
        ],
        // The driver cancelled: the same trip, vehicle and fare on the
        // confirm step, to send to another driver.
        if (cancelledByDriver(r) && rideRebookOf(r) != null) ...[
          FilledButton(
            key: const ValueKey('ride-find-another'),
            onPressed: () => _bookAgain(rideRebookOf(r)!),
            child: const Text('Find another driver'),
          ),
          const SizedBox(height: 8),
          // The same route, the vehicle and fare chosen afresh.
          OutlinedButton(
            key: const ValueKey('ride-book-again'),
            onPressed: () => _bookAgain(rideRebookOf(r)!.routeOnly),
            child: const Text('Book another ride'),
          ),
        ]
        // Cancelled: straight on to booking again, the route kept, rather
        // than only Done.
        else if (r.status == RideStatus.cancelled)
          FilledButton(
            key: const ValueKey('ride-book-again'),
            onPressed: () => _bookAgain(rideRebookOf(r)?.routeOnly),
            child: const Text('Book another ride'),
          )
        else if (r.status.isFinished)
          FilledButton(key: const ValueKey('ride-done'), onPressed: _close, child: const Text('Done')),
      ];

  /// Pinned under the sheet at any height and clear of the home indicator
  /// (and of a browser toolbar, which reports no inset: 12 at least).
  Widget _footer(Key key, Widget child) => Material(
        key: key,
        color: Theme.of(context).colorScheme.surface,
        elevation: 8,
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: 12),
          child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 8), child: child),
        ),
      );

  Widget? _rideFooter(RideRequest r) {
    final cancel = _cancelFooter(r);
    if (cancel != null || !r.status.isFinished) return cancel;
    return _footer(
      const ValueKey('ride-finish-footer'),
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: _finishActions(r)),
    );
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureFooter());
    // Settings → Show location to your driver, switched mid-ride.
    ref.listen(showLocationToDriverProvider, (_, _) => _syncLocationShare());
    ref.listen(rideLocationOffProvider, (_, _) => _syncLocationShare());
    final r = widget.ride;
    final t = Theme.of(context);
    final riderCancelAsk = r.cancelRequestedAt != null && r.cancelRequestedBy == 'rider';
    // The code from ride_trip_codes (0152), else the ride row (older database,
    // or before it has loaded).
    final tripCode = ref.watch(tripCodeProvider(r.id)).value ?? r.otp;

    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (r.status != RideStatus.open) RideStatusTitle(ride: r),
          if (r.isForOthers)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                const Icon(Icons.person_pin_circle_outlined, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Booked for ${r.passengerName} · ${r.bookedForPhone}',
                    key: const ValueKey('booked-for'),
                    style: t.textTheme.bodyMedium,
                  ),
                ),
              ]),
            ),
          if (r.status == RideStatus.open) ...[
            const SizedBox(height: 12),
            ..._searchSheet(r),
          ] else ...[
          const SizedBox(height: 16),
          // The driver asking to hand the trip over (0199), or the new one coming.
          if (!_isDemo) ...[
            RiderHandoverCard(ride: r),
            RiderHandoverPrompt(ride: r, pushes: PushService.instance?.received),
          ],
          if (r.hasDriver)
            Card(
              child: Column(
                children: [
                  // The plate first, the car under it, then the driver.
                  DriverCardHeader(ride: r),
                  if (tripCode != null && r.status != RideStatus.onTrip)
                    ListTile(
                      key: const ValueKey('trip-code'),
                      leading: const Icon(Icons.pin_outlined),
                      title: const Text('Trip code'),
                      subtitle: const Text('Share with your driver at pickup'),
                      trailing: Text(tripCode, style: t.textTheme.headlineSmall?.copyWith(letterSpacing: 4)),
                    ),
                  // The phones find each other at the kerb (Phase D).
                  if (r.status == RideStatus.accepted || r.status == RideStatus.arrived)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: BleHandshakeBadge(rideId: r.id, status: r.status.db, driver: false),
                    ),
                  // No Message or Call once the ride is cancelled.
                  // The sheet never rests lower than this row: on a phone on
                  // its side or at large text it showed under "Cancel ride".
                  if (!_isDemo && r.status != RideStatus.cancelled && (r.partnerPhone != null || rideChatAvailable(r)))
                    MapSheetRestLine(
                      child: OverflowBar(
                      children: [
                        // An in-app call (migration 0131); a long press offers
                        // the phone call when the number is known.
                        RideCallButton(ride: r, peerName: r.partnerName ?? 'your driver', phone: r.partnerPhone),
                        // The in-app chat (migration 0129), not the phone's SMS app.
                        if (rideContactAllowed(r))
                          TextButton.icon(
                            key: const ValueKey('ride-message'),
                            icon: RideChatBadge(requestId: r.id, child: const Icon(Icons.chat_bubble_outline)),
                            onPressed: () => context.push('/ride/${r.id}/chat'),
                            label: const Text('Message'),
                          ),
                      ],
                      ),
                    ),
                ],
              ),
            ),
          if (cancelledByDriver(r))
            Card(
              key: const ValueKey('driver-cancelled'),
              color: t.colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.cancel_outlined),
                title: Text(driverCancelNotice(r)),
                subtitle: const Text('You can book another ride from the map.'),
              ),
            ),
          if ((riderCancelAsk || r.cancelRequestOutcome == 'expired') && r.status.isOngoing)
            _CancelWaitCard(
              ride: r,
              onAskAgain: () =>
                  _run(() => ref.read(rideRepositoryProvider).cancel(r, reason: r.cancelReason, by: 'rider')),
              onSupport: () => context.push(
                r.cancelTicketId == null ? '/account/support' : '/account/support/${r.cancelTicketId}',
              ),
              onSos: () => _sos(r),
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
                  // In the booking sheet's words, not the stored values.
                  title: Text(capitaliseName(r.service ?? 'Ride')),
                  subtitle: Text(
                    '${formatDistance(r.distanceKm)} · ${formatDuration(r.durationMin)} · ${paymentModeLabel(r.paymentMode)}',
                  ),
                  // A cancelled ride was never charged: not its quote as a price.
                  trailing: r.status == RideStatus.cancelled || r.status == RideStatus.expired
                      ? Text(
                          'Not charged',
                          key: const ValueKey('ride-not-charged'),
                          style: t.textTheme.titleSmall?.copyWith(color: mutedTextColor(t)),
                        )
                      : Text(
                          r.fareText(r.effectiveFare),
                          style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Trip safety (Phase D4): "Are you in the car?" / "still on your trip?".
          if (r.status == RideStatus.onTrip && !_isDemo) SafetyCheckBanner(ride: r, onHelp: () => _sos(r)),
          if (r.status == RideStatus.completed && !_isDemo) RideRatingCard(ride: r),
          if (r.status == RideStatus.completed && !_isDemo) LostItemCard(ride: r),
          // On the trip itself the X only asks: the driver approves it.
          // Before it, on a phone, Cancel ride is pinned under the sheet.
          if (r.status.isOngoing && !riderCancelAsk && (widget.wide || _cancelAction(r) == null))
            BusyButton.outlined(
              icon: const Icon(Icons.close),
              onPressed: _busy ? null : _cancel,
              child: Text(r.status == RideStatus.onTrip ? 'Request cancellation' : 'Cancel ride'),
            ),
          if (r.status == RideStatus.completed &&
              ((r.tollCharges ?? 0) > 0 || (r.otherCharges ?? 0) > 0 || r.fareCoinsValue > 0 || r.chargeLines.isNotEmpty))
            Card(
              key: const ValueKey('ride-charges'),
              child: Column(children: [
                ListTile(dense: true, title: const Text('Trip fare'),
                    trailing: Text(r.fareText(r.effectiveFare))),
                for (final (i, l) in r.chargeLines.indexed)
                  ListTile(
                    key: ValueKey(l.isTax ? 'ride-tax-$i' : 'ride-surcharge-$i'),
                    dense: true,
                    title: Text(l.label),
                    trailing: Text(formatMoney(l.amount, r.currency)),
                  ),
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
          // On a phone these sit in the footer, above the home indicator.
          if (widget.wide) ..._finishActions(r),
          ],
        ],
      ),
    );
    final layout = _layout(r, content);
    // The trip is over and not paid for: the payment popup over everything,
    // until the Done page closes it (kept up once seen here, so the payment
    // landing ends on Done rather than vanishing).
    if (r.status == RideStatus.completed &&
        (r.paymentStatus == RidePaymentStatus.due || r.paymentStatus == RidePaymentStatus.cashPending)) {
      _paymentShown = true;
    }
    if (!_paymentShown || r.status != RideStatus.completed) return layout;
    return Stack(children: [
      Positioned.fill(child: layout),
      Positioned.fill(child: RidePaymentOverlay(ride: r)),
    ]);
  }

  /// Once a driver has the ride and until it ends.
  bool _sosOn(RideRequest r) => r.status.isOngoing && r.status != RideStatus.open;

  /// The payment popup has been up on this screen.
  bool _paymentShown = false;

  Widget _layout(RideRequest r, Widget content) {
    if (widget.wide) {
      return Row(
        children: [
          SizedBox(width: 420, child: SingleChildScrollView(child: content)),
          const VerticalDivider(width: 1),
          Expanded(
            child: LayoutBuilder(builder: (context, c) {
              // The offers stand left of the map's layers and recenter
              // buttons (right edge), never over them: on a phone on its
              // side (915 × 412) the second card sat under them.
              final right = offersClearOfMapButtons(MediaQuery.paddingOf(context).right);
              final width = (c.maxWidth - right - 16).clamp(0.0, 380.0);
              return Stack(children: [
              Positioned.fill(child: widget.map),
              if (_sosOn(r)) Positioned.fill(child: RideSosFab(onPressed: () => _sos(r))),
              Positioned(
                key: const ValueKey('wide-offers'),
                top: 16,
                right: right,
                bottom: 16,
                width: width,
                child: SingleChildScrollView(
                  child: ValueListenableBuilder(
                    valueListenable: _clock,
                    builder: (_, _, _) => OfferStack(offers: _offerViews()),
                  ),
                ),
              ),
            ]);
            }),
          ),
        ],
      );
    }
    // On a phone too, as the driver sees requests: the offer floats over
    // the top of the map rather than sitting in the sheet.
    // inDrive's: offers dim the whole screen under "Choose a driver".
    return Stack(children: [
      // SOS floats on the map for the whole ride (not in the sheet).
      Positioned.fill(
        child: MapSheetLayout(
          // Always the same Stack, so the map isn't rebuilt when SOS appears.
          map: Stack(children: [
            Positioned.fill(child: widget.map),
            if (_sosOn(r)) Positioned.fill(child: RideSosFab(onPressed: () => _sos(r))),
          ]),
          sheet: content,
          footer: switch (_rideFooter(r)) {
            final f? => KeyedSubtree(key: _footerKey, child: f),
            null => null,
          },
          // A phone on its side: SOS and the map's buttons beside the sheet.
          besideWhenShort: true,
        ),
      ),
      // Down to the pinned footer, so its Cancel request stays the one way
      // to cancel while offers are up.
      if (r.status == RideStatus.open)
        Positioned.fill(
          child: ValueListenableBuilder(
            valueListenable: _footerHeight,
            builder: (_, footer, child) => Padding(
              padding: EdgeInsets.only(bottom: footer),
              child: MediaQuery.removePadding(context: context, removeBottom: footer > 0, child: child!),
            ),
            child: ValueListenableBuilder(
              valueListenable: _clock,
              builder: (_, _, _) => ChooseDriverOverlay(offers: _offerViews()),
            ),
          ),
        ),
    ]);
  }
}

/// Expo's "Why are you cancelling?" sheet: one reason, required; "Other"
/// needs the rider's own words. Pops the value to store, or null to keep
/// the ride.
class _CancelReasonDialog extends StatefulWidget {
  const _CancelReasonDialog({required this.status});
  final RideStatus status;

  @override
  State<_CancelReasonDialog> createState() => _CancelReasonDialogState();
}

class _CancelReasonDialogState extends State<_CancelReasonDialog> {
  String? _picked;
  final _other = TextEditingController();

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final value = cancelReasonValue(_picked, _other.text);
    return AlertDialog(
      title: Text(status == RideStatus.open ? 'Cancel request?' : 'Request cancellation?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (status != RideStatus.open)
              Text(
                status == RideStatus.onTrip
                    ? "You're on your trip. Your driver will be asked to approve the cancellation."
                    : 'Your driver has accepted. They will be asked to approve the cancellation.',
              ),
            const SizedBox(height: 8),
            Text('Why are you cancelling?', style: Theme.of(context).textTheme.titleSmall),
            RadioGroup<String>(
              groupValue: _picked,
              onChanged: (v) => setState(() => _picked = v),
              child: Column(
                children: [
                  for (final reason in cancelReasonsFor(status))
                    RadioListTile<String>(
                      key: ValueKey('cancel-reason-${reason.id}'),
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
                key: const ValueKey('cancel-reason-text'),
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
          onPressed: value == null ? null : () => Navigator.pop(context, value),
          child: Text(status == RideStatus.onTrip ? 'Request cancellation' : 'Cancel ride'),
        ),
      ],
    );
  }
}

/// The rider's cancellation request: how long it still waits for the
/// driver, then, when the driver didn't answer (migration 0191), what the
/// rider can do. The ride itself carries on.
class _CancelWaitCard extends ConsumerStatefulWidget {
  const _CancelWaitCard({required this.ride, required this.onAskAgain, required this.onSupport, required this.onSos});

  final RideRequest ride;
  final Future<void> Function() onAskAgain;
  final VoidCallback onSupport;
  final VoidCallback onSos;

  @override
  ConsumerState<_CancelWaitCard> createState() => _CancelWaitCardState();
}

class _CancelWaitCardState extends ConsumerState<_CancelWaitCard> {
  Timer? _timer;

  /// "Keep riding" hides the options until the rider asks again.
  DateTime? _dismissedAt;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    final t = Theme.of(context);
    final c = ref.watch(cancelRequestConfigProvider).value ?? CancelRequestConfig.standard;
    final now = DateTime.now();
    final unanswered = riderCancelUnanswered(r, now, c);
    if (!unanswered) {
      final left = riderCancelWaitLeft(r, now, c);
      if (left == null) return const SizedBox.shrink();
      return Card(
        key: const ValueKey('cancel-waiting'),
        child: ListTile(
          leading: const Icon(Icons.hourglass_top),
          title: const Text('Cancellation requested'),
          subtitle: Text('Waiting for the driver to confirm · ${cancelWaitText(left)}'),
        ),
      );
    }
    final dismissed = _dismissedAt;
    if (dismissed != null && (r.cancelRequestedAt == null || r.cancelRequestedAt!.isBefore(dismissed))) {
      return const SizedBox.shrink();
    }
    return Card(
      key: const ValueKey('cancel-unanswered'),
      color: t.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              "Your driver didn't respond",
              style: t.textTheme.titleMedium?.copyWith(
                color: t.colorScheme.onTertiaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'The ride carries on. You can ask again, contact support, or use SOS if you feel unsafe.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onTertiaryContainer),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                BusyButton.filled(
                  key: const ValueKey('cancel-ask-again'),
                  onPressed: widget.onAskAgain,
                  child: const Text('Ask again'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('cancel-support'),
                  icon: const Icon(Icons.support_agent),
                  label: const Text('Support'),
                  onPressed: widget.onSupport,
                ),
                OutlinedButton.icon(
                  key: const ValueKey('cancel-sos'),
                  style: OutlinedButton.styleFrom(foregroundColor: t.colorScheme.error),
                  icon: const Icon(Icons.sos),
                  label: const Text('SOS'),
                  onPressed: widget.onSos,
                ),
                TextButton(
                  key: const ValueKey('cancel-keep-riding'),
                  onPressed: () => setState(() => _dismissedAt = DateTime.now()),
                  child: const Text('Keep riding'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
