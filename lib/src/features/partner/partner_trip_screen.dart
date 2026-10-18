import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/active_location.dart';
import '../../core/early_end.dart';
import '../../core/fare.dart' show RideService;
import '../../data/app_display_repository.dart' show rideServicesProvider, serviceBoxNamesProvider;
import '../../data/fare_tariff_repository.dart' show fareTariffsProvider;
import '../../core/region_pricing.dart';
import '../../core/format.dart';
import '../../core/navigation_app.dart';
import '../../core/trip_charges.dart';
import '../../core/trip_checkpoint.dart';
import '../../core/trip_progress.dart';
import '../../core/trip_start.dart';
import '../../core/ride_cancel.dart';
import '../../core/ride_chat.dart';
import '../../core/ride_read_aloud.dart';
import '../../core/ride_payment.dart';
import '../../data/models.dart';
import '../../data/read_aloud.dart';
import '../../data/reliability_repository.dart';
import '../../data/ride_chat_repository.dart';
import '../../data/trip_handover_repository.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/cancel_request_prompt.dart';
import '../../widgets/common.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/ride_stop_tiles.dart';
import '../ride/live_ride_map.dart';
import '../ride/cancelled_countdown.dart';
import '../ride/ride_call_screen.dart' show RideCallButton;
import '../ride/ride_chat_screen.dart' show RideChatBadge;
import '../../widgets/ble_handshake_badge.dart';
import '../../widgets/offline_ride_banner.dart';
import '../ride/ride_tracking_screen.dart' show SteadyRide, rideStreamProvider;
import '../safety/ride_sos.dart';
import '../safety/voice_protection_controller.dart';
import 'trip_handover_panel.dart';
import '../../widgets/page_style_host.dart';

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

/// One fix from the driver's phone: where, which way, and how loose.
typedef TripFix = ({LatLng at, double? heading, double? accuracy});

/// The driver's own position stream while on the trip screen. Empty when
/// location is unavailable or refused.
final tripPositionStreamProvider = Provider<Stream<TripFix> Function()>((ref) => () async* {
  try {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
    yield* Geolocator.getPositionStream(
      locationSettings: activeLocationSettings(
        ActiveLocationUse.driverTrip,
        accuracy: LocationAccuracy.high,
        distanceFilter: 15,
      ),
    ).map((p) => (at: LatLng(p.latitude, p.longitude), heading: p.heading < 0 ? null : p.heading, accuracy: p.accuracy));
  } catch (_) {}
});

/// The trip screen's clock, for the running trip time. For tests.
final tripClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Driver view of an accepted trip: navigate, arrive, verify code, start, complete.
class PartnerTripScreen extends ConsumerStatefulWidget {
  const PartnerTripScreen({super.key, required this.requestId});
  final String requestId;

  @override
  ConsumerState<PartnerTripScreen> createState() => _PartnerTripScreenState();
}

class _PartnerTripScreenState extends ConsumerState<PartnerTripScreen> {
  StreamSubscription<TripFix>? _gps;
  LatLng? _me;
  double? _heading;
  // The running trip: when this screen first saw it on trip (the row's
  // started_at wins), the distance driven since, and the last fix it counted.
  DateTime? _onTripSince;
  double _metres = 0;
  LatLng? _legFrom;
  DateTime? _legAt;
  Timer? _tick;

  /// Bumped each second of the trip clock, and by the pay-and-close
  /// countdown: only their text rebuilds.
  final _clockTicks = ValueNotifier<int>(0);

  /// Bumped on each GPS fix: only the map and the distance driven rebuild.
  final _gpsTicks = ValueNotifier<int>(0);
  RideStatus? _status;
  // Set when the driver approves the passenger's cancel here, so the end of
  // the ride isn't announced back to them.
  bool _approvedHere = false;
  DateTime _lastPublish = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false;
  late final VoiceProtectionController _voice;

  /// The passenger's messages already read out (or already there when the
  /// trip opened); null until the thread first arrives.
  Set<String>? _heard;
  String _passenger = 'Your passenger';
  late final Speaker _speaker;

