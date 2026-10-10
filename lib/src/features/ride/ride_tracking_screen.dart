import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/active_location.dart';
import '../../admin/screens/commerce/get_coin.dart' show formatCoins;
import '../../core/fare_coins.dart';
import '../../core/fare_offer.dart' show fareOfferStep;
import '../../core/format.dart';
import '../../core/ride_bidding.dart';
import '../../core/ride_cancel.dart';
import '../../core/ride_chat.dart' show rideChatAvailable;
import '../../core/ride_confirm.dart';
import '../../core/request_viewers.dart';
import '../../core/search_stage.dart';
import '../../core/search_timer.dart';
import '../../config.dart';
import '../../core/sos.dart';
import '../../data/fare_coin_store.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/cancel_request_prompt.dart';
import '../../widgets/common.dart';
import '../../widgets/map_sheet_layout.dart';
import 'demo_ride.dart';
import 'confirm_parts.dart' show AutoAcceptIcon, ConfirmSwitch;
import 'live_ride_map.dart';
import 'ride_call_screen.dart' show RideCallButton;
import 'ride_chat_screen.dart' show RideChatBadge;
import 'searching_parts.dart';
import 'shared_ride_screen.dart' show shareRide;
import '../../widgets/ride_stop_tiles.dart';
import '../profile/emergency_contacts_screen.dart';
import '../safety/safety_screen.dart';
import '../wallet/wallet_screen.dart';
import '../../core/demo_mode.dart';
import 'auto_accept.dart';

