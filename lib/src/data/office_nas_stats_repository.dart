// Visitor stats (migration 0321): the settings, and today's numbers read
// from Umami on the office NAS through the nas-stats function.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/office_nas_stats.dart';
import '../providers.dart';

class OfficeNasStatsRepository {
  OfficeNasStatsRepository(this._db);
  final SupabaseClient _db;

  Future<NasStatsSettings> config() async => NasStatsSettings.fromJson(await _db.rpc('admin_nas_stats_config'));

  Future<NasStatsSettings> save(NasStatsSettings s) async =>
      NasStatsSettings.fromJson(await _db.rpc('admin_nas_stats_set', params: {'p': s.toJson()}));

  /// Today's numbers, or why there are none. Never throws: a function that
  /// can't be reached reads as "NAS off".
  Future<VisitorStats> today() async {
    try {
      final res = await _db.functions.invoke('nas-stats', body: const {});
      return VisitorStats.fromJson(res.data);
    } catch (_) {
      return const VisitorStats.unreachable();
    }
  }
}

final officeNasStatsRepositoryProvider = Provider((ref) => OfficeNasStatsRepository(ref.watch(supabaseProvider)));
