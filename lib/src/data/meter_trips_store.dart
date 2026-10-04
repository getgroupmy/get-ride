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

  /// Completes one end of a hire once a late reading lands (the place name
  /// and the drop-off odometer come back after the record is written). The
  /// change is applied to the end as stored, so two late readings for the
  /// same end never overwrite each other, and only the ends can change:
  /// nothing that was measured or charged is rewritable.
  Future<List<MeterTrip>> patchEnd(String id, {required bool pickup, required MeterWaypoint Function(MeterWaypoint end) change}) async {
    final trips = [...await load()];
    final i = trips.indexWhere((t) => t.id == id);
    if (i == -1) return trips;
    final end = pickup ? trips[i].pickup : trips[i].dropoff;
    if (end == null) return trips;
    trips[i] = pickup ? trips[i].withEnds(pickup: change(end)) : trips[i].withEnds(dropoff: change(end));
    return _write(trips);
  }

  Future<void> clear() async => (await SharedPreferences.getInstance()).remove(key);
}