final rideStreamProvider = StreamProvider.autoDispose.family<RideRequest, String>(
  (ref, id) => ref.watch(rideRepositoryProvider).watch(id),
);

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
        actions: [
          if (ride.value?.status.isOngoing ?? false)
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
          return _RidePanel(ride: r, map: LiveRideMap(ride: r), wide: MediaQuery.sizeOf(context).width >= 900);
        },
      ),
    );
  }
}

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

  /// The search's one-second clock (Expo ride-confirm): the first-minute
  /// bar, the "Raise your fare?" prompt, the expiry and the offer window.
  Timer? _tick;
  late DateTime _now = ref.read(searchClockProvider)();
  bool _askedRaise = false;
  bool _expiryShown = false;

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

  /// Drivers who have looked at the request (the bar over the sheet), and
  /// when they were last asked about.
  RequestViewers _viewers = RequestViewers.none;
  DateTime? _viewersAt;
  bool _viewersBusy = false;

  @override
  void initState() {
    super.initState();
    ref.read(fareCoinChoiceStoreProvider).chosen(widget.ride.id).then((v) {
      if (mounted && v) setState(() => _coinsChosen = true);
    }, onError: (_) {});
    _maybeClaimReward();
    _syncLocationShare();
    _syncSearch();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _askAboutCancel();
      unawaited(_pollViewers());
    });
  }

  final _cancelPrompt = CancelRequestPrompt();

  /// The driver's request to cancel, as a popup the passenger answers.
  void _askAboutCancel() {
    if (!mounted) return;
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _askAboutCancel());
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
    // Demo driver offers only on a request that takes offers.
    final demo = open && widget.ride.offerMe && ref.read(demoSettingsProvider).riderOffers;
    if (demo && _demo == null) {
      _demo = DemoOfferTimeline(widget.ride.fare ?? 0, clock: ref.read(searchClockProvider))
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
    setState(() => _now = ref.read(searchClockProvider)());
    final r = widget.ride;
    if (r.status != RideStatus.open) return;
    unawaited(_pollViewers());
    final elapsed = searchElapsed(r.createdAt, _now);
    if (!_expiryShown && elapsed >= AppConfig.requestExpiry) {
      _expiryShown = true;
      _askedRaise = true;
      unawaited(ref.read(rideRepositoryProvider).expireStaleOpen().catchError((_) {}));
      unawaited(_showExpired());
      return;
    }
    // A fixed-fare request is never offered a raise: its fare is the fare.
    if (r.offerMe &&
        shouldPromptRaise(elapsed: elapsed, offerStanding: _visibleOffer != null, alreadyAsked: _askedRaise)) {
      _askedRaise = true;
      unawaited(_promptRaise());
    }
  }

  /// Expo's sheet at the end of the first minute: raise by
  /// [searchPromptRaise], or keep the fare and go on waiting.
  Future<void> _promptRaise() async {
    final r = widget.ride;
    final fare = r.fare ?? 0;
    final raise = await showModalBottomSheet<bool>(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('No driver yet', style: Theme.of(c).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text("Drivers nearby haven't taken your request. A higher fare can help."),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('prompt-raise'),
                onPressed: () => Navigator.pop(c, true),
                child: Text('Raise fare to ${r.fareText(fare + searchPromptRaise)}'),
              ),
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep my fare')),
            ],
          ),
        ),
      ),
    );
    if (raise == true && mounted && widget.ride.status == RideStatus.open) {
      await _raise(searchPromptRaise);
      if (mounted) showInfo(context, 'You raised the fare to ${r.fareText(fare + searchPromptRaise)}');
    }
  }

  Future<void> _showExpired() async {
    await showDialog<void>(
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

  void _syncLocationShare() {
    final share = shareRiderLocation(widget.ride.status) && !widget.ride.id.startsWith('demo');
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
      final updated = await ref.read(rideRepositoryProvider).raiseFare(r.id, next);
      raised = updated != null;
      if (updated == null && mounted) showInfo(context, 'This request is no longer open.');
    });
    if (!raised) return;
    if (mounted) setState(() => _fareTarget = null);
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
    await sendSos(context, contacts,
        driver: r.hasDriver ? r.partnerName : null, plate: r.hasDriver ? r.partnerPlate : null);
  }

  /// A demo offer taken (Admin → Demo → mock driver offers): the real
  /// request is withdrawn, so no real driver turns up, and the demo trip
  /// plays out on the phone alone.
  Future<void> _acceptDemo(DemoOffer o) async {
    final r = widget.ride;
    final pickup = _ll(r.pickupLat, r.pickupLng), drop = _ll(r.dropLat, r.dropLng);
    if (pickup == null || drop == null) return;
    await _run(() => ref.read(rideRepositoryProvider).cancel(r, reason: 'Took a demo offer', by: 'rider'));
    if (!mounted) return;
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
    final reason = await showDialog<String>(context: context, builder: (_) => _CancelReasonDialog(status: r.status));
    if (reason == null) return;
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
      await ref.read(rideRepositoryProvider).cancel(r, reason: choice.reason, by: 'rider');
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
    if (offer != null) {
      views.add(SearchOfferView(
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
    return views;
  }

  /// The open request's sheet, as inDrive's: the stage and its countdown,
  /// the fare to raise, auto-accept, payment, the route and Cancel request.
  List<Widget> _searchSheet(RideRequest r) {
    final elapsed = searchElapsed(r.createdAt, _now);
    final left = searchTimeLeft(elapsed, AppConfig.requestExpiry);
    final current = r.fare ?? 0;
    final quoted = _quoted ?? current;
    final target = _target;
    String money(double v) => r.fareText(v);
    final limit = ref.watch(autoAcceptProvider)[r.id];
    // Raising the fare, confirming a raise and auto-accepting an offer are
    // bidding; a fixed-fare request has none of them.
    final bidding = r.offerMe;
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
      SearchHeader(
        bidding: bidding,
        elapsed: elapsed,
        left: formatCountdown(left),
        progress: (left.inMilliseconds / AppConfig.requestExpiry.inMilliseconds).clamp(0.0, 1.0),
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
              value: limit != null,
              onChanged: (on) {
                final n = ref.read(autoAcceptProvider.notifier);
                on ? n.set(r.id, current) : n.clear(r.id);
                final offer = _visibleOffer;
                if (on && shouldAutoAccept(limit: current, offer: offer)) _acceptOffer(offer!);
              },
            ),
          ]),
        ),
      ],
      SearchBlock(child: SearchPaymentRow(amount: money(r.effectiveFare ?? current), mode: r.paymentMode)),
      SearchBlock(child: SearchRouteCard(ride: r)),
      const SizedBox(height: 12),
      SearchGreyButton(
        key: const ValueKey('cancel-request'),
        label: 'Cancel request',
        onPressed: _busy ? null : _cancelSearch,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    final t = Theme.of(context);
    final riderCancelAsk = r.cancelRequestedAt != null && r.cancelRequestedBy == 'rider';

    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (r.status != RideStatus.open) Text(r.status.label, style: t.textTheme.headlineSmall),
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
          if (r.hasDriver)
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
                  if (r.partnerPhone != null || rideChatAvailable(r))
                    OverflowBar(
                      children: [
                        // An in-app call (migration 0131); a long press offers
                        // the phone call when the number is known.
                        RideCallButton(ride: r, peerName: r.partnerName ?? 'your driver', phone: r.partnerPhone),
                        // The in-app chat (migration 0129), not the phone's SMS app.
                        if (rideChatAvailable(r))
                          TextButton.icon(
                            key: const ValueKey('ride-message'),
                            icon: RideChatBadge(requestId: r.id, child: const Icon(Icons.chat_bubble_outline)),
                            onPressed: () => context.push('/ride/${r.id}/chat'),
                            label: const Text('Message'),
                          ),
                      ],
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
                    r.fareText(r.effectiveFare),
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
              child: BusyButton.filled(
                key: const ValueKey('ride-sos'),
                style: FilledButton.styleFrom(
                  backgroundColor: t.colorScheme.error,
                  foregroundColor: t.colorScheme.onError,
                ),
                icon: const Icon(Icons.sos),
                onPressed: () => _sos(r),
                child: const Text('SOS · Emergency'),
              ),
            ),
          // On the trip itself the X only asks: the driver approves it.
          if (r.status.isOngoing && !riderCancelAsk)
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
          if (r.status.isFinished) FilledButton(onPressed: () => context.go('/'), child: const Text('Done')),
          ],
        ],
      ),
    );
    if (widget.wide) {
      return Row(
        children: [
          SizedBox(width: 420, child: SingleChildScrollView(child: content)),
          const VerticalDivider(width: 1),
          Expanded(
            child: Stack(children: [
              Positioned.fill(child: widget.map),
              Positioned(
                top: 16,
                right: 16,
                width: 380,
                child: SingleChildScrollView(child: OfferStack(offers: _offerViews())),
              ),
            ]),
          ),
        ],
      );
    }
    // On a phone too, as the driver sees requests: the offer floats over
    // the top of the map rather than sitting in the sheet.
    // inDrive's: offers dim the whole screen under "Choose a driver".
    return Stack(children: [
      Positioned.fill(child: MapSheetLayout(map: widget.map, sheet: content)),
      if (r.status == RideStatus.open)
        Positioned.fill(
          child: ChooseDriverOverlay(offers: _offerViews(), onCancel: _busy ? null : _cancelSearch),
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
