import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/meter_trip.dart';

/// The meter's trip log, kept on the device like the Expo app's
/// (`utils/meterTripsStore.ts`): it is the meter's paper roll, and a meter
/// has to keep its roll with no signal at all.
class MeterTripsStore {
  static const key = 'meter_trips_v1';

  /// The roll keeps the newest 50 hires.
  static const maxTrips = 50;

  Future<List<MeterTrip>> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      if (raw == null) return const [];
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list.map(MeterTrip.fromJson).whereType<MeterTrip>().toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<MeterTrip>> _write(List<MeterTrip> trips) async {
    final next = trips.take(maxTrips).toList();
    await (await SharedPreferences.getInstance()).setString(key, jsonEncode([for (final t in next) t.toJson()]));
    return next;
  }

  /// Adds (or replaces) a hire at the top of the roll.
  Future<List<MeterTrip>> save(MeterTrip trip) async =>
      _write([trip, ...(await load()).where((t) => t.id != trip.id)]);

  /// Completes a hire's ends once a late reading lands (the place name comes
  /// back after the record is written). Only the ends can change: nothing
  /// that was measured or charged is rewritable.
  Future<List<MeterTrip>> patchEnds(String id, {MeterWaypoint? pickup, MeterWaypoint? dropoff}) async {
    final trips = [...await load()];
    final i = trips.indexWhere((t) => t.id == id);
    if (i == -1) return trips;
    trips[i] = trips[i].withEnds(pickup: pickup, dropoff: dropoff);
    return _write(trips);
  }

  Future<void> clear() async => (await SharedPreferences.getInstance()).remove(key);
}