  @override
  void initState() {
    super.initState();
    _speaker = ref.read(speakerProvider);
    ref.listenManual(rideMessagesProvider(widget.requestId), (_, next) {
      final thread = next.value;
      if (thread != null) _readAloud(thread);
    }, fireImmediately: true);
    _voice = ref.read(voiceProtectionProvider.notifier);
    _gps = ref.read(tripPositionStreamProvider)().listen(_onPosition, onError: (_) {});
    // VoiceProtection records the trip from the moment it starts (gated by the
    // driver's own switch inside the controller) and files it when it ends.
    // Handed over to another partner: this driver's part of the trip ends.
    ref.listenManual(rideHandoverProvider(widget.requestId), (_, next) {
      if (!tripHandedAway(next)) return;
      _tick?.cancel();
      _tick = null;
      unawaited(_voice.stopTrip());
    });
    ref.listenManual(rideStreamProvider(widget.requestId), (_, next) {
      final r = next.value;
      if (r == null) return;
      _passenger = r.passengerName;
      final before = _status;
      _status = r.status;
      final paidBefore = _payment;
      _payment = r.paymentStatus;
      // Paid and confirmed: back to waiting for rides in a few seconds.
      if (paymentJustSettled(paidBefore, r.paymentStatus)) _startClose();
      if (r.status == RideStatus.onTrip) {
        unawaited(_voice.startTrip(rideId: r.id, label: _tripLabel(r)));
        if (before != RideStatus.onTrip) _beginTrip();
      } else {
        _tick?.cancel();
        _tick = null;
        if (r.status.isFinished) unawaited(_voice.stopTrip());
      }
      final notice = passengerCancelNotice(before, r, approvedHere: _approvedHere);
      if (notice != null) WidgetsBinding.instance.addPostFrameCallback((_) => _showCancelled(notice));
      WidgetsBinding.instance.addPostFrameCallback((_) => _askAboutCancel(r));
    }, fireImmediately: true);
  }

  DateTime get _now => ref.read(tripClockProvider)();

  /// Reads the passenger's new messages out, while the trip is on and this
  /// screen is the one in front (the open chat shows them instead).
  void _readAloud(List<RideMessage> thread) {
    final me = ref.read(currentUserIdProvider);
    final heard = _heard;
    if (heard == null) {
      _heard = {for (final m in thread) m.id};
      return;
    }
    final fresh = rideMessagesToReadAloud(thread, me: me, heard: heard);
    if (fresh.isEmpty) return;
    heard.addAll(fresh.map((m) => m.id));
    final live = !(_status?.isFinished ?? false);
    final inFront = mounted && (ModalRoute.of(context)?.isCurrent ?? true);
    if (!live || !inFront || !ref.read(reliabilityProvider).readAloud || !ref.read(readAloudProvider)) return;
    for (final m in fresh) {
      unawaited(_speaker.speak(rideMessageSpeech(m, _passenger)));
    }
  }

  final _cancelPrompt = CancelRequestPrompt();

  /// The passenger's request to cancel, as a popup the driver answers.
  void _askAboutCancel(RideRequest r) {
    if (!mounted) return;
    final asking = r.cancelRequestedAt != null && r.cancelRequestedBy == 'rider' && r.status.isOngoing;
    final why = cancelReasonLabel(r.cancelReason);
    final repo = ref.read(rideRepositoryProvider);
    _cancelPrompt.update(
      context,
      askedAt: asking ? r.cancelRequestedAt : null,
      message: why == null ? 'The passenger asked to cancel.' : 'The passenger asked to cancel: $why',
      onDecline: () => _run(() => repo.declineCancellation(r.id)),
      onApprove: () => _run(() async {
        _approvedHere = true;
        try {
          await repo.approveCancellation(r.id);
        } catch (_) {
          _approvedHere = false;
          rethrow;
        }
      }),
    );
  }

