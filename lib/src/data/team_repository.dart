// User teams (migration 0358): the app side. A "team" rides on the referral
// graph — your team lead is your referrer. A member joins a team by the lead's
// referral code (team_join), asks to move to another lead with a reason
// (team_request_change, which an admin approves), and sees their team-mates
// (team_members). The admin side is in team_changes_repository.dart.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';

/// A pending "change team" request the member is waiting on.
class TeamPendingChange {
  const TeamPendingChange({required this.id, required this.toName});
  final String id;
  final String toName;

  static TeamPendingChange? fromJson(Object? j) {
    if (j is! Map) return null;
    return TeamPendingChange(
      id: j['id'] as String,
      toName: (j['to_name'] as String?)?.trim().isNotEmpty == true ? (j['to_name'] as String).trim() : 'the new team',
    );
  }
}

/// The caller's team: whether they are on one, their lead, and any pending
/// change request.
class TeamStatus {
  const TeamStatus({required this.onTeam, this.leadId, this.leadName, this.pending});
  final bool onTeam;
  final String? leadId;
  final String? leadName;
  final TeamPendingChange? pending;

  static TeamStatus fromJson(Map<String, dynamic> j) => TeamStatus(
        onTeam: j['on_team'] == true,
        leadId: j['lead_id'] as String?,
        leadName: (j['lead_name'] as String?)?.trim(),
        pending: TeamPendingChange.fromJson(j['pending_change']),
      );
}

/// One member in the team directory — name + plate only.
class TeamMemberRow {
  const TeamMemberRow({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.plate,
    required this.isLead,
    required this.isMe,
  });

  final String id;
  final String name;
  final String? avatarUrl;
  final String? plate;
  final bool isLead;
  final bool isMe;

  static String? _s(Object? v) {
    final t = (v as String?)?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  static TeamMemberRow fromJson(Map<String, dynamic> j) => TeamMemberRow(
        id: j['member_id'] as String,
        name: (j['name'] as String?)?.trim().isNotEmpty == true ? (j['name'] as String).trim() : 'User',
        avatarUrl: _s(j['avatar_url']),
        plate: _s(j['plate']),
        isLead: j['is_lead'] == true,
        isMe: j['is_me'] == true,
      );
}

/// Maps a team RPC's raised error to a message for the user; null when the
/// error is not one we recognise (the caller shows a generic message).
String? teamErrorText(Object e) {
  final m = e is PostgrestException ? e.message : e.toString();
  bool has(String code) => m.contains(code);
  if (has('invalid_code')) return 'That referral code looks too short. Check it and try again.';
  if (has('code_not_found')) return "We couldn't find anyone with that referral code.";
  if (has('self_team')) return "That's your own code — enter a team-mate's code.";
  if (has('already_on_team')) return "You're already on a team. Use \"Change team\" to move.";
  if (has('not_on_team')) return 'Join a team first before asking to change.';
  if (has('same_team')) return "You're already on that team.";
  if (has('request_pending')) return 'You already have a change request waiting for review.';
  if (has('reason_required')) return 'Please give a reason for the change.';
  if (has('not_authorized')) return 'Please sign in to manage your team.';
  return null;
}

class TeamRepository {
  TeamRepository(this._db);
  final SupabaseClient _db;

  /// The caller's team status, or null when not signed in / unavailable.
  Future<TeamStatus?> self() async {
    final r = await _db.rpc('team_self');
    if (r == null) return null;
    return TeamStatus.fromJson(Map<String, dynamic>.from(r as Map));
  }

  /// Join a team by the lead's referral code (immediate; the caller must not
  /// already be on a team).
  Future<void> join(String code) async {
    await _db.rpc('team_join', params: {'p_code': code});
  }

  /// File a request to move to another team lead, with a reason. An admin
  /// approves or rejects it.
  Future<void> requestChange({required String code, required String reason}) async {
    await _db.rpc('team_request_change', params: {'p_code': code, 'p_reason': reason});
  }

  /// The caller's team-mates (the lead first), or empty when not on a team.
  Future<List<TeamMemberRow>> members() async => [
        for (final r in (await _db.rpc('team_members') as List))
          TeamMemberRow.fromJson(Map<String, dynamic>.from(r as Map)),
      ];
}

final teamRepositoryProvider = Provider((ref) => TeamRepository(ref.watch(supabaseProvider)));

/// The caller's team status (drives the Profile "Team" card). Null on a legacy
/// local-PIN session or where migration 0358 is not applied — the error is
/// swallowed so the card simply hides.
final teamSelfProvider = FutureProvider.autoDispose<TeamStatus?>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return null;
  try {
    return await ref.watch(teamRepositoryProvider).self();
  } catch (_) {
    return null;
  }
});

/// The caller's team-mates (View members).
final teamMembersProvider = FutureProvider.autoDispose<List<TeamMemberRow>>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return const <TeamMemberRow>[];
  return ref.watch(teamRepositoryProvider).members();
});
