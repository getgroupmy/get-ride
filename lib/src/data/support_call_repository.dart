import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/support_call.dart';
import '../providers.dart';

/// Support calls (migration 0105): ringing, answering and hanging up on
/// `support_calls`, and the WebRTC setup messages on `support_call_signals`.
/// Row-level security keeps each side to its own calls; the 0105 guard keeps
/// a user from doing anything but ring support as themselves and move the
/// status of their own calls.
class SupportCallRepository implements CallSignalling<SupportCall> {
  SupportCallRepository(this._db);
  final SupabaseClient _db;

  static const _calls = 'support_calls';
  static const _signals = 'support_call_signals';

  String? get _uid => _db.auth.currentUser?.id;
  String _now() => DateTime.now().toUtc().toIso8601String();

  /// A user rings support from [ticketId]; any agent can answer.
  Future<SupportCall> ringSupport({String? ticketId, String? callerName}) async {
    final uid = _uid;
    if (uid == null) throw const AuthException('Sign in to call support.');
    final row = await _db
        .from(_calls)
        .insert({
          'profile_id': uid,
          'ticket_id': ticketId,
          'caller_role': 'user',
          'caller_name': callerName,
          'media': 'voice',
          'status': 'ringing',
        })
        .select()
        .single();
    return SupportCall(row);
  }

  /// An agent rings the user [profileId] about [ticketId].
  Future<SupportCall> ringUser({required String profileId, String? ticketId, String? agentName}) async {
    final row = await _db
        .from(_calls)
        .insert({
          'profile_id': profileId,
          'ticket_id': ticketId,
          'caller_role': 'admin',
          'caller_id': _uid,
          'caller_name': agentName ?? 'Support',
          'media': 'voice',
          'status': 'ringing',
        })
        .select()
        .single();
    return SupportCall(row);
  }

  /// Answers [call]. An agent taking a user's call claims it, and gets false
  /// when another agent got there first; a user answering an agent just
  /// accepts.
  Future<bool> answer(SupportCall call, {String? agentName}) async {
    final patch = <String, dynamic>{'status': CallStatus.accepted.name, 'started_at': _now()};
    var q = _db
        .from(_calls)
        .update({
          ...patch,
          if (call.fromUser) ...{'answered_by': _uid, 'answered_by_name': agentName},
        })
        .eq('id', call.id)
        .eq('status', CallStatus.ringing.name);
    if (call.fromUser) q = q.isFilter('answered_by', null);
    final rows = await q.select('id');
    return rows.isNotEmpty;
  }

  /// Ends [callId] with [status] (declined, missed or ended). A call already
  /// over is left as it is.
  @override
  Future<void> finish(String callId, CallStatus status) async {
    await _db.from(_calls).update({'status': status.name, 'ended_at': _now()}).eq('id', callId).inFilter('status', [
      CallStatus.ringing.name,
      CallStatus.accepted.name,
    ]);
  }

  Future<SupportCall?> fetch(String callId) async {
    final row = await _db.from(_calls).select().eq('id', callId).maybeSingle();
    return row == null ? null : SupportCall(row);
  }

  /// [callId]'s row now and on every change.
  @override
  Stream<SupportCall> watch(String callId) => _watchRows(
    'call_$callId',
    _calls,
    PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: callId),
    initial: () async {
      final c = await fetch(callId);
      return c == null ? const [] : [c.raw];
    },
  ).map(SupportCall.new);

  /// Calls an agent is ringing [uid] with, and their changes.
  Stream<SupportCall> watchIncomingForUser(String uid) => _watchRows(
    'incoming_$uid',
    _calls,
    PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'profile_id', value: uid),
    initial: () async => List<Map<String, dynamic>>.from(
      await _db
          .from(_calls)
          .select()
          .eq('profile_id', uid)
          .eq('caller_role', 'admin')
          .eq('status', CallStatus.ringing.name),
    ),
  ).map(SupportCall.new).where((c) => !c.fromUser);

  /// Users ringing support (for agents), and their changes, so a call taken
  /// by another agent or given up on stops ringing here.
  Stream<SupportCall> watchIncomingForAgents() => _watchRows(
    'incoming_support',
    _calls,
    PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'caller_role', value: 'user'),
    initial: () async => List<Map<String, dynamic>>.from(
      await _db
          .from(_calls)
          .select()
          .eq('caller_role', 'user')
          .eq('status', CallStatus.ringing.name)
          .gte('created_at', DateTime.now().toUtc().subtract(callRingTimeout).toIso8601String()),
    ),
  ).map(SupportCall.new);

  @override
  Future<void> sendSignal(String callId, String kind, Map<String, dynamic> payload) =>
      _db.from(_signals).insert({'call_id': callId, 'kind': kind, 'payload': payload});

  /// Every setup message on [callId], the ones already sent first, each once.
  @override
  Stream<CallSignal> watchSignals(String callId) {
    final seen = <int>{};
    return _watchRows(
      'signals_$callId',
      _signals,
      PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'call_id', value: callId),
      event: PostgresChangeEvent.insert,
      initial: () async =>
          List<Map<String, dynamic>>.from(await _db.from(_signals).select().eq('call_id', callId).order('id')),
    ).map(CallSignal.fromRow).where((s) => seen.add(s.id));
  }

  /// The ICE servers for a call (turn-credentials); STUN only when the
  /// function is unreachable or not deployed.
  @override
  Future<List<Map<String, dynamic>>> iceServers() async {
    try {
      final res = await _db.functions.invoke('turn-credentials');
      return parseIceServers(res.data);
    } catch (_) {
      return parseIceServers(null);
    }
  }

  Stream<Map<String, dynamic>> _watchRows(
    String name,
    String table,
    PostgresChangeFilter filter, {
    PostgresChangeEvent event = PostgresChangeEvent.all,
    required Future<List<Map<String, dynamic>>> Function() initial,
  }) => watchCallRows(_db, name, table, filter, event: event, initial: initial);
}

/// Rows of [table] matching [filter]: [initial] first, then every change, as
/// one stream (support calls and ride calls follow their rows this way).
Stream<Map<String, dynamic>> watchCallRows(
  SupabaseClient db,
  String name,
  String table,
  PostgresChangeFilter filter, {
  PostgresChangeEvent event = PostgresChangeEvent.all,
  required Future<List<Map<String, dynamic>>> Function() initial,
}) {
  final controller = StreamController<Map<String, dynamic>>();
  RealtimeChannel? channel;
  controller.onListen = () {
    void emit(Map<String, dynamic> row) {
      if (!controller.isClosed && row.isNotEmpty) controller.add(row);
    }

    channel = db
        .channel('${name}_${DateTime.now().microsecondsSinceEpoch}')
        .onPostgresChanges(
          event: event,
          schema: 'public',
          table: table,
          filter: filter,
          callback: (p) => emit(p.newRecord),
        )
        .subscribe();
    initial().then((rows) => rows.forEach(emit), onError: (Object _) {});
  };
  controller.onCancel = () async {
    if (channel != null) await db.removeChannel(channel!);
    await controller.close();
  };
  return controller.stream;
}

final supportCallRepositoryProvider = Provider((ref) => SupportCallRepository(ref.watch(supabaseProvider)));