  void _beginTrip() {
    _onTripSince = _now;
    _metres = 0;
    _legFrom = _me;
    _legAt = _me == null ? null : _onTripSince;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) _clockTicks.value++;
    });
  }

  /// The passenger's cancel notice is up: it closes the screen itself.
  bool _cancelNoticeUp = false;
  bool _left = false;

  void _leave() {
    if (_left || !mounted) return;
    _left = true;
    context.go('/drive');
  }

  Future<void> _showCancelled(String notice) async {
    if (!mounted) return;
    _cancelNoticeUp = true;
    await showAppDialog<void>(id: 'partner-trip.show-cancelled',
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('trip-cancelled'),
        title: const Text('Ride cancelled'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(notice),
          const SizedBox(height: 16),
          CancelledCountdown(label: 'Back to requests', onDone: () => Navigator.pop(ctx)),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Back to requests'))],
      ),
    );
    _cancelNoticeUp = false;
    _leave();
  }

  static String _tripLabel(RideRequest r) => '${r.pickupLabel} → ${r.dropLabel}';

  void _onPosition(TripFix p) {
    if (!mounted) return;
    final now = _now;
    _me = p.at;
    _heading = p.heading;
    // Only the trip itself counts toward the distance driven.
    if (_status == RideStatus.onTrip) {
      if (_legFrom != null && _legAt != null) {
        _metres += tripLegMetres(_legFrom!, p.at, now.difference(_legAt!), accuracy: p.accuracy);
      }
      if (p.accuracy == null || p.accuracy! <= tripFixMaxAccuracyMetres) {
        _legFrom = p.at;
        _legAt = now;
      }
    }
    // The map's car and the distance driven, not the screen.
    _gpsTicks.value++;
    // Share the driver's live position with the rider at most every 5 s.
    if (now.difference(_lastPublish) < const Duration(seconds: 5)) return;
    _lastPublish = now;
    ref
        .read(rideRepositoryProvider)
        .publishPartnerLocation(widget.requestId, p.at.latitude, p.at.longitude, p.heading)
        .catchError((_) {});
  }

  RidePaymentStatus? _payment;

  /// The countdown back to waiting for rides once the trip is paid
  /// ([paymentDoneClose]); null while none runs.
  Timer? _closeTimer;
  int? _closeIn;

  void _startClose() {
    if (_closeTimer != null) return;
    _closeIn = paymentDoneClose.inSeconds;
    _closeTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      _closeIn = _closeIn! - 1;
      _clockTicks.value++;
      if (_closeIn! <= 0) {
        t.cancel();
        context.go('/drive');
      }
    });
  }

  @override
  void dispose() {
    unawaited(_speaker.stop());
    _gps?.cancel();
    _tick?.cancel();
    _closeTimer?.cancel();
    _clockTicks.dispose();
    _gpsTicks.dispose();
    // Leaving the trip screen always files whatever was recorded — after the
    // unmount, since a provider can't change while the tree is being torn down.
    unawaited(Future.microtask(_voice.stopTrip));
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
    final code = await showAppDialog<String>(id: 'partner-trip.start',
      context: context,
      builder: (ctx) {
        final c = TextEditingController();
        return AlertDialog(
          key: const ValueKey('trip-code-dialog'),
          title: const Text('Enter trip code'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Ask the passenger for the 4-digit code shown in their app.'),
            const SizedBox(height: 12),
            CodeField(controller: c, length: 4),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              key: const ValueKey('trip-code-start'),
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('Start trip'),
            ),
          ],
        );
      },
    );
    if (code == null || !mounted) return;
    final clean = cleanTripCode(code);
    if (clean == null) {
      showInfo(context, 'Enter the 4-digit code.');
      return;
    }
    // The server checks the code (start_trip, 0152); the app never sees it.
    await _run(() async {
      final message = tripStartMessage(await ref.read(rideRepositoryProvider).startTrip(r.id, clean));
      if (message != null && mounted) showInfo(context, message);
    });
  }

  /// The driver cancels before pickup, with a reason; the passenger is told
  /// (see [driverCancelNotice]). Once the passenger is on board there is no
  /// cancel key: the trip is completed or ended early.
  Future<void> _cancel(RideRequest r) async {
    final reason = await showAppDialog<String>(id: 'partner-trip.cancel', context: context, builder: (_) => const _DriverCancelDialog());
    if (reason == null || !mounted) return;
    RideRequest? done;
    var answered = false;
    _approvedHere = true;
    await _run(() async {
      done = await ref.read(rideRepositoryProvider).cancelAsDriver(r.id, reason);
      answered = true;
    });
    if (!mounted) return;
    if (done != null) return context.go('/drive');
    _approvedHere = false;
    // A failed write has already been reported by _run.
    if (answered) showInfo(context, "This ride can't be cancelled now: the passenger is on board or it has ended.");
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
  ///
  /// Completing away from the drop-off ends the trip early (Expo's "End ride
  /// early?"): the fare is recalculated for the distance actually covered and
  /// confirmed first, then stored on the ride.
  Future<void> _complete(RideRequest r) async {
    double? earlyFare;
    final here = _me;
    if (endsEarly(here, _ll(r.dropLat, r.dropLng))) {
      earlyFare = await _confirmEarlyEnd(r, here!);
      if (earlyFare == null || !mounted) return;
    }
    final charges = await showAppDialog<TripCharges>(id: 'partner-trip.complete',
      context: context,
      builder: (_) => _ChargesDialog(fare: earlyFare ?? r.effectiveFare ?? 0, currency: r.currency),
    );
    if (charges == null || !mounted) return;
    await _run(() async {
      // Stamped before the status change, as Expo does, so the drop point is
      // where the driver stood when they pressed complete.
      unawaited(_checkpoint(r.id, TripCheckpoint.drop));
      await ref.read(rideRepositoryProvider).complete(r, charges: charges, earlyFare: earlyFare);
    });
  }

  /// The flag fall of the tariff [r] was priced on (Admin → Fare tariffs for
  /// its pickup and service), the least an early end may charge. The
  /// built-in TEKSI one when the cards or the catalogue can't be read.
  Future<double> _earlyEndFloor(RideRequest r) async {
    Future<T?> read<T>(Future<T> f) async {
      try {
        return await f.timeout(const Duration(seconds: 5));
      } catch (_) {
        return null;
      }
    }

    final (cards, services, names) =
        await (
          read(ref.read(fareTariffsProvider.future)),
          read(ref.read(rideServicesProvider.future)),
          read(ref.read(serviceBoxNamesProvider.future)),
        ).wait;
    final name = '${r.raw['service'] ?? ''}'.trim().toLowerCase();
    final service = (services ?? const <RideService>[]).where((s) => s.name.trim().toLowerCase() == name).firstOrNull;
    final card = rideTariffCard(
      cards ?? const [],
      r.raw,
      vehicleServiceId: service?.id,
      serviceTypes: service == null ? const {} : serviceTypeIds(service, names ?? const {}),
    );
    return earlyEndFloor(card, multiplier: service?.multiplier ?? 1);
  }

  /// Works out the early-end fare and asks the driver to confirm it; null
  /// keeps driving. The distance covered is the road route from the pickup
  /// to here (as Expo measured it), else what this screen counted.
  Future<double?> _confirmEarlyEnd(RideRequest r, LatLng here) async {
    final geo = ref.read(geoServiceProvider);
    final pickup = _ll(r.pickupLat, r.pickupLng), drop = _ll(r.dropLat, r.dropLng);
    Future<double?> km(LatLng? a, LatLng? b) async {
      if (a == null || b == null) return null;
      try {
        return (await geo.route(a, b)).distanceKm;
      } catch (_) {
        return null;
      }
    }

    setState(() => _busy = true);
    final (routed, planned) = await (km(pickup, here), r.distanceKm != null ? Future.value(r.distanceKm) : km(pickup, drop)).wait;
    if (!mounted) return null;
    setState(() => _busy = false);
    final driven = routed ?? (_metres > 0 ? _metres / 1000 : null);
    final agreed = r.effectiveFare ?? 0;
    final fare = earlyEndFare(
      agreed: agreed,
      plannedKm: planned,
      drivenKm: driven,
      pricing: RegionPricing.fromRide(r.raw),
      floor: await _earlyEndFloor(r),
    );
    if (!mounted) return null;
    final go = await showAppDialog<bool>(id: 'partner-trip.km',
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('early-end'),
        title: const Text('End ride early?'),
        content: Text(
          [
            "You haven't reached the drop-off yet.",
            if (driven != null && planned != null)
              'The fare is recalculated for the ${driven.toStringAsFixed(1)} km driven of the '
                  '${planned.toStringAsFixed(1)} km booked: ${r.fareText(fare)} '
                  'instead of ${r.fareText(agreed)}.'
            else
              "The distance driven can't be measured, so the booked fare of ${r.fareText(agreed)} stands.",
          ].join('\n\n'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep driving')),
          FilledButton(
            key: const ValueKey('early-end-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End ride here'),
          ),
        ],
      ),
    );
    return go == true ? fare : null;
  }

  void _navigate(LatLng to) {
    final url = navigationUri(ref.read(navigationAppProvider), to.latitude, to.longitude);
    launchUrl(url, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    // The car's position on the row moves every few seconds: only the map
    // follows it ([SteadyRide]).
    final ride = ref.watch(rideStreamProvider(widget.requestId).select(SteadyRide.new)).value;
    // While the trip is on there is no way back off this screen: the ride
    // ends by completing it (or cancelling before pickup), not by leaving,
    // or by handing it over (migration 0199).
    final away = tripHandedAway(ref.watch(rideHandoverProvider(widget.requestId)));
    final onTrip = (ride.value?.status.isOngoing ?? false) && !away;
    return PopScope(
      canPop: !onTrip,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !onTrip) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Finish the trip to leave this screen.')));
      },
      child: _scaffold(ride, onTrip),
    );
  }

  Widget _readAloudToggle() {
    final on = ref.watch(readAloudProvider);
    return IconButton(
      key: const ValueKey('read-aloud-toggle'),
      tooltip: on ? 'Stop reading messages aloud' : 'Read messages aloud',
      isSelected: on,
      icon: Icon(on ? Icons.volume_up_outlined : Icons.volume_off_outlined),
      onPressed: () {
        ref.read(readAloudProvider.notifier).set(!on);
        if (on) unawaited(_speaker.stop());
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(on ? 'Messages won\'t be read aloud.' : 'Passenger messages will be read aloud.')),
          );
      },
    );
  }

  Widget _scaffold(AsyncValue<RideRequest> ride, bool onTrip) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Current trip'),
        automaticallyImplyLeading: false,
        leading: onTrip
            ? null
            : BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/drive')),
        // Admin → Reliability can take read-aloud away altogether.
        actions: [if (ref.watch(reliabilityProvider).readAloud) _readAloudToggle()],
      ),
      body: AsyncView(
        value: ride,
        onRetry: () => ref.invalidate(rideStreamProvider(widget.requestId)),
        data: (r) {
          // SOS floats on the map for the whole trip, as for the passenger.
          final map = Stack(children: [
            Positioned.fill(
              child: Consumer(
                builder: (_, ref, _) {
                  final live = ref.watch(rideStreamProvider(widget.requestId)).value ?? r;
                  return ValueListenableBuilder(
                    valueListenable: _gpsTicks,
                    builder: (_, _, _) => LiveRideMap(
                      ride: live,
                      partner: true,
                      driverAt: _me,
                      driverHeading: _heading,
                      now: ref.read(tripClockProvider),
                    ),
                  );
                },
              ),
            ),
            if (r.status.isOngoing && r.status != RideStatus.open)
              Positioned.fill(
                child: RideSosFab(onPressed: () => showRideSos(context, ref, plate: r.partnerPlate, rideId: r.id)),
              ),
          ]);
          final wide = MediaQuery.sizeOf(context).width >= 900;
          // On a phone the step's main button (arrived / start / complete) is
          // pinned under the sheet, so it is in view however far down the
          // sheet sits; on a wide screen it stays in the panel.
          final primary = wide ? null : _primaryAction(r);
          final panel = _panel(r, primaryInFooter: primary != null);
          final Widget body = wide
              ? Row(children: [
                  SizedBox(width: 420, child: SingleChildScrollView(child: panel)),
                  const VerticalDivider(width: 1),
                  Expanded(child: map),
                ])
              : MapSheetLayout(
                  map: map,
                  sheet: panel,
                  footer: primary == null
                      ? null
                      : Material(
                          key: const ValueKey('trip-footer'),
                          color: Theme.of(context).colorScheme.surface,
                          elevation: 8,
                          child: SafeArea(
                            top: false,
                            child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 8), child: primary),
                          ),
                        ),
                );
          if (!r.fromCache) return body;
          return Column(
            children: [
              OfflineRideBanner(cachedAt: r.cachedAt!),
              Expanded(child: body),
            ],
          );
        },
      ),
    );
  }

  /// The step's one main button, or null when the step has none (or the
  /// ride was handed over).
  Widget? _primaryAction(RideRequest r) {
    final handover = ref.watch(rideHandoverProvider(r.id));
    if (tripHandedAway(handover)) return null;
    final meeting = tripHandoverMeeting(r, handover);
    return switch (r.status) {
      RideStatus.accepted => BusyButton.filled(
        key: const ValueKey('trip-arrive'),
        onPressed: _busy ? null : () => _arrive(r),
        child: const Text("I've arrived"),
      ),
      RideStatus.arrived => BusyButton.filled(onPressed: _busy ? null : () => _start(r), child: const Text('Start trip')),
      RideStatus.onTrip when !meeting => BusyButton.filled(
        key: const ValueKey('trip-complete'),
        onPressed: _busy ? null : () => _complete(r),
        child: Text('Complete trip · collect ${r.fareText(r.effectiveFare)}'),
      ),
      _ => null,
    };
  }

  /// The trip's details and actions; [primaryInFooter] leaves out the main
  /// button, pinned under the sheet instead ([_primaryAction]).
  Widget _panel(RideRequest r, {bool primaryInFooter = false}) {
    final t = Theme.of(context);
    final handover = ref.watch(rideHandoverProvider(r.id));
    // Handed over: the ride is no longer this driver's to read or drive.
    if (tripHandedAway(handover)) return HandedOverView(ride: r, handover: handover!, onDone: _leave);
    final meeting = tripHandoverMeeting(r, handover);
    final target = meeting
        ? _ll(r.handoverMeetLat, r.handoverMeetLng)
        : r.status == RideStatus.onTrip
        ? _ll(r.dropLat, r.dropLng)
        : _ll(r.pickupLat, r.pickupLng);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(switch (r.status) {
          _ when meeting => 'Meet the car',
          RideStatus.accepted => 'Head to pickup',
          RideStatus.arrived => 'Waiting for passenger',
          RideStatus.onTrip => 'Drive to destination',
          _ => r.status.label,
        }, style: t.textTheme.headlineSmall),
        const SizedBox(height: 12),
        Card(
          child: Column(children: [
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(r.passengerName),
              // Two pieces with their own icons and no separator, each kept
              // whole, so large text wraps them cleanly onto two lines.
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 12, runSpacing: 2, children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.person_outline, size: 16),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text('${r.passengers} passenger${r.passengers == 1 ? '' : 's'}', key: const ValueKey('trip-pax')),
                    ),
                  ]),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.payments_outlined, size: 16),
                    const SizedBox(width: 4),
                    Flexible(child: Text(r.paymentMode, key: const ValueKey('trip-payment'))),
                  ]),
                ]),
                if (r.isForOthers) Text('Booked by ${r.riderName ?? 'another rider'}'),
              ]),
              isThreeLine: r.isForOthers,
              // No Message or Call once the ride is cancelled.
              trailing: !rideContactAllowed(r) ? null : Row(mainAxisSize: MainAxisSize.min, children: [
                // The in-app chat with the passenger (migration 0129).
                IconButton(
                  key: const ValueKey('trip-message'),
                  tooltip: 'Message ${r.passengerName}',
                  icon: RideChatBadge(requestId: r.id, child: const Icon(Icons.chat_bubble_outline)),
                  onPressed: () => context.push('/drive/trip/${r.id}/chat'),
                ),
                // An in-app call to the rider's account (migration 0131); a
                // long press offers the phone call when the number is known.
                RideCallButton(ride: r, peerName: r.passengerName, phone: r.passengerPhone, compact: true),
              ]),
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
              trailing: Text(r.fareText(r.effectiveFare),
                  style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
        if (r.status == RideStatus.onTrip) ...[
          const SizedBox(height: 8),
          Wrap(key: const ValueKey('trip-meter'), crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Icon(Icons.timer_outlined, size: 18),
            const SizedBox(width: 6),
            ValueListenableBuilder(
              valueListenable: _clockTicks,
              builder: (_, _, _) => Text(
                  formatTripElapsed(tripElapsed(startedAt: r.startedAt, firstSeen: _onTripSince, now: _now)),
                  style: t.textTheme.titleMedium),
            ),
            const SizedBox(width: 16),
            const Icon(Icons.route_outlined, size: 18),
            const SizedBox(width: 6),
            ValueListenableBuilder(
              valueListenable: _gpsTicks,
              builder: (_, _, _) =>
                  Text('${(_metres / 1000).toStringAsFixed(1)} km driven', style: t.textTheme.titleMedium),
            ),
          ]),
        ],
        const SizedBox(height: 12),
        const _VoiceProtectionPill(),
        if (r.status.isOngoing && target != null)
          OutlinedButton.icon(
            icon: const Icon(Icons.navigation_outlined),
            label: const Text('Navigate'),
            onPressed: () => _navigate(target),
          ),
        // Asking another partner to take over, or meeting the car (0199).
        TripHandoverPanel(ride: r),
        const SizedBox(height: 8),
        // The phones find each other at the kerb (Phase D); the code still works.
        if (r.status == RideStatus.accepted || r.status == RideStatus.arrived)
          BleHandshakeBadge(rideId: r.id, status: r.status.db, driver: true),
        if (!primaryInFooter) ?_primaryAction(r),
        if (driverMayCancel(r.status))
          BusyButton.text(
            key: const ValueKey('trip-cancel'),
            onPressed: _busy ? null : () => _cancel(r),
            child: const Text('Cancel ride'),
          ),
        if (r.status == RideStatus.completed) _CollectCard(ride: r),
        if (r.status == RideStatus.completed)
          OutlinedButton.icon(
            key: const ValueKey('trip-receipt'),
            icon: const Icon(Icons.receipt_long_outlined),
            label: const Text('View receipt'),
            onPressed: () => context.push('/trips/${r.id}'),
          ),
        // Cancelled: the screen closes by itself (the passenger's cancel
        // notice, when it is up, runs the same countdown).
        if (r.status == RideStatus.cancelled) ...[
          CancelledCountdown(
            label: 'Back to requests',
            onDone: () {
              if (!_cancelNoticeUp) _leave();
            },
          ),
          const SizedBox(height: 12),
        ],
        if (r.status.isFinished)
          FilledButton(
            key: const ValueKey('trip-back-to-requests'),
            onPressed: _leave,
            child: ValueListenableBuilder(
              valueListenable: _clockTicks,
              builder: (_, _, _) => Text(_closeIn == null ? 'Back to requests' : 'Back to requests ($_closeIn)'),
            ),
          ),
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
///
/// Below it, where the passenger's payment stands (migration 0142): waiting,
/// paid in cash (the driver confirms they received it), or paid.
class _CollectCard extends ConsumerWidget {
  const _CollectCard({required this.ride});
  final RideRequest ride;

