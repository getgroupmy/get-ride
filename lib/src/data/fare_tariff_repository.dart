import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/fare_tariff.dart';
import '../providers.dart';

/// Booking tariff cards (migration 0109).
class FareTariffRepository {
  FareTariffRepository(this._db);
  final SupabaseClient _db;

  /// The active cards. A database without the table (before 0109), or one
  /// that can't be read, has none: quotes stay on the built-in tariff.
  Future<List<FareTariff>> active() async {
    try {
      final rows = await _db.from('fare_tariffs').select().eq('active', true);
      return [for (final r in rows) FareTariff.fromRow(r)];
    } catch (_) {
      return const [];
    }
  }
}

final fareTariffRepositoryProvider = Provider((ref) => FareTariffRepository(ref.watch(supabaseProvider)));

final fareTariffsProvider = FutureProvider<List<FareTariff>>((ref) => ref.watch(fareTariffRepositoryProvider).active());
