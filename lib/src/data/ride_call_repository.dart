import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/ride_call.dart';
import '../core/support_call.dart';
import '../providers.dart';
import 'support_call_repository.dart' show watchCallRows;

/// Rider ↔ driver calls (migration 0131): ringing, answering and hanging up
/// on `ride_calls`, and the WebRTC setup on `ride_call_signals`. The client
/// only names the ride; who is calling whom comes from the ride, and the
/// 0131 guard decides which side may move the status where.
class RideCallRepository implements CallSignalling<RideCall> {
  RideCallRepository(this._db);
  final SupabaseClient _db;

  static const _calls = 'ride_calls';
  static const _signals = 'ride_call_signals';

  /// Rings the other person on [requestId].
  Future<RideCall> ring(String requestId) async {
    final row = await _db.from(_calls).insert({'request_id': requestId}).select().single();
    return RideCall(row);
  }

  /// The call ringing or under way on [requestId], if there is one.
  Future<RideCall?> live(String requestId) async {
    final rows = await _db
        .from(_calls)
        .select()
        .eq('request_id', requestId)
        .inFilter('status', ['ringing', 'answered'])
        .order('created_at', ascending: false)
        .limit(1);
    return rows.isEmpty ? null : RideCall(rows.first);
  }

  /// Answers [call]. False when it is no longer ringing (the caller gave up,
  /// or it rang out: the database then records it missed).
  Future<bool> answer(RideCall call) async {
    final rows = await _db
        .from(_calls)
        .update({'status': 'answered'})
        .eq('id', call.id)
        .eq('status', 'ringing')
        .select('status');
    return rows.isNotEmpty && rows.first['status'] == 'answered';
  }

  /// Ends [callId] with [status]. Only a step the call can still take is
  /// sent: declined, missed and cancelled from ringing, ended once answered.
  @override
  Future<void> finish(String callId, CallStatus status) async {
    await _db
        .from(_calls)
        .update({'status': rideCallStatusName(status)})
        .eq('id', callId)
        .eq('status', status == CallStatus.ended ? 'answered' : 'ringing');
  }

  Future<RideCall?> fetch(String callId) async {
    final row = await _db.from(_calls).select().eq('id', callId).maybeSingle();
    return row == null ? null : RideCall(row);
  }

  @override
  Stream<RideCall> watch(String callId) => watchCallRows(
    _db,
    'ride_call_$callId',
    _calls,
    PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: callId),
    initial: () async {
      final c = await fetch(callId);
      return c == null ? const [] : [c.raw];
    },
  ).map(RideCall.new);

  /// Calls ringing [uid], and their changes (so one the caller cancels stops
  /// ringing).
  Stream<RideCall> watchIncoming(String uid) => watchCallRows(
    _db,
    'ride_call_incoming_$uid',
    _calls,
    PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'callee_id', value: uid),
    initial: () async => List<Map<String, dynamic>>.from(
      await _db
          .from(_calls)
          .select()
          .eq('callee_id', uid)
          .eq('status', 'ringing')
          .gte('created_at', DateTime.now().toUtc().subtract(callRingTimeout).toIso8601String()),
    ),
  ).map(RideCall.new);

  @override
  Future<void> sendSignal(String callId, String kind, Map<String, dynamic> payload) =>
      _db.from(_signals).insert({'call_id': callId, 'kind': kind, 'payload': payload});

  /// Every setup message on [callId], the ones already sent first, each once.
  @override
  Stream<CallSignal> watchSignals(String callId) {
    final seen = <int>{};
    return watchCallRows(
      _db,
      'ride_call_signals_$callId',
      _signals,
      PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'call_id', value: callId),
      event: PostgresChangeEvent.insert,
      initial: () async =>
          List<Map<String, dynamic>>.from(await _db.from(_signals).select().eq('call_id', callId).order('id')),
    ).map(CallSignal.fromRow).where((s) => seen.add(s.id));
  }

  /// The same relay credentials as a support call (turn-credentials hands
  /// them to any signed-in account); STUN only when it is unreachable.
  @override
  Future<List<Map<String, dynamic>>> iceServers() async {
    try {
      final res = await _db.functions.invoke('turn-credentials');
      return parseIceServers(res.data);
    } catch (_) {
      return parseIceServers(null);
    }
  }
}

final rideCallRepositoryProvider = Provider((ref) => RideCallRepository(ref.watch(supabaseProvider)));
