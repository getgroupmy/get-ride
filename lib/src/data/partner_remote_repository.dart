import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/partner_remote_action.dart';
import '../providers.dart';

/// Edit Partner › Change status (migration 0286): the admin's ask and the
/// phone's answer, through the partner_remote_action_* functions only.
class PartnerRemoteRepository implements RemoteActionInbox {
  PartnerRemoteRepository(this._db);

  final SupabaseClient _db;

  // ---- Admin ---------------------------------------------------------------

  /// Asks [profileId]'s phone to do [action] ([vehicleId] for a link). The
  /// server refuses what it can already tell (no edit on Partners, a vehicle
  /// another driver is online with, a request already waiting).
  Future<RemoteActionRequest?> request(String profileId, RemoteAction action, {String? vehicleId}) async {
    final row = await _db.rpc('partner_remote_action_request', params: {
      'p_profile_id': profileId,
      'p_action': action.wire,
      'p_vehicle_id': vehicleId,
    });
    return RemoteActionRequest.fromJson(row);
  }

  /// The partner's latest request, or null.
  Future<RemoteActionRequest?> status(String profileId) async =>
      RemoteActionRequest.fromJson(await _db.rpc('partner_remote_action_status', params: {'p_profile_id': profileId}));

  // ---- The phone -----------------------------------------------------------

  @override
  Future<RemoteActionRequest?> mine([String? id]) async =>
      RemoteActionRequest.fromJson(await _db.rpc('partner_remote_action_mine', params: {'p_id': id}));

  @override
  Future<void> seen(String id, {required bool waitingDriver}) =>
      _db.rpc('partner_remote_action_seen', params: {'p_id': id, 'p_waiting_driver': waitingDriver});

  @override
  Future<void> report(String id, {String? reason, required String localTime}) =>
      _db.rpc('partner_remote_action_report', params: {
        'p_id': id,
        'p_result': reason == null ? 'done' : 'refused',
        'p_reason': reason,
        'p_local_time': localTime,
      });
}

final partnerRemoteRepositoryProvider = Provider((ref) => PartnerRemoteRepository(ref.watch(supabaseProvider)));
