// Office NAS backups and uptime (migration 0318): what Admin > Settings >
// Office NAS reads and changes. Admins only; the server checks every call.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/office_nas.dart';
import '../providers.dart';

/// One check in a target's history.
typedef UptimeCheckRow = ({DateTime at, String source, UptimeStatus status, int? ms, String? detail});

class OfficeNasRepository {
  OfficeNasRepository(this._db);
  final SupabaseClient _db;

  Future<OfficeNasState> load() async => OfficeNasState.fromJson(await _db.rpc('admin_office_nas'));

  Future<NasBackupSettings> saveBackup(NasBackupSettings s) async =>
      NasBackupSettings.fromJson(await _db.rpc('admin_nas_backup_set', params: {'p': s.toJson()}));

  Future<NasUptimeSettings> saveUptime(NasUptimeSettings s) async =>
      NasUptimeSettings.fromJson(await _db.rpc('admin_nas_uptime_set', params: {'p': s.toJson()}));

  /// "Back up now" or "Run a restore test": the NAS takes it within a minute.
  Future<void> request(RunKind kind) =>
      _db.rpc('admin_nas_backup_request', params: {'p_kind': kind == RunKind.backup ? 'backup' : 'restore_test'});

  Future<void> saveTarget(Map<String, dynamic> target) => _db.rpc('admin_uptime_target_save', params: {'p': target});

  Future<void> deleteTarget(String id) => _db.rpc('admin_uptime_target_delete', params: {'p_id': id});

  Future<void> testAlert() => _db.rpc('admin_uptime_test_alert');

  Future<List<UptimeCheckRow>> history(String target) async {
    final rows = await _db.rpc('admin_uptime_history', params: {'p_target': target});
    return [
      for (final r in (rows is List ? rows : const []))
        if (r is Map && DateTime.tryParse('${r['checked_at']}') != null)
          (
            at: DateTime.parse('${r['checked_at']}').toLocal(),
            source: '${r['source']}',
            status: UptimeStatus.of(r['status']),
            ms: (r['ms'] as num?)?.round(),
            detail: r['detail'] as String?,
          ),
    ];
  }

  /// A one-time code (XXXX-XXXX, 10 minutes) for the NAS app to connect with.
  Future<({String code, DateTime? expiresAt})> pairingCode(String label) async {
    final r = await _db.rpc('admin_nas_ops_pairing_code', params: {'p_label': label});
    final m = r is Map ? r : const {};
    return (code: '${m['code'] ?? ''}', expiresAt: DateTime.tryParse('${m['expires_at']}')?.toLocal());
  }

  Future<void> disconnect(String id) => _db.rpc('admin_nas_ops_remove', params: {'p_id': id});
}

final officeNasRepositoryProvider = Provider((ref) => OfficeNasRepository(ref.watch(supabaseProvider)));

final officeNasProvider = FutureProvider.autoDispose<OfficeNasState>((ref) => ref.watch(officeNasRepositoryProvider).load());
