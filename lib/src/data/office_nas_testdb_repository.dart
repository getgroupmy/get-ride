// The office NAS's test database (migration 0321): the tab's state, its
// settings, trying a PR's migrations, a fresh copy now, and connecting or
// disconnecting the runner on the NAS.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/office_nas_testdb.dart';
import '../providers.dart';

class OfficeNasTestDbRepository {
  OfficeNasTestDbRepository(this._db);
  final SupabaseClient _db;

  Future<TestDbState> state() async => TestDbState.fromJson(await _db.rpc('admin_testdb_state'));

  Future<TestDbSettings> save(TestDbSettings s) async =>
      TestDbSettings.fromJson(await _db.rpc('admin_testdb_set', params: {'p': s.toJson()}));

  /// Queues "try the migrations of PR #n" (or of a branch).
  Future<TestDbRun> tryMigration({int? pr, String? branch}) async => TestDbRun.fromJson(
      Map<String, dynamic>.from(await _db.rpc('admin_testdb_try', params: {'p_pr': pr, 'p_branch': branch}) as Map));

  Future<void> refreshNow() => _db.rpc('admin_testdb_refresh');

  Future<void> cancel(String id) => _db.rpc('admin_testdb_cancel', params: {'p_id': id});

  /// A one-time code (XXXX-XXXX, 10 minutes) for the runner to connect with.
  Future<({String code, DateTime? expiresAt})> pairingCode(String label) async {
    final r = await _db.rpc('admin_testdb_pairing_code', params: {'p_label': label});
    final m = r is Map ? r : const {};
    return (code: '${m['code'] ?? ''}', expiresAt: DateTime.tryParse('${m['expires_at']}')?.toLocal());
  }

  Future<void> removeRunner(String id) => _db.rpc('admin_testdb_runner_remove', params: {'p_id': id});
}

final officeNasTestDbRepositoryProvider =
    Provider((ref) => OfficeNasTestDbRepository(ref.watch(supabaseProvider)));
