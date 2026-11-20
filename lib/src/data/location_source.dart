// Where the phone is, fast and then accurately (PERF-4). The home screen
// used to wait for a high-accuracy GPS fix (up to 12 s) before it showed
// the map on the rider and the pickup; now it shows them on the last known
// position (or a quick low-accuracy fix) at once and moves them when the
// accurate fix comes in.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'active_location.dart';
import 'live_fix.dart';
import 'shared_location.dart';

/// The location calls [locateFastThenFine] makes; a fake in tests.
abstract class LocationSource {
  Future<bool> serviceEnabled();
  Future<LocationPermission> checkPermission();
  Future<LocationPermission> requestPermission();

  /// The fix the phone already has, without waking the GPS; null for none.
  Future<LatLng?> lastKnown();

  /// A fresh fix at [accuracy].
  Future<LatLng> current(LocationAccuracy accuracy);
}

/// A [LocationSource] whose position can also be followed as it changes: the
/// phone itself. A stand-in that only answers when asked (most tests') has no
/// such stream, and a map following it simply stays on the fix it was given.
abstract class LiveLocationSource implements LocationSource {
  /// The position as it changes, for a map that shows the rider where they
  /// are. It asks for nothing: permission is [requestPermission]'s to ask.
  Stream<LiveFix> liveFixes();
}

/// The phone's own location, through Geolocator.
class GeolocatorLocationSource implements LiveLocationSource {
  const GeolocatorLocationSource();

  @override
  Future<bool> serviceEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  @override
  Future<LocationPermission> requestPermission() => Geolocator.requestPermission();

  @override
  Future<LatLng?> lastKnown() async {
    final p = await Geolocator.getLastKnownPosition();
    return p == null ? null : LatLng(p.latitude, p.longitude);
  }

  @override
  Future<LatLng> current(LocationAccuracy accuracy) async {
    final p = await Geolocator.getCurrentPosition(locationSettings: LocationSettings(accuracy: accuracy));
    return LatLng(p.latitude, p.longitude);
  }

  /// Off the app's one shared stream (shared_location.dart), at what a rider's
  /// map asks of it ([riderMapLocationSettings]).
  @override
  Stream<LiveFix> liveFixes() => sharedPositionStream(riderMapLocationSettings()).map(liveFixOf);
}

final locationSourceProvider = Provider<LocationSource>((_) => const GeolocatorLocationSource());

/// The phone's position as it changes, for a map that shows the rider where
/// they are (the home map's dot; overridden in tests). Empty when the location
/// source has none to give ([LiveLocationSource]), or location is off or not
/// yet allowed — and it never asks: asking is [locateFastThenFine]'s job (and
/// the recenter button's), so opening the app asks once, not twice. Whoever
/// listens starts it again once a fix shows location is allowed.
final liveFixesProvider = Provider<Stream<LiveFix> Function()>((ref) => () async* {
  final source = ref.read(locationSourceProvider);
  if (source is! LiveLocationSource) return;
  try {
    if (!await source.serviceEnabled()) return;
    final perm = await source.checkPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
    yield* source.liveFixes();
  } catch (_) {}
});

/// How long the accurate fix is waited for (as before).
const fineFixTimeout = Duration(seconds: 12);

/// How long a quick, low-accuracy fix is waited for when the phone has no
/// last known one.
const quickFixTimeout = Duration(seconds: 4);

/// The phone's position, first fast then accurately: the last known fix
/// (not on the web, which has none) or a quick low-accuracy one, as soon as
/// there is one, then the high-accuracy fix when it arrives (unless it is
/// the same point). The accurate fix is asked for at once, alongside, so it
/// is never later than it was; when it comes first the quick one is not
/// given at all.
///
/// Permission is asked for as `currentPosition` does (when it was not yet
/// refused); nothing is given when location is off, refused, or no fix
/// comes, which leaves the "location off" states as they were.
Stream<LatLng> locateFastThenFine(
  LocationSource source, {
  bool isWeb = kIsWeb,
  Duration fineTimeout = fineFixTimeout,
  Duration quickTimeout = quickFixTimeout,
}) async* {
  try {
    if (!await source.serviceEnabled()) return;
    var perm = await source.checkPermission();
    if (perm == LocationPermission.denied) perm = await source.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
  } catch (_) {
    return;
  }
  LatLng? fineFix;
  var fineDone = false;
  final fine = source.current(LocationAccuracy.high).timeout(fineTimeout).then<LatLng?>(
    (p) => p,
    onError: (Object _) => null,
  ).whenComplete(() => fineDone = true);
  unawaited(fine.then((p) => fineFix = p));

  Future<LatLng?> quick() async {
    if (!isWeb) {
      try {
        final last = await source.lastKnown();
        if (last != null) return last;
      } catch (_) {}
    }
    try {
      return await source.current(LocationAccuracy.low).timeout(quickTimeout);
    } catch (_) {
      return null;
    }
  }

  final first = await Future.any<LatLng?>([quick(), fine.then((_) => null)]);
  LatLng? shown;
  if (first != null && !fineDone) yield shown = first;
  await fine;
  final f = fineFix;
  if (f != null && f != shown) yield f;
}
