// Office NAS maps (migration 0319): the admin's side. The status (settings,
// the NAS's check-in, connected NAS, what it answered), saving the
// settings, pairing codes and disconnecting.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/nas_maps.dart';
import '../providers.dart';

class NasMapsRepository {
  NasMapsRepository(this._db);
  final SupabaseClient _db;

  Future<NasMapsStatus> status() async => NasMapsStatus.fromJson(await _db.rpc('admin_nas_maps_status'));

  Future<NasMapsSettings> save(NasMapsSettings s) async =>
      NasMapsSettings.fromJson(await _db.rpc('admin_nas_maps_set', params: {'p': s.toJson()}));

  /// A one-time code (XXXX-XXXX, 10 minutes) for the NAS to connect with.
  Future<({String code, DateTime? expiresAt})> pairingCode(String label) async {
    final r = await _db.rpc('admin_nas_maps_pairing_code', params: {'p_label': label});
    final m = r is Map ? r : const {};
    return (code: '${m['code'] ?? ''}', expiresAt: DateTime.tryParse('${m['expires_at']}')?.toLocal());
  }

  Future<void> remove(String id) => _db.rpc('admin_nas_maps_remove', params: {'p_id': id});
}

final nasMapsRepositoryProvider = Provider((ref) => NasMapsRepository(ref.watch(supabaseProvider)));

final nasMapsStatusProvider = FutureProvider.autoDispose<NasMapsStatus>(
  (ref) => ref.watch(nasMapsRepositoryProvider).status(),
);
