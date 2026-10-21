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

  // A page at a time: the API answers at most 1,000 rows a request, and the
  // places and their gates outgrow that. Unpaged, every row past the first
  // 1,000 (the newest gates) was silently left out.
  Future<List<Map<String, dynamic>>> allGates() async {
    const page = 1000;
    final out = <Map<String, dynamic>>[];
    while (true) {
      final rows = await db
          .from('multi_gate')
          .select('id, kind, values, position')
          .order('position', ascending: true)
          .order('created_at', ascending: true)
          .order('id', ascending: true)
          .range(out.length, out.length + page - 1);
      out.addAll(rows);
      if (rows.length < page) return out;
    }
  }

  final results = await Future.wait([
    read(allGates),
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
      // An airport is always the Airport type (0264).
      for (final r in results[1])
        (id: row(r).id, values: {...row(r).values, 'placeType': 'airport', 'placeTypeSet': true}),
    ],
    gates: [
      for (final r in multi)
        if (r['kind'] == 'gate') row(r),
    ],
  );
});

/// The areas with a drawn boundary, in the order a point is matched
/// ([areasByPrecedence]): Admin → Airport Areas' airports, then the
/// multi-gate places whose boundary is on (0258), smallest first; a point in
/// both is at the one the admin's setting picks (gate_snap.dart's
/// `gateAreaAt`, 0266). Empty when unreadable. A place's area row has its name only: its search
/// grouping, address, position and type come from its multi_gate row (the
/// same id). Search collapses results into the areas that group them
/// ([AirportArea.groupResults]); the door picker and fares use every area.
final airportAreasProvider = FutureProvider<List<AirportArea>>((ref) async {
  ref.watchLive('airport_areas');
  ref.watchLive('multi_gate');
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
    final placeValues = <String, Map<String, dynamic>>{};
    if (rows.any((r) => r['kind'] == 'place')) {
      try {
        // A page at a time, past the API's 1,000-row cap.
        const page = 1000;
        for (var from = 0; ; from += page) {
          final rows = await db
              .from('multi_gate')
              .select('id, values')
              .eq('kind', 'place')
              .order('id', ascending: true)
              .range(from, from + page - 1);
          for (final r in rows) {
            placeValues['${r['id']}'] = m(r['values']);
          }
          if (rows.length < page) break;
        }
      } catch (_) {
        // Without them a place keeps its defaults: not grouped.
      }
    }
    return areasByPrecedence([
      for (final r in rows)
        if (r['kind'] != 'place')
          ?AirportArea.fromEntry('${r['id']}', m(r['values']))
        else if (r['active'] != false)
          ?AirportArea.fromEntry(
            '${r['id']}',
            placeAreaValues(m(r['values']), placeValues['${r['id']}'], r['shape']),
            kind: AreaKind.place,
            sizeM2: (r['size_m2'] as num?)?.toDouble(),
          ),
    ]);
  } catch (_) {
    return const [];
  }
});

/// A place area's entry for [AirportArea.fromEntry]: its area row's name and
/// [shape], with its multi_gate row's search grouping, address, position
/// and type ([place], null when unread).
Map<String, dynamic> placeAreaValues(Map<String, dynamic> area, Map<String, dynamic>? place, Object? shape) => {
  'name': area['name'],
  'boundary': shape,
  if (place != null)
    for (final k in const ['groupResults', 'groupWords', 'address', 'lat', 'lon', 'placeType'])
      if (place[k] != null) k: place[k],
};
