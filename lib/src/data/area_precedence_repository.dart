// Places inside an airport (migration 0266): the admin's one setting for
// which area a point in both an airport's and a place's boundary is at, and
// the "Part of" of every area it compares (core/airport_areas.dart's
// AreaPrecedenceRule). The server's area_at reads the same setting.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/airport_areas.dart';
import '../core/place_gates.dart' show partOfKey;
import '../providers.dart';
import 'live_tables.dart';
import 'place_gates_repository.dart';

const areaPrecedenceTable = 'area_precedence_settings';

class AreaPrecedenceRepository {
  AreaPrecedenceRepository(this._db);
  final SupabaseClient _db;

  /// The setting; the default when there is no row.
  Future<AreaPrecedence> mode() async {
    final row = await _db.from(areaPrecedenceTable).select('mode').eq('id', 1).maybeSingle();
    return AreaPrecedence.of(row?['mode']);
  }

  Future<void> setMode(AreaPrecedence mode) =>
      _db.from(areaPrecedenceTable).update({'mode': mode.key}).eq('id', 1);
}

final areaPrecedenceRepositoryProvider = Provider((ref) => AreaPrecedenceRepository(ref.watch(supabaseProvider)));

/// The setting, live; the default (Part of) when unreadable.
final areaPrecedenceProvider = FutureProvider<AreaPrecedence>((ref) async {
  ref.watchLive(areaPrecedenceTable);
  try {
    return await ref.watch(areaPrecedenceRepositoryProvider).mode();
  } catch (_) {
    return AreaPrecedence.partOf;
  }
});

/// The setting with every area's "Part of" (the airports' and the places'
/// own, from the gate catalogue), for gate_snap.dart's `gateAreaAt`.
final areaPrecedenceRuleProvider = FutureProvider<AreaPrecedenceRule>((ref) async {
  final mode = await ref.watch(areaPrecedenceProvider.future);
  final catalogue = await ref.watch(placeGatesProvider.future);
  return AreaPrecedenceRule(
    mode: mode,
    partOf: {
      for (final p in catalogue.places)
        if (partOfKey(p.values['partOf']) case final key when key.isNotEmpty) p.id: key,
    },
  );
});
