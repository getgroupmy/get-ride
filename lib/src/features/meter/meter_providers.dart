import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../admin/screens/meterapp/meter_logic.dart';
import '../../admin/screens/meterapp/meter_store.dart';
import '../../data/meter_launch_store.dart';
import '../../data/meter_trips_store.dart';
import '../../providers.dart';
import '../../data/live_tables.dart';

/// One GPS fix as the meter uses it.
class MeterFix {
  const MeterFix({
    required this.latitude,
    required this.longitude,
    required this.at,
    this.accuracyM,
    this.speedKmh,
  });
  final double latitude;
  final double longitude;
  final int at;
  final double? accuracyM;

  /// Ground speed, when the platform reports one.
  final double? speedKmh;
}

/// The meter's location feed. A seam so tests can drive a hire.
abstract class MeterLocation {
  /// Asks for permission if needed. A message when the meter cannot have
  /// fixes (services off, permission refused), null when it can.
  Future<String?> prepare();

  Stream<MeterFix> fixes();
}

class GeolocatorMeterLocation implements MeterLocation {
  @override
  Future<String?> prepare() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return 'Location is turned off on this device.';
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        return 'Location permission is needed to meter on GPS.';
      }
      return null;
    } catch (e) {
      return 'Location is not available here ($e).';
    }
  }

  @override
  Stream<MeterFix> fixes() => Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation),
      ).map((p) => MeterFix(
            latitude: p.latitude,
            longitude: p.longitude,
            at: p.timestamp.millisecondsSinceEpoch,
            accuracyM: p.accuracy.isFinite && p.accuracy > 0 ? p.accuracy : null,
            // Negative means "unknown" on both platforms.
            speedKmh: p.speed.isFinite && p.speed >= 0 ? p.speed * 3.6 : null,
          ));
}

final meterLocationProvider = Provider<MeterLocation>((_) => GeolocatorMeterLocation());

/// Epoch milliseconds now. A seam so tests can run the meter's clock.
final meterClockProvider = Provider<int Function()>((_) => () => DateTime.now().millisecondsSinceEpoch);

/// The operator's rate cards (Admin → Settings → Meter Digital Setting).
/// Readable by everyone; an unreachable table means the built-in tariff.
final meterLaunchStoreProvider = Provider((_) => MeterLaunchStore());

/// The operator's rate cards. Kept on the device as last fetched, because a
/// meter has to keep pricing with no signal at all (and the launch decision
/// is made before the network answers): offline, the cached cards decide.
final meterCardsProvider = FutureProvider<List<MeterProfile>>((ref) async {
  ref.watchLive('meter_digital_settings');
  final cache = ref.watch(meterLaunchStoreProvider);
  try {
    final cards = await MeterSettingsStore(ref.watch(supabaseProvider)).fetch();
    try {
      await cache.saveCards(cards);
    } catch (_) {}
    return cards;
  } catch (_) {
    return cache.readCards();
  }
});

final meterTripsStoreProvider = Provider((_) => MeterTripsStore());

/// Pins the device to landscape while the console is in front, and hands
/// rotation back to the app default when it is not (Expo
/// `useLandscapeLock`). A seam so tests can see the requests.
class MeterOrientation {
  const MeterOrientation();

  Future<void> lockLandscape() => SystemChrome.setPreferredOrientations(
      const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);

  /// An empty list is the app's own default (`Info.plist` / the manifest).
  Future<void> release() => SystemChrome.setPreferredOrientations(const []);
}

final meterOrientationProvider = Provider<MeterOrientation>((_) => const MeterOrientation());
