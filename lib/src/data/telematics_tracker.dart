// The driver app's side of telematics (migration 0255): how far the driver
// drives while online, and on each trip to the pickup and with the
// passenger, from the phone's own location stream (or the odometer of a
// linked OBD-II reader), reported to the server which caps it.
//
// Battery: the stream is the one the Drive screen already keeps while the
// driver is online (the same settings, so the OS shares one GPS session),
// open only while online or a trip is under way; each fix costs a sum.
// Online km go up every [TelematicsTracker.flushEvery] and when going
// offline; a trip's at its checkpoints.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/obd.dart' show decodePid, isElmError, odometerPid;
import '../core/telematics.dart';
import '../features/partner/driver_online.dart';
import '../providers.dart';
import 'active_location.dart';
import 'models.dart';
import 'obd/obd_session.dart';

/// Where a trip is, for its kilometres.
enum _Leg { toPickup, atPickup, withPassenger }

class _RideLeg {
  _RideLeg(this.leg);
  _Leg leg;
  final km = DistanceAccumulator();
}

/// A trip checkpoint report: `telematics_ride_checkpoint`.
typedef TelematicsCheckpoint =
    Future<void> Function(String rideId, String stage, {double? km, double? odometerKm, double? estKm});

class TelematicsTracker {
  TelematicsTracker({
    required this.fixes,
    required this.reportOnline,
    required this.checkpoint,
    required this.odometer,
    required this.routeKm,
    this.flushEvery = const Duration(minutes: 5),
    this.enabled = true,
  });

  /// The phone's fixes while listened to.
  final Stream<TelematicsFix> Function() fixes;

  /// `telematics_report_online(km, source)`.
  final Future<void> Function(double km, String source) reportOnline;
  final TelematicsCheckpoint checkpoint;

  /// The linked reader's odometer, km; null without one.
  final Future<double?> Function() odometer;

  /// The app's road route, km; null when none comes.
  final Future<double?> Function(LatLng from, LatLng to) routeKm;
  final Duration flushEvery;

  /// Off: does nothing at all (widget tests, where no phone moves).
  final bool enabled;

  bool _online = false;
  bool _disposed = false;
  StreamSubscription<TelematicsFix>? _sub;
  Timer? _timer;
  final _onlineKm = DistanceAccumulator();
  double _pendingKm = 0;
  String _pendingSource = 'gps';
  double? _lastOdometer;
  bool _flushing = false;
  TelematicsFix? _last;
  final _rides = <String, _RideLeg>{};

  bool get online => _online;

  /// Whether the location stream is open (online, or a trip under way).
  bool get listening => _sub != null;

  /// Km counted online and not yet reported.
  double get unreportedKm => _onlineKm.metres / 1000 + _pendingKm;

  /// The km driven with the passenger on [rideId] so far, as the phone
  /// counted them; null when it isn't counting that leg (an hourly hire's
  /// End hire starts its km box from it, 0326).
  double? passengerKm(String rideId) {
    final r = _rides[rideId];
    return r == null || r.leg != _Leg.withPassenger ? null : r.km.metres / 1000;
  }

  void setOnline(bool online) {
    if (!enabled || _disposed || online == _online) return;
    _online = online;
    _timer?.cancel();
    _timer = null;
    if (online) {
      _onlineKm.reset();
      _lastOdometer = null;
      unawaited(_odometerBaseline());
      _timer = Timer.periodic(flushEvery, (_) => unawaited(flush()));
    } else {
      unawaited(flush());
    }
    _listen();
  }

  Future<void> _odometerBaseline() async {
    try {
      _lastOdometer ??= await odometer();
    } catch (_) {}
  }

  void _listen() {
    final want = _online || _rides.isNotEmpty;
    if (want && _sub == null) {
      _sub = fixes().listen(_onFix, onError: (Object _) {});
    } else if (!want && _sub != null) {
      unawaited(_sub!.cancel());
      _sub = null;
    }
  }

  void _onFix(TelematicsFix f) {
    _last = f;
    if (_online) _onlineKm.add(f);
    for (final r in _rides.values) {
      if (r.leg != _Leg.atPickup) r.km.add(f);
    }
  }

  /// Reports the online km counted since the last report: the odometer's
  /// difference when a reader answered at both ends, else the GPS's. A
  /// report that fails is added to the next.
  Future<void> flush() async {
    if (!enabled || _flushing) return;
    _flushing = true;
    try {
      final gps = _onlineKm.take() / 1000;
      double? odo;
      try {
        odo = await odometer();
      } catch (_) {}
      final before = _lastOdometer;
      var km = gps, source = 'gps';
      if (odo != null && before != null && odo >= before && odo - before <= gps * 3 + 5) {
        km = odo - before;
        source = 'obd';
      }
      if (odo != null) _lastOdometer = odo;
      if (_pendingKm > 0) {
        km += _pendingKm;
        if (_pendingSource == 'gps') source = 'gps';
      }
      _pendingKm = 0;
      if (km < 0.001) return;
      try {
        await reportOnline(double.parse(km.toStringAsFixed(3)), source);
      } catch (_) {
        // Kept for the next report (the server caps it by the time between).
        _pendingKm = km > 500 ? 500 : km;
        _pendingSource = source;
      }
    } finally {
      _flushing = false;
    }
  }

