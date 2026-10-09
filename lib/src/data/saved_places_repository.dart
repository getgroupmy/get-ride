import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/saved_places.dart';
import '../providers.dart';

/// The rider's saved places (`saved_places`, migration 0116; own rows only).
class SavedPlacesRepository {
  SavedPlacesRepository(this._db);
  final SupabaseClient _db;

  Future<List<SavedPlace>> list() async {
    final rows = await _db.from('saved_places').select().order('created_at');
    return [for (final r in rows) ?SavedPlace.fromRow(r)];
  }

  /// Adds [p], or updates it when it has an id. Home and Work replace the
  /// one already saved.
  Future<SavedPlace?> save(SavedPlace p) async {
    final row = p.toRow();
    final Map<String, dynamic> saved;
    if (p.id != null) {
      saved = await _db.from('saved_places').update(row).eq('id', p.id!).select().single();
    } else if (p.kind != SavedPlaceKind.other) {
      await _db.from('saved_places').delete().eq('kind', p.kind.name);
      saved = await _db.from('saved_places').insert(row).select().single();
    } else {
      saved = await _db.from('saved_places').insert(row).select().single();
    }
    return SavedPlace.fromRow(saved);
  }

  Future<void> delete(String id) => _db.from('saved_places').delete().eq('id', id);
}

final savedPlacesRepositoryProvider = Provider((ref) => SavedPlacesRepository(ref.watch(supabaseProvider)));

/// The signed-in rider's saved places; empty when signed out or unreadable
/// (an older database).
final savedPlacesProvider = FutureProvider.autoDispose<List<SavedPlace>>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return const [];
  try {
    return await ref.watch(savedPlacesRepositoryProvider).list();
  } catch (_) {
    return const [];
  }
});
