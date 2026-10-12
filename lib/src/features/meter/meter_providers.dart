import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/meter_console.dart';
import '../../core/vehicle_assignment.dart';
import '../../data/active_location.dart';
import '../../data/vehicle_assignment_repository.dart';
import '../partner/driver_permit_screen.dart' show driverPermitProvider;
import '../../admin/screens/meterapp/meter_logic.dart';
import '../../admin/screens/meterapp/meter_store.dart';
import '../../data/meter_launch_store.dart';
import '../../data/meter_trips_store.dart';
import '../../providers.dart';
import '../../data/live_tables.dart';

/// One GPS fix as the meter uses it.
class MeterFix {
  const MeterFix({required this.latitude, required this.longitude, required this.at, this.accuracyM, this.speedKmh});
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

  /// Opens the phone's settings where location is allowed, from the START
  /// popup when the card bills on GPS and location is off.
  Future<void> openSettings();
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
  Future<void> openSettings() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        await Geolocator.openLocationSettings();
      } else {
        await Geolocator.openAppSettings();
      }
    } catch (_) {}
  }

  @override
  Stream<MeterFix> fixes() =>
      Geolocator.getPositionStream(
        locationSettings: activeLocationSettings(ActiveLocationUse.meter, accuracy: LocationAccuracy.bestForNavigation),
      ).map(
        (p) => MeterFix(
          latitude: p.latitude,
          longitude: p.longitude,
          at: p.timestamp.millisecondsSinceEpoch,
          accuracyM: p.accuracy.isFinite && p.accuracy > 0 ? p.accuracy : null,
          // Negative means "unknown" on both platforms.
          speedKmh: p.speed.isFinite && p.speed >= 0 ? p.speed * 3.6 : null,
        ),
      );
}

final meterLocationProvider = Provider<MeterLocation>((_) => GeolocatorMeterLocation());

/// Epoch milliseconds now. A seam so tests can run the meter's clock.
final meterClockProvider = Provider<int Function()>(
  (_) =>
      () => DateTime.now().millisecondsSinceEpoch,
);

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

  Future<void> lockLandscape() =>
      SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);

  /// An empty list is the app's own default (`Info.plist` / the manifest).
  Future<void> release() => SystemChrome.setPreferredOrientations(const []);
}

final meterOrientationProvider = Provider<MeterOrientation>((_) => const MeterOrientation());

/// The vehicles this driver may drive, for the console's vehicle binding;
/// null when the fleet can't be read (no session, a failed query), which the
/// console treats as "not known" rather than "no vehicles".
final meterFleetProvider = FutureProvider.autoDispose<List<AssignableVehicle>?>((ref) async {
  try {
    return await ref.watch(assignableVehiclesProvider.future).timeout(const Duration(seconds: 10));
  } catch (_) {
    return null;
  }
});

/// Takes [vehicleId] for this driver (`claim_vehicle`). A seam for tests.
final meterClaimVehicleProvider = Provider<Future<void> Function(String vehicleId)>(
  (ref) =>
      (id) => ref.read(vehicleAssignmentRepositoryProvider).claim(id),
);

/// Who is driving, from the taxi driver permit first and the account after
/// (Expo `loadDriverPermitData` + `resolveMeterDriver`). Each source is
/// optional: a permit that can't be read leaves the account's name.
final meterDriverProvider = FutureProvider.autoDispose<MeterDriverIdentity>((ref) async {
  Future<T?> read<T>(Future<T> f) async {
    try {
      return await f.timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }

  final partner = await read(ref.watch(partnerProvider.future));
  final profile = await read(ref.watch(profileProvider.future));
  final permit = await read(ref.watch(driverPermitProvider.future));
  return resolveMeterDriver(
    permitName: permit?.name,
    permitNumber: permit?.permitNumber,
    permitPhoto: permit?.photoUrl,
    permitPlate: permit?.vehiclePlate,
    partnerName: partner?.name,
    profileName: profile?.name,
    partnerPhoto: partner?.avatarUrl,
    profilePhoto: profile?.avatarUrl,
  );
});
