import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../features/partner/driver_online.dart';
import '../providers.dart';

/// Where the driver is, cheaply: the last known fix, else a quick coarse one.
/// Null without location permission (presence never asks for it).
typedef PresenceFix = Future<({double lat, double lng})?> Function();

/// Metres between two fixes (haversine).
double presenceMetres(({double lat, double lng}) a, ({double lat, double lng}) b) {
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(b.lat - a.lat), dLng = rad(b.lng - a.lng);
  final h = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(a.lat)) * math.cos(rad(b.lat)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * 6371000 * math.asin(math.min(1, math.sqrt(h)));
}

/// Whether a check-in [sinceLast] after the last report is worth sending:
/// always once [maxQuiet] has passed (the server's 3-minute expiry and
/// God View's "updated" age need a heartbeat), else only when the driver
/// has moved [minMetres] from where they last reported.
bool presenceReportDue({
  required Duration sinceLast,
  required ({double lat, double lng})? last,
  required ({double lat, double lng})? now,
  double minMetres = 15,
  Duration maxQuiet = const Duration(seconds: 30),
}) {
  if (sinceLast >= maxQuiet) return true;
  if (now == null) return false;
  if (last == null) return true;
  return presenceMetres(last, now) >= minMetres;
}

/// Tells the server whether this driver is taking rides and where they are
/// (`set_driver_presence`, migration 0145), so a new request is pushed to
/// the drivers near it rather than to every driver, and Admin → God View
/// (0270) shows them moving. Reports when the Drive switch moves and checks
/// in every [interval] (10 s) while it is on, sending only when the driver
/// has moved 15 m or 30 s have passed ([presenceReportDue]); the server
/// forgets a driver it has not heard from in 3 minutes, so a phone that dies
/// simply drops out.
class DriverPresenceReporter {
  DriverPresenceReporter({
    required this.report,
    required this.fix,
    this.interval = const Duration(seconds: 10),
    this.maxQuiet = const Duration(seconds: 30),
    this.minMetres = 15,
  });

  final Future<void> Function(bool online, double? lat, double? lng) report;
  final PresenceFix fix;
  final Duration interval;
  final Duration maxQuiet;
  final double minMetres;

  Timer? _timer;
  bool _online = false;
  bool _disposed = false;

  /// Where the last report said, and the check-ins since (time is counted
  /// in ticks, so it follows the timer and a test's clock alike).
  ({double lat, double lng})? _lastFix;
  int _quietTicks = 0;
  bool _sentOnline = false;

  bool get online => _online;

  void setOnline(bool online) {
    if (_disposed || online == _online) return;
    _online = online;
    _timer?.cancel();
    _timer = null;
    if (online) {
      _sentOnline = false;
      unawaited(_tick());
      _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
    } else {
      unawaited(_send(false, null));
    }
  }

  Future<void> _tick() async {
    ({double lat, double lng})? at;
    try {
      at = await fix();
    } catch (_) {}
    if (!_online || _disposed) return;
    final due = !_sentOnline ||
        presenceReportDue(
          sinceLast: interval * (_quietTicks + 1),
          last: _lastFix,
          now: at,
          minMetres: minMetres,
          maxQuiet: maxQuiet,
        );
    if (!due) {
      _quietTicks++;
      return;
    }
    _quietTicks = 0;
    if (await _send(true, at)) {
      _sentOnline = true;
      if (at != null) _lastFix = at;
    }
  }

  /// True when the server took it.
  Future<bool> _send(bool online, ({double lat, double lng})? at) async {
    try {
      await report(online, at?.lat, at?.lng);
      return true;
    } catch (_) {
      // Presence is best effort: the next check-in, or the 3-minute expiry,
      // puts it right.
      return false;
    }
  }

  /// Tells the server this driver is not taking rides, whatever the switch
  /// last said here: the app opened offline after it closed online.
  void tellOffline() {
    if (_disposed || _online) return;
    unawaited(_send(false, null));
  }

  void dispose() {
    if (_disposed) return;
    _timer?.cancel();
    // A different account (or none): this driver is no longer taking rides.
    if (_online) unawaited(_send(false, null));
    _online = false;
    _disposed = true;
  }
}

Future<({double lat, double lng})?> _phoneFix() async {
  final perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
  // A browser has no last known position: straight to a fresh one.
  final last = kIsWeb ? null : await Geolocator.getLastKnownPosition();
  // Reports go every 10 s while moving: a fix older than that is stale.
  if (last != null && DateTime.now().difference(last.timestamp) < const Duration(seconds: 10)) {
    return (lat: last.latitude, lng: last.longitude);
  }
  final p = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
  ).timeout(const Duration(seconds: 10));
  return (lat: p.latitude, lng: p.longitude);
}

/// How presence is reported and where the fix comes from. A seam for tests.
final driverPresenceReporterFactoryProvider = Provider<DriverPresenceReporter Function()>(
  (ref) =>
      () => DriverPresenceReporter(
        report: (online, lat, lng) async {
          await ref
              .read(supabaseProvider)
              .rpc('set_driver_presence', params: {'p_online': online, 'p_lat': lat, 'p_lng': lng});
        },
        fix: _phoneFix,
      ),
);

/// Follows the Drive switch for as long as the app shell is up.
final driverPresenceProvider = Provider<DriverPresenceReporter>((ref) {
  final reporter = ref.watch(driverPresenceReporterFactoryProvider)();
  ref.onDispose(reporter.dispose);
  reporter.setOnline(ref.read(driverOnlineProvider));
  ref.listen<bool>(driverOnlineProvider, (_, online) => reporter.setOnline(online));
  return reporter;
});