  /// The trip screen's row of the driver's ride, each time it changes:
  /// accepted starts the way to the pickup (with the route estimate),
  /// arrived reports it, on trip starts the passenger's part, completed
  /// reports it. A step the app did not see begin is not reported.
  void onRide(RideRequest r) {
    if (!enabled || _disposed) return;
    final id = r.id;
    final leg = _rides[id];
    switch (r.status) {
      case RideStatus.accepted:
        if (leg != null) return;
        _rides[id] = _RideLeg(_Leg.toPickup);
        _listen();
        unawaited(_accept(r));
      case RideStatus.arrived:
        if (leg == null) {
          _rides[id] = _RideLeg(_Leg.atPickup);
          _listen();
        } else if (leg.leg == _Leg.toPickup) {
          leg.leg = _Leg.atPickup;
          final km = leg.km.take() / 1000;
          unawaited(_send(id, 'arrive', km: km));
        }
      case RideStatus.onTrip:
        if (leg == null || leg.leg == _Leg.withPassenger) return;
        if (leg.leg == _Leg.toPickup) {
          final km = leg.km.take() / 1000;
          unawaited(_send(id, 'arrive', km: km));
        }
        leg.leg = _Leg.withPassenger;
        leg.km.reset();
        if (_last != null) leg.km.add(_last!);
        unawaited(_send(id, 'start'));
      case RideStatus.completed:
        _rides.remove(id);
        _listen();
        if (leg?.leg == _Leg.withPassenger) {
          final km = leg!.km.take() / 1000;
          unawaited(_send(id, 'complete', km: km));
        }
      case RideStatus.cancelled || RideStatus.expired || RideStatus.open:
        if (_rides.remove(id) != null) _listen();
    }
  }

  Future<void> _accept(RideRequest r) async {
    final leg = _rides[r.id];
    if (_last != null) leg?.km.add(_last!);
    final aLat = (r.raw['partner_accept_lat'] as num?)?.toDouble() ?? _last?.lat;
    final aLng = (r.raw['partner_accept_lng'] as num?)?.toDouble() ?? _last?.lng;
    double? est;
    if (aLat != null && aLng != null && r.pickupLat != null && r.pickupLng != null) {
      try {
        est = await routeKm(LatLng(aLat, aLng), LatLng(r.pickupLat!, r.pickupLng!));
      } catch (_) {}
    }
    await _send(r.id, 'accept', estKm: est);
  }

  /// One checkpoint with the odometer (when a reader answers); tried twice.
  Future<void> _send(String id, String stage, {double? km, double? estKm}) async {
    double? odo;
    try {
      odo = await odometer();
    } catch (_) {}
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await checkpoint(
          id,
          stage,
          km: km == null ? null : double.parse(km.toStringAsFixed(3)),
          odometerKm: odo,
          estKm: estKm == null ? null : double.parse(estKm.toStringAsFixed(2)),
        );
        return;
      } catch (_) {
        if (_disposed) return;
        await Future<void>.delayed(const Duration(seconds: 15));
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    if (_online) unawaited(flush());
    _disposed = true;
    _timer?.cancel();
    unawaited(_sub?.cancel());
    _sub = null;
    _rides.clear();
  }
}

/// The odometer of a linked OBD-II reader (an EV profile's own when the car
/// answers through one), asked twice; null without a reader or an answer.
Future<double?> readLinkedOdometerKm(Ref ref) async {
  final state = ref.read(obdSessionProvider);
  if (!state.linked) return null;
  final ev = state.ev?.odometerKm;
  if (ev != null) return ev;
  final session = ref.read(obdSessionProvider.notifier);
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final raw = await session.request(odometerPid.command).timeout(const Duration(seconds: 4));
      if (raw == null || isElmError(raw)) return null;
      final km = decodePid(raw, odometerPid);
      if (km != null) return km;
    } catch (_) {}
  }
  return null;
}

/// The location the tracker counts: the Drive screen's own stream settings.
Stream<TelematicsFix> _phoneFixes() async* {
  try {
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
    yield* Geolocator.getPositionStream(
      locationSettings: activeLocationSettings(
        ActiveLocationUse.driverOnline,
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).map(
      (p) => (
        lat: p.latitude,
        lng: p.longitude,
        accuracy: p.accuracy.isFinite && p.accuracy > 0 ? p.accuracy : null,
        at: p.timestamp,
      ),
    );
  } catch (_) {}
}

/// Under `flutter test` nothing moves and nothing is reported.
bool get _underTest => !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

/// How the tracker is made. A seam for tests.
final telematicsTrackerFactoryProvider = Provider<TelematicsTracker Function()>(
  (ref) =>
      () => TelematicsTracker(
        enabled: !_underTest,
        fixes: _phoneFixes,
        reportOnline: (km, source) async {
          await ref.read(supabaseProvider).rpc('telematics_report_online', params: {'p_km': km, 'p_source': source});
        },
        checkpoint: (rideId, stage, {km, odometerKm, estKm}) async {
          await ref
              .read(supabaseProvider)
              .rpc(
                'telematics_ride_checkpoint',
                params: {'p_ride': rideId, 'p_stage': stage, 'p_km': km, 'p_odometer_km': odometerKm, 'p_est_km': estKm},
              );
        },
        odometer: () => readLinkedOdometerKm(ref),
        routeKm: (from, to) async =>
            (await ref.read(geoServiceProvider).route(from, to).timeout(const Duration(seconds: 12))).distanceKm,
      ),
);

/// Follows the Drive switch for as long as the app shell is up; the trip
/// screen hands it the driver's ride.
final telematicsTrackerProvider = Provider<TelematicsTracker>((ref) {
  final tracker = ref.watch(telematicsTrackerFactoryProvider)();
  ref.onDispose(tracker.dispose);
  tracker.setOnline(ref.read(driverOnlineProvider));
  ref.listen<bool>(driverOnlineProvider, (_, online) => tracker.setOnline(online));
  return tracker;
});