  static Widget _amountRow(ThemeData t, String label, String amount, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(16, 8, 24, 0),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
        const SizedBox(width: 12),
        Text(amount, style: t.textTheme.bodyMedium),
      ],
    ),
  );

  Future<void> _confirmCash(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(rideRepositoryProvider).confirmRideCash(ride.id);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ride, t = Theme.of(context);
    final coins = r.fareCoinsValue;
    final payment = r.paymentStatus;
    final paidOnline = payment == RidePaymentStatus.paid && r.paidMethod == RidePayMethod.getWallet;
    return Card(
      key: const ValueKey('trip-collect'),
      child: Column(children: [
        // The fare, then each thing added to it (surcharges, taxes, tolls,
        // other charges), so the total adds up on screen.
        if (r.chargeLines.isNotEmpty || (r.tollCharges ?? 0) > 0 || (r.otherCharges ?? 0) > 0) ...[
          _amountRow(t, 'Trip fare', formatMoney(r.effectiveFare, r.currency), key: const ValueKey('trip-collect-fare')),
          for (final l in r.chargeLines) _amountRow(t, l.label, formatMoney(l.amount, r.currency)),
          if ((r.tollCharges ?? 0) > 0)
            _amountRow(t, 'Tolls', formatMoney(r.tollCharges, r.currency), key: const ValueKey('trip-collect-tolls')),
          if ((r.otherCharges ?? 0) > 0)
            _amountRow(
              t,
              (r.otherChargesNote ?? '').trim().isEmpty ? 'Other charges' : 'Other charges · ${r.otherChargesNote!.trim()}',
              formatMoney(r.otherCharges, r.currency),
              key: const ValueKey('trip-collect-other'),
            ),
        ],
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
        if (paidOnline)
          ListTile(
            key: const ValueKey('trip-collect-wallet'),
            leading: const Icon(Icons.account_balance_wallet_outlined),
            title: const Text('Paid with GET.wallet'),
            subtitle: const Text('Added to your GET.wallet'),
            trailing: Text('−${formatMoney(r.paidAmount, r.currency)}'),
          ),
        const Divider(height: 1),
        ListTile(
          title: const Text('Collect from passenger', style: TextStyle(fontWeight: FontWeight.w700)),
          trailing: Text(formatMoney(paidOnline ? 0 : r.cashDue, r.currency),
              style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
        if (payment != null) ...[
          const Divider(height: 1),
          switch (payment) {
            RidePaymentStatus.due => ListTile(
                key: const ValueKey('trip-payment-due'),
                leading: const Icon(Icons.hourglass_top),
                title: const Text('Waiting for the passenger to pay'),
                subtitle: const Text('Paid you in cash? Confirm it below.'),
              ),
            RidePaymentStatus.cashPending => ListTile(
                key: const ValueKey('trip-payment-cash'),
                tileColor: t.colorScheme.tertiaryContainer,
                leading: Icon(Icons.payments_outlined, color: t.colorScheme.onTertiaryContainer),
                title: Text('Passenger paid in cash',
                    style: TextStyle(color: t.colorScheme.onTertiaryContainer, fontWeight: FontWeight.w700)),
                subtitle: Text('Confirm you received ${formatMoney(r.cashDue, r.currency)}',
                    style: TextStyle(color: t.colorScheme.onTertiaryContainer)),
              ),
            RidePaymentStatus.paid => ListTile(
                key: const ValueKey('trip-payment-paid'),
                leading: const Icon(Icons.check_circle, color: Colors.green),
                title: Text(switch (r.paidMethod) {
                  RidePayMethod.cash => 'Cash received',
                  RidePayMethod.getCoin => 'Paid with GET.coin',
                  RidePayMethod.getWallet => 'Paid with GET.wallet',
                  null => 'Paid',
                }),
                trailing: r.paidAmount == null ? null : Text(formatMoney(r.paidAmount, r.currency)),
              ),
          },
          if (payment != RidePaymentStatus.paid)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: payment == RidePaymentStatus.cashPending
                    ? BusyButton.filled(
                        key: const ValueKey('trip-confirm-cash'),
                        icon: const Icon(Icons.check),
                        onPressed: () => _confirmCash(context, ref),
                        child: const Text('Confirm cash received'),
                      )
                    : BusyButton.outlined(
                        key: const ValueKey('trip-confirm-cash'),
                        icon: const Icon(Icons.check),
                        onPressed: () => _confirmCash(context, ref),
                        child: const Text('Confirm cash received'),
                      ),
              ),
            ),
        ],
      ]),
    );
  }
}

