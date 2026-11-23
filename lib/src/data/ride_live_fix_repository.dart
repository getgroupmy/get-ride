// The driver's fix a second (migration 0426).
//
// The driver's phone has always shared its position on the ride's own row, at
// most once every five seconds: fine for an ETA, but a passenger's map that
// only hears that often draws a car five seconds behind the real one. Beside
// it there is now a small channel for the position alone (`ride_live_fixes`):
// the driver's phone writes every GPS fix there through `ride_live_fix()`, and
// the passenger's phone hears each as it is written and follows the car live
// (live_ride_map.dart).
//
// Nothing depends on it. A server from before the migration has neither the
// function nor the table: the driver's phone is told so once and stops asking
// ([liveFixUnsupported]), and the passenger's hears nothing here and goes on
// following the ride row. Only the ride's own passenger can read it, and only
// while the ride is under way.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/demo_mode.dart' show isDemoRideId;
import '../providers.dart';
import 'live_fix.dart';
import 'realtime_hub.dart';

const _table = 'ride_live_fixes';
const _function = 'ride_live_fix';

double? _finite(double? value) => value != null && value.isFinite ? value : null;

/// What `ride_live_fix()` is called with for [fix] of ride [rideId]; null when
/// the fix has no position to send. A fix that came without a time is stamped
/// [now]. Pure.
///
/// The course goes in the function's `p_heading`: the database calls the way a
/// car is travelling its heading, as on the ride row.
Map<String, dynamic>? liveFixParams(String rideId, LiveFix fix, {required DateTime now}) {
  final lat = _finite(fix.at.latitude), lng = _finite(fix.at.longitude);
  if (lat == null || lng == null) return null;
  return {
    'p_ride': rideId,
    'p_lat': lat,
    'p_lng': lng,
    'p_heading': _finite(fix.course),
    'p_speed': _finite(fix.speed),
    'p_accuracy': _finite(fix.accuracy),
    'p_fixed_at': (fix.time ?? now).toUtc().toIso8601String(),
  };
}

double? _number(Object? value) => switch (value) {
  final num n => n.isFinite ? n.toDouble() : null,
  final String s => _finite(double.tryParse(s)),
  _ => null,
};

/// The fix in a row of `ride_live_fixes` as realtime hands it over; null when
/// the row has no position (a delete's empty row). Pure.
///
/// The time is the one the driver's phone's GPS stamped on the fix, by that
/// phone's clock: only ever compared with the times of its other fixes, and
/// with how late each reached this phone (FixFollower.take).
LiveFix? liveFixOfRow(Map<String, dynamic> row) {
  final lat = _number(row['lat']), lng = _number(row['lng']);
  if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) return null;
  final speed = _number(row['speed']), course = _number(row['heading']), accuracy = _number(row['accuracy']);
  final fixedAt = row['fixed_at'];
  return (
    at: LatLng(lat, lng),
    speed: speed != null && speed >= 0 ? speed : null,
    course: course != null && course >= 0 ? course % 360 : null,
    time: fixedAt is String ? DateTime.tryParse(fixedAt) : null,
    accuracy: accuracy != null && accuracy >= 0 ? accuracy : null,
  );
}

/// Whether [error] says the server has no fix-a-second channel: a database
/// from before migration 0426, without the function or the table. Pure.
bool liveFixUnsupported(Object error) {
  if (error is! PostgrestException) return false;
  final message = error.message.toLowerCase();
  return error.code == 'PGRST202' ||
      error.code == '42883' ||
      error.code == 'PGRST205' ||
      error.code == '42P01' ||
      message.contains('could not find the function') ||
      message.contains('could not find the table');
}

class RideLiveFixRepository {
  RideLiveFixRepository(this._db);

  final SupabaseClient _db;

  /// Sends the driver's [fix] for ride [rideId].
  ///
  /// True when the ride takes fixes from this account (it is theirs and under
  /// way); false when it takes none, and there is no use sending more for now.
  /// Throws when the server could not be reached, or has no such function
  /// ([liveFixUnsupported]).
  Future<bool> send(String rideId, LiveFix fix) async {
    final params = liveFixParams(rideId, fix, now: DateTime.now());
    if (params == null) return true; // nothing to send; nothing refused
    final answer = await _db.rpc(_function, params: params);
    return answer == true;
  }

  /// The fixes of ride [rideId]'s car, each as its driver's phone sends it:
  /// about one a second while the driver's phone is sending them, nothing
  /// while it is not. For the ride's passenger; anyone else hears nothing.
  ///
  /// Never an error, and no fix from before the listening began: what the map
  /// follows is the car moving now. Done at once when the server has no such
  /// channel.
  Stream<LiveFix> watch(String rideId) {
    final controller = StreamController<LiveFix>();
    RealtimeListen? channel;
    controller.onListen = () {
      try {
        // Shared with any other map on this ride (RealtimeHub).
        channel = RealtimeHub.of(_db).listen(
          table: _table,
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'ride_id', value: rideId),
          onChange: (change) {
            final fix = liveFixOfRow(change.newRecord);
            if (fix != null && !controller.isClosed) controller.add(fix);
          },
        );
      } catch (_) {
        // No client to open a channel on: the map follows the ride row.
      }
      // Is there anything to listen to? A channel on a table the server does
      // not have is refused, and asked for again and again for as long as it
      // is open: on a server from before the channel it is let go of.
      unawaited(() async {
        try {
          await _db.from(_table).select('driver_id').eq('ride_id', rideId).limit(1);
        } catch (e) {
          // Not reachable just now is not "not there": realtime connects when
          // the server is.
          if (!liveFixUnsupported(e)) return;
          channel?.cancel();
          channel = null;
          if (!controller.isClosed) await controller.close();
        }
      }());
    };
    controller.onCancel = () async {
      channel?.cancel();
      channel = null;
      if (!controller.isClosed) await controller.close();
    };
    return controller.stream;
  }
}

final rideLiveFixRepositoryProvider = Provider<RideLiveFixRepository>(
  (ref) => RideLiveFixRepository(ref.watch(supabaseProvider)),
);

/// The live fixes of ride [id]'s car, for its passenger's map; null for a ride
/// that lives on this phone alone (a demo), which no server is asked about.
/// Overridden in tests.
final rideCarFixesProvider = Provider.family<Stream<LiveFix> Function()?, String>((ref, id) {
  if (isDemoRideId(id)) return null;
  return () {
    final RideLiveFixRepository repository;
    try {
      repository = ref.read(rideLiveFixRepositoryProvider);
    } catch (_) {
      // No server to listen to: the map follows the ride row.
      return const Stream<LiveFix>.empty();
    }
    return repository.watch(id);
  };
});
