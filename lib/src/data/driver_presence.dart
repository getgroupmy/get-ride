import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../features/partner/driver_online.dart';
import '../providers.dart';

/// Where the driver is, cheaply: the last known fix, else a quick coarse one.
/// Null without location permission (presence never asks for it).
typedef PresenceFix = Future<({double lat, double lng})?> Function();

/// Tells the server whether this driver is taking rides and where they are
/// (`set_driver_presence`, migration 0145), so a new request is pushed to
/// the drivers near it rather than to every driver. Reports when the Drive
/// switch moves and every [interval] while it is on; the server forgets a
/// driver it has not heard from in 3 minutes, so a phone that dies simply
/// drops out.
class DriverPresenceReporter {
  DriverPresenceReporter({required this.report, required this.fix, this.interval = const Duration(seconds: 60)});

  final Future<void> Function(bool online, double? lat, double? lng) report;
  final PresenceFix fix;
  final Duration interval;

  Timer? _timer;
  bool _online = false;
  bool _disposed = false;

  bool get online => _online;

  void setOnline(bool online) {
    if (_disposed || online == _online) return;
    _online = online;
    _timer?.cancel();
    _timer = null;
    if (online) {
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
    await _send(true, at);
  }

  Future<void> _send(bool online, ({double lat, double lng})? at) async {
    try {
      await report(online, at?.lat, at?.lng);
    } catch (_) {
      // Presence is best effort: the next report, or the 3-minute expiry,
      // puts it right.
    }
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
  if (kIsWeb) return null;
  final perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
  final last = await Geolocator.getLastKnownPosition();
  if (last != null && DateTime.now().difference(last.timestamp) < const Duration(minutes: 2)) {
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
