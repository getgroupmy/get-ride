// User teams (migration 0358): the admin side — list the pending "change team"
// requests and approve/reject them. Every rule is the server's; this only asks
// the RPCs (admin_list_team_changes / admin_decide_team_change, each gated on
// the 'admin-team-changes' page, audited, and pushing the requester).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';

/// One team-change request as the admin sees it.
class TeamChangeRequest {
  const TeamChangeRequest({
    required this.id,
    required this.requesterName,
    this.requesterPhone,
    this.fromLeadName,
    required this.toLeadName,
    required this.toCode,
    required this.reason,
    required this.status,
    this.createdAt,
  });

  final String id;
  final String requesterName;
  final String? requesterPhone;
  final String? fromLeadName;
  final String toLeadName;
  final String toCode;
  final String reason;
  final String status;
  final DateTime? createdAt;

  bool get isPending => status == 'pending';

  static TeamChangeRequest fromJson(Map<String, dynamic> j) => TeamChangeRequest(
        id: j['id'] as String,
        requesterName: (j['requester_name'] as String?)?.trim().isNotEmpty == true
            ? (j['requester_name'] as String).trim()
            : 'User',
        requesterPhone: (j['requester_phone'] as String?)?.trim(),
        fromLeadName: (j['from_lead_name'] as String?)?.trim(),
        toLeadName: (j['to_lead_name'] as String?)?.trim().isNotEmpty == true
            ? (j['to_lead_name'] as String).trim()
            : 'the new team',
        toCode: (j['to_code'] as String?) ?? '',
        reason: (j['reason'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'pending',
        createdAt: DateTime.tryParse('${j['created_at'] ?? ''}')?.toLocal(),
      );
}

class TeamChangesRepository {
  TeamChangesRepository(this._db);
  final SupabaseClient _db;

  /// Change requests by [status] ('pending' default, or 'all').
  Future<List<TeamChangeRequest>> list({String status = 'pending'}) async => [
        for (final r in (await _db.rpc('admin_list_team_changes', params: {'p_status': status}) as List))
          TeamChangeRequest.fromJson(Map<String, dynamic>.from(r as Map)),
      ];

  /// Approve or reject a request. [action] is 'approve' or 'reject'; a note is
  /// optional (sent to the requester on a reject).
  Future<void> decide(String id, String action, {String? note}) async {
    await _db.rpc('admin_decide_team_change', params: {'p_id': id, 'p_action': action, 'p_note': note});
  }
}

final teamChangesRepositoryProvider = Provider((ref) => TeamChangesRepository(ref.watch(supabaseProvider)));

/// Pending change requests for the admin review page.
final teamChangesPendingProvider = FutureProvider.autoDispose<List<TeamChangeRequest>>(
  (ref) => ref.watch(teamChangesRepositoryProvider).list(),
);
