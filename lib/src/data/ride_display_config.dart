// Region ride-display rules (migration 0411): the ride home reads the active
// rules live and resolves both switches on the device. Empty where the table
// isn't in the database yet (older backend) — the home then shows the AI fare
// and the distance·time line, as before.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ride_display_rules.dart';
import '../providers.dart';
import 'live_tables.dart';

export '../core/ride_display_rules.dart';

/// Every active region display rule, refetched the moment an admin saves.
final rideDisplayRulesProvider = FutureProvider<List<RideDisplayRule>>((ref) async {
  ref.watchLive('ride_display_rules');
  try {
    final rows = await ref.watch(supabaseProvider).from('ride_display_rules').select().eq('active', true);
    return [for (final r in rows) RideDisplayRule.fromRow(Map<String, dynamic>.from(r as Map))];
  } catch (_) {
    return const <RideDisplayRule>[];
  }
});