/// Expo's driver "Why are you cancelling?" sheet: one reason, required;
/// "Other" needs the driver's own words. Pops the value to store, or null to
/// keep the ride.
class _DriverCancelDialog extends StatefulWidget {
  const _DriverCancelDialog();

  @override
  State<_DriverCancelDialog> createState() => _DriverCancelDialogState();
}

class _DriverCancelDialogState extends State<_DriverCancelDialog> {
  String? _picked;
  final _other = TextEditingController();

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = cancelReasonValue(_picked, _other.text);
    return AlertDialog(
      key: const ValueKey('driver-cancel-dialog'),
      title: const Text('Cancel this ride?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("The passenger will be told you cancelled. You can't cancel once they're on board."),
            const SizedBox(height: 8),
            Text('Why are you cancelling?', style: Theme.of(context).textTheme.titleSmall),
            RadioGroup<String>(
              groupValue: _picked,
              onChanged: (v) => setState(() => _picked = v),
              child: Column(
                children: [
                  for (final reason in driverCancelReasons)
                    RadioListTile<String>(
                      key: ValueKey('driver-cancel-reason-${reason.id}'),
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
                key: const ValueKey('driver-cancel-reason-text'),
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
          key: const ValueKey('driver-cancel-confirm'),
          onPressed: value == null ? null : () => Navigator.pop(context, value),
          child: const Text('Cancel ride'),
        ),
      ],
    );
  }
}
