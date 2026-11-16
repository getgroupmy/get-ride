// Advance-booking surcharge rates (migration 0414): the booking sheet reads the
// active rows live and previews the "+ RM x scheduling fee" the server will
// charge. Empty where the table isn't in the database yet (older backend) — the
// booking then falls back to the global scheduled-rides fee, as before.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/scheduling_surcharge.dart';
import '../providers.dart';
import 'live_tables.dart';

export '../core/scheduling_surcharge.dart';

/// Every active advance-booking surcharge rate, refetched when an admin saves.
final schedulingSurchargeRatesProvider = FutureProvider<List<SchedulingSurchargeRule>>((ref) async {
  ref.watchLive('scheduling_surcharge_rates');
  try {
    final rows = await ref.watch(supabaseProvider).from('scheduling_surcharge_rates').select().eq('active', true);
    return [for (final r in rows) SchedulingSurchargeRule.fromRow(Map<String, dynamic>.from(r as Map))];
  } catch (_) {
    return const <SchedulingSurchargeRule>[];
  }
});
