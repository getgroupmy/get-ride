import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/place_gates.dart';
import '../providers.dart';

/// The admin's multi-gate places (plus airports, which count as places) and
/// their gates, for the place picker. Empty when they can't be read, so
/// search simply works without gates.
typedef GateCatalogue = ({List<GateRow> places, List<GateRow> gates});

final placeGatesProvider = FutureProvider<GateCatalogue>((ref) async {
  final db = ref.watch(supabaseProvider);
  GateRow row(Map<String, dynamic> r) =>
      (id: '${r['id']}', values: Map<String, dynamic>.from((r['values'] as Map?) ?? const {}));
  Future<List<Map<String, dynamic>>> read(Future<List<Map<String, dynamic>>> Function() q) async {
    try {
      return await q();
    } catch (_) {
      return const [];
    }
  }

  final results = await Future.wait([
    read(() => db.from('multi_gate').select('id, kind, values, position').order('position')),
    read(() => db.from('airport_areas').select('id, values, position').order('position')),
  ]);
  final multi = results[0];
  return (
    places: [
      for (final r in multi)
        if (r['kind'] == 'place') row(r),
      for (final r in results[1]) row(r),
    ],
    gates: [
      for (final r in multi)
        if (r['kind'] == 'gate') row(r),
    ],
  );
});
