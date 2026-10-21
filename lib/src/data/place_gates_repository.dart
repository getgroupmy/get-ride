import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/place_gates.dart';
import '../providers.dart';
import '../core/airport_areas.dart';
import 'live_tables.dart';

/// The admin's multi-gate places (plus airports, which count as places) and
/// their gates, for the place picker. Empty when they can't be read, so
/// search simply works without gates.
typedef GateCatalogue = ({List<GateRow> places, List<GateRow> gates});

final placeGatesProvider = FutureProvider<GateCatalogue>((ref) async {
  ref.watchLive('multi_gate');
  ref.watchLive('airport_areas');
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
    read(() => db.from('multi_gate').select('id, kind, values, position').order('position', ascending: true).order('created_at', ascending: true)),
    // A place's own area row (kind 'place', 0258) is the place itself, already
    // listed from multi_gate. Before 0258 there is no kind column.
    read(() async {
      try {
        return await db.from('airport_areas').select('id, values, position, kind').eq('kind', 'airport').order('position', ascending: true).order('created_at', ascending: true);
      } on PostgrestException {
        return await db.from('airport_areas').select('id, values, position').order('position', ascending: true).order('created_at', ascending: true);
      }
    }),
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

/// The areas with a drawn boundary, in the order a point is matched
/// ([areasByPrecedence]): Admin → Airport Areas' airports, then the
/// multi-gate places whose boundary is on (0258), smallest first. Empty
/// when unreadable. Search collapses results into airports only
/// ([airportsOnly]); the door picker and fares use every area.
final airportAreasProvider = FutureProvider<List<AirportArea>>((ref) async {
  ref.watchLive('airport_areas');
  final db = ref.watch(supabaseProvider);
  Map<String, dynamic> m(Object? v) => Map<String, dynamic>.from((v as Map?) ?? const {});
  try {
    List<Map<String, dynamic>> rows;
    try {
      rows = await db.from('airport_areas').select('id, values, kind, shape, active, size_m2').order('position', ascending: true).order('created_at', ascending: true);
    } on PostgrestException {
      // Before 0258: airports only.
      rows = await db.from('airport_areas').select('id, values').order('position', ascending: true).order('created_at', ascending: true);
    }
    return areasByPrecedence([
      for (final r in rows)
        if (r['kind'] != 'place')
          ?AirportArea.fromEntry('${r['id']}', m(r['values']))
        else if (r['active'] != false)
          ?AirportArea.fromEntry(
            '${r['id']}',
            {'name': m(r['values'])['name'], 'boundary': r['shape']},
            kind: AreaKind.place,
            sizeM2: (r['size_m2'] as num?)?.toDouble(),
          ),
    ]);
  } catch (_) {
    return const [];
  }
});

/// The airports among [areas] (search collapses results into these only;
/// places keep their gates in search, as before 0258).
List<AirportArea> airportsOnly(List<AirportArea> areas) => [for (final a in areas) if (!a.isPlace) a];
