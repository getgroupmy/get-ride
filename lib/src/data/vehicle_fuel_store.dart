// The vehicle's fuel profile (tank capacity, the driver's average consumption
// and the running measurement taken from their own fuel burn), ported from the
// Expo app's `utils/vehicleFuelStore.ts`.
//
// Device-local (shared_preferences) for the same reason the adapter book is:
// an OBD-II reader and the car it is plugged into belong to one phone. All of
// the arithmetic lives in `core/fuel_range.dart`; this only loads, validates
// and saves.
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/fuel_range.dart';

class VehicleFuelStore {
  /// Expo `VEHICLE_FUEL_PROFILE_KEY` ("@vehicle_fuel_profile_v1") without the '@'.
  static const profileKey = 'vehicle_fuel_profile_v1';

  Future<FuelProfile> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(profileKey);
      if (raw == null || raw.isEmpty) return defaultFuelProfile();
      return normalizeFuelProfile(jsonDecode(raw));
    } catch (e) {
      developer.log('load failed', name: 'vehicle-fuel', error: e);
      return defaultFuelProfile();
    }
  }

  /// Normalises, persists and returns the profile. A failed write is logged
  /// and the normalised profile is still returned.
  Future<FuelProfile> save(FuelProfile profile) async {
    final normalized = normalizeFuelProfile(profile);
    try {
      await (await SharedPreferences.getInstance()).setString(profileKey, jsonEncode(normalized.toJson()));
    } catch (e) {
      developer.log('save failed', name: 'vehicle-fuel', error: e);
    }
    return normalized;
  }

  /// Load the profile for the vehicle currently on the reader and, when the
  /// scan saw both an odometer and a fuel level, fold that pair into the
  /// running consumption measurement.
  ///
  /// Returns the profile the screen should render with; it is persisted first,
  /// so the next scan measures against this reading.
  Future<({FuelProfile profile, bool learned})> recordFuelSample(String? vin, FuelSample? sample) async {
    final stored = await load();
    final profile = profileForVin(stored, vin);
    if (sample == null) {
      // Nothing to measure against, but the VIN may have switched the profile.
      if (!identical(profile, stored)) await save(profile);
      return (profile: profile, learned: false);
    }
    final result = learnConsumption(sample, profile);
    final saved = await save(result.profile);
    return (profile: saved, learned: result.learned);
  }

  /// Drop the measured consumption and its baseline, keeping what the driver typed.
  Future<FuelProfile> resetMeasuredConsumption() async {
    final profile = await load();
    return save(profile.copyWith(measuredL100: null, baseline: null));
  }
}

final vehicleFuelStoreProvider = Provider((_) => VehicleFuelStore());
