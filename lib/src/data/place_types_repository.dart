import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/place_types.dart';
import '../providers.dart';
import 'live_tables.dart';

/// The place types (Admin > Place types, migration 0264), in the admin's
/// order, followed live. The types 0264 starts with until the table is read,
/// or when it can't be (signed out, before 0264), so a place always shows
/// an icon.
final placeTypesProvider = FutureProvider<List<PlaceType>>((ref) async {
  ref.watchLive('place_types');
  try {
    final rows = await ref
        .watch(supabaseProvider)
        .from('place_types')
        .select('key, name, icon, color, color_dark, sort_order, active')
        .order('sort_order', ascending: true)
        .order('name', ascending: true);
    final list = [for (final r in rows) PlaceType.fromRow(Map<String, dynamic>.from(r))];
    return list.isEmpty ? defaultPlaceTypes : sortPlaceTypes(list);
  } catch (_) {
    return defaultPlaceTypes;
  }
});

/// The types now: the last read, else the starting ones.
List<PlaceType> placeTypesNow(WidgetRef ref) => ref.watch(placeTypesProvider).value ?? defaultPlaceTypes;
