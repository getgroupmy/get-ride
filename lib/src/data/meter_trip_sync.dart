// Sends finished meter hires to GET.ride (migration 0219), so a TEKSI street
// hail can be charged commission when Admin → Commission → Settings says so.
// The roll on the phone stays the record of truth for the driver; this keeps
// a list of the hires already sent and sends the rest, oldest first, whenever
// the meter is opened or a hire ends. With no signal, a hire waits for the
// next try; the server ignores one sent twice.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/meter_trip.dart';
import '../features/meter/meter_providers.dart' show meterTripsStoreProvider;
import '../providers.dart';
import 'meter_trips_store.dart';

/// The hires on [roll] not yet sent, oldest first. Pure.
List<MeterTrip> pendingMeterTrips(List<MeterTrip> roll, Set<String> sent) =>
    [for (final t in roll.reversed) if (!sent.contains(t.id)) t];

/// Why a send stopped.
enum MeterSyncStop { done, offline, notPartner }

class MeterTripSync {
  MeterTripSync(this._store, this._send);

  final MeterTripsStore _store;

  /// Sends one hire; throws on failure.
  final Future<void> Function(Map<String, dynamic> trip) _send;

  static const sentKey = 'meter_trips_sent_v1';
  bool _running = false;

  Future<Set<String>> _sent() async =>
      ((await SharedPreferences.getInstance()).getStringList(sentKey) ?? const []).toSet();

  /// Sends what is waiting; answers how many went and why it stopped.
  Future<({int sent, MeterSyncStop stop})> sendPending() async {
    if (_running) return (sent: 0, stop: MeterSyncStop.done);
    _running = true;
    var count = 0;
    var stop = MeterSyncStop.done;
    try {
      final roll = await _store.load();
      final sent = await _sent();
      for (final t in pendingMeterTrips(roll, sent)) {
        try {
          await _send(t.toJson());
        } on PostgrestException catch (e) {
          if (e.code == '42501') {
            // Not an approved partner (yet): nothing will go until they are.
            stop = MeterSyncStop.notPartner;
            break;
          }
          if (e.code == '22023') {
            // A hire the server can't take (impossible times or numbers): never retried.
            sent.add(t.id);
            continue;
          }
          stop = MeterSyncStop.offline;
          break;
        } catch (_) {
          stop = MeterSyncStop.offline;
          break;
        }
        sent.add(t.id);
        count++;
      }
      // Only ids still on the roll are worth remembering.
      final onRoll = {for (final t in roll) t.id};
      await (await SharedPreferences.getInstance()).setStringList(sentKey, [...sent.where(onRoll.contains)]);
    } finally {
      _running = false;
    }
    return (sent: count, stop: stop);
  }
}

final meterTripSyncProvider = Provider<MeterTripSync>((ref) {
  final db = ref.watch(supabaseProvider);
  return MeterTripSync(
    ref.watch(meterTripsStoreProvider),
    (trip) async {
      if (db.auth.currentUser == null) throw StateError('signed out');
      await db.rpc('meter_trip_record', params: {'p_trip': trip});
    },
  );
});
