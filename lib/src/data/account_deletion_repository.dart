// Deleting your own account, and the admin's linking and final deletion
// (migration 0194).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/account_deletion.dart';
import '../providers.dart';
import 'live_tables.dart';

class AccountDeletionRepository {
  AccountDeletionRepository(this._db);
  final SupabaseClient _db;

  Future<AccountDeletionCheck> check() async =>
      AccountDeletionCheck.fromJson(await _db.rpc('my_account_deletion_check'));

  /// Deletes the signed-in account, confirmed by [pin] or by an SMS code
  /// verified on this session just before. Null when deleted, else why not.
  Future<String?> delete({String? pin, String? reason}) async =>
      deleteAccountProblem(await _db.rpc('delete_my_account', params: {'p_pin': pin, 'p_reason': reason}));

  /// After deleting: the server already ended every session.
  Future<void> signOutHere() async {
    try {
      await _db.auth.signOut(scope: SignOutScope.local);
    } catch (_) {}
  }

  // ---- Admin ----------------------------------------------------------------------------------

  Future<int> retentionDays() async {
    final r = await _db.rpc('account_deletion_config');
    return r is Map && r['retentionDays'] is num ? (r['retentionDays'] as num).toInt() : 365;
  }

  Future<int> saveRetentionDays(int days) async {
    final r = await _db.rpc(
      'set_account_deletion_config',
      params: {
        'p_config': {'retentionDays': days},
      },
    );
    return r is Map && r['retentionDays'] is num ? (r['retentionDays'] as num).toInt() : days;
  }

  Future<List<AccountEvent>> events(String profileId) async => [
    for (final r
        in await _db
            .from('account_events')
            .select()
            .or('profile_id.eq.$profileId,other_profile_id.eq.$profileId')
            .order('created_at', ascending: false))
      AccountEvent(r),
  ];

  /// Deleted accounts an admin can link: those that used [phone] first,
  /// then the most recent, never ones already wiped.
  Future<List<Map<String, dynamic>>> deletedAccounts({String? phone, String? search}) async {
    var q = _db.from('profiles').select().not('deleted_at', 'is', null).isFilter('final_deleted_at', null);
    final s = search?.trim() ?? '';
    if (s.isNotEmpty) {
      final like = '%${s.replaceAll(RegExp(r'[%,()]'), '')}%';
      q = q.or('deleted_phone.ilike.$like,name.ilike.$like');
    }
    final rows = await q.order('deleted_at', ascending: false).limit(50);
    final digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
    bool same(Map r) => digits.isNotEmpty && '${r['deleted_phone']}'.replaceAll(RegExp(r'\D'), '') == digits;
    return [...rows.where(same), ...rows.where((r) => !same(r))];
  }

  Future<Map<String, dynamic>> link(String oldId, String newId, Set<AccountLinkCategory> what) async {
    final r = await _db.rpc(
      'admin_link_account',
      params: {
        'p_old': oldId,
        'p_new': newId,
        'p_categories': [for (final c in what) c.key],
      },
    );
    return r is Map ? Map<String, dynamic>.from(r) : const {};
  }

  Future<List<Map<String, dynamic>>> dueForFinalDeletion() async => [
    for (final r in await _db.rpc('accounts_due_final_deletion') as List) Map<String, dynamic>.from(r as Map),
  ];

  /// Wipes the account's personal data, then empties its storage folders.
  /// Returns how many files were removed; a folder that couldn't be emptied
  /// is left for a retry (running it again is safe).
  Future<int> finalDelete(String profileId) async {
    final r = await _db.rpc('admin_final_delete_account', params: {'p_profile': profileId});
    var removed = 0;
    for (final f in (r is Map ? r['folders'] as List? : null) ?? const []) {
      if (f is! Map) continue;
      final bucket = _db.storage.from('${f['bucket']}');
      final paths = await _files(bucket, '${f['folder']}', 3);
      for (var i = 0; i < paths.length; i += 100) {
        final batch = paths.sublist(i, i + 100 > paths.length ? paths.length : i + 100);
        removed += (await bucket.remove(batch)).length;
      }
    }
    return removed;
  }

  /// Every file under [folder], a few levels down.
  Future<List<String>> _files(StorageFileApi bucket, String folder, int depth) async {
    final out = <String>[];
    final List<FileObject> items;
    try {
      items = await bucket.list(path: folder);
    } catch (_) {
      return out;
    }
    for (final item in items) {
      final path = '$folder/${item.name}';
      if (item.id != null) {
        out.add(path);
      } else if (depth > 0) {
        out.addAll(await _files(bucket, path, depth - 1));
      }
    }
    return out;
  }
}

final accountDeletionRepositoryProvider = Provider((ref) => AccountDeletionRepository(ref.watch(supabaseProvider)));

/// The admin's retention setting.
final accountRetentionDaysProvider = FutureProvider.autoDispose<int>((ref) async {
  ref.watchAdminLive('profiles');
  try {
    return await ref.watch(accountDeletionRepositoryProvider).retentionDays();
  } catch (_) {
    return 365;
  }
});
