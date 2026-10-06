// IO for the global display settings row (`admin_display_settings`,
// id `global`), shared by the Display and Mock / Simulation screens.
//
// Every edit is read-modify-write: the latest blob is fetched, the edit is
// applied to it and the whole object is upserted, which is the shape the
// Expo `updateRemoteDisplaySettings` writes. Writes run with the signed-in
// admin's session (RLS `caller_is_admin()`).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/app_display_repository.dart';
import '../../../providers.dart';
import 'display_logic.dart';
import '../../../data/live_tables.dart';

typedef DisplayEdit = Map<String, dynamic> Function(Map<String, dynamic> settings);

class DisplaySettingsStore {
  DisplaySettingsStore(this._db);
  final SupabaseClient _db;

  Future<Map<String, dynamic>> fetch() async {
    final row = await _db
        .from(displaySettingsTable)
        .select('settings')
        .eq('id', displaySettingsRowId)
        .maybeSingle();
    return mergeDisplaySettings(row?['settings']);
  }

  Future<Map<String, dynamic>> update(DisplayEdit edit) async {
    final next = edit(await fetch());
    await _db.from(displaySettingsTable).upsert({
      'id': displaySettingsRowId,
      'settings': next,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'id');
    return next;
  }

  /// Settings entries of another category (read only), e.g. the services the
  /// home boxes link to.
  Future<List<Map<String, dynamic>>> entries(String category) async => List<Map<String, dynamic>>.from(
        await _db.from('settings_entries').select('id, values, position').eq('category', category).order('position'),
      );
}

final displayStoreProvider = Provider((ref) => DisplaySettingsStore(ref.watch(supabaseProvider)));

class DisplaySettingsController extends AsyncNotifier<Map<String, dynamic>> {
  @override
  Future<Map<String, dynamic>> build() {
    ref.watchLive(displaySettingsTable);
    return ref.watch(displayStoreProvider).fetch();
  }

  /// Applies [edit] optimistically, then writes it; reverts and rethrows on a
  /// refused write.
  Future<void> apply(DisplayEdit edit) async {
    final prev = state.value;
    if (prev != null) state = AsyncData(edit(prev));
    try {
      final next = await ref.read(displayStoreProvider).update(edit);
      state = AsyncData(next);
      // The rest of this app reads the row live; refresh it now rather than
      // wait for the realtime echo of the admin's own write.
      ref.invalidate(displaySettingsBlobProvider);
    } catch (_) {
      if (prev != null) state = AsyncData(prev);
      rethrow;
    }
  }
}

final displaySettingsProvider =
    AsyncNotifierProvider.autoDispose<DisplaySettingsController, Map<String, dynamic>>(DisplaySettingsController.new);

final settingsEntriesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>(
  (ref, category) {
  ref.watchLive('settings_entries');
  return ref.watch(displayStoreProvider).entries(category);
},
);
