// Approver (migration 0349): the admin side — list, grant/configure and
// revoke the delegated document approvers. Every rule is the server's; this
// only asks the RPCs (admin_list_approvers / admin_set_approver /
// admin_remove_approver, each gated on the 'admin-approvers' page and audited).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';

class ApproversRepository {
  ApproversRepository(this._db);
  final SupabaseClient _db;

  /// Every approver (active and revoked), with their name, phone and summary.
  Future<List<Map<String, dynamic>>> list() async => [
        for (final r in (await _db.rpc('admin_list_approvers') as List)) Map<String, dynamic>.from(r as Map),
      ];

  /// Grant or re-configure [userId]. Returns the cleaned config the server kept.
  Future<Map<String, dynamic>> set(String userId, Map<String, dynamic> config) async => Map<String, dynamic>.from(
        (await _db.rpc('admin_set_approver', params: {'p_user': userId, 'p_config': config})) as Map,
      );

  /// Revoke [userId] (a soft revoke on the server — the grant goes inactive).
  Future<void> remove(String userId) async {
    await _db.rpc('admin_remove_approver', params: {'p_user': userId});
  }
}

final approversRepositoryProvider = Provider((ref) => ApproversRepository(ref.watch(supabaseProvider)));
