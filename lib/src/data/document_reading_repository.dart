// Document reading (migration 0293): the reader order and switches every app
// follows, and the admin's side: saving them, connected readers (the office
// NAS, a GPU reading PC) with today's work, pairing codes and disconnecting.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/document_reading.dart';
import '../providers.dart';

class DocumentReadingRepository {
  DocumentReadingRepository(this._db);
  final SupabaseClient _db;

  Future<DocumentReadingConfig> config() async =>
      DocumentReadingConfig.fromJson(await _db.rpc('document_reading_config'));

  Future<DocumentReadingConfig> save(DocumentReadingConfig c) async =>
      DocumentReadingConfig.fromJson(await _db.rpc('admin_document_reading_set', params: {'p': c.toJson()}));

  Future<ReadersState> readers() async => ReadersState.fromJson(await _db.rpc('admin_doc_readers'));

  /// A one-time code (XXXX-XXXX, 10 minutes) for a reader to connect with.
  Future<({String code, DateTime? expiresAt})> pairingCode(DocReaderId kind, String label) async {
    final r = await _db.rpc('admin_doc_reader_pairing_code', params: {'p_kind': kind.name, 'p_label': label});
    final m = r is Map ? r : const {};
    return (code: '${m['code'] ?? ''}', expiresAt: DateTime.tryParse('${m['expires_at']}')?.toLocal());
  }

  Future<void> remove(String id) => _db.rpc('admin_doc_reader_remove', params: {'p_id': id});
}

final documentReadingRepositoryProvider = Provider((ref) => DocumentReadingRepository(ref.watch(supabaseProvider)));

/// The order and switches; the defaults (everything on) when they can't be read.
final documentReadingConfigProvider = FutureProvider<DocumentReadingConfig>((ref) async {
  try {
    return await ref.watch(documentReadingRepositoryProvider).config();
  } catch (_) {
    return DocumentReadingConfig.defaults;
  }
});
