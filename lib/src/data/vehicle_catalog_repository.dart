import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart' show currentUserIdProvider, supabaseProvider;

/// One entry of the vehicle make/model catalogue (`vehicle_make_models`): a
/// make + model with its energy and body type. The Edit vehicle sheet drives
/// its Make / Model / Energy pickers from these so only real values are chosen,
/// and the AI lookup tops the catalogue up when something is missing (0387).
class VehicleCatalogEntry {
  const VehicleCatalogEntry({
    required this.make,
    required this.model,
    this.energyType,
    this.vehicleType,
    this.seats,
  });

  final String make;
  final String model;
  final String? energyType;
  final String? vehicleType;
  final int? seats;

  static String? _s(Object? v) {
    final t = '${v ?? ''}'.trim();
    return t.isEmpty ? null : t;
  }

  static VehicleCatalogEntry? fromJson(Map<String, dynamic> j) {
    final make = _s(j['make']);
    final model = _s(j['model']);
    if (make == null || model == null) return null;
    return VehicleCatalogEntry(
      make: make, model: model,
      energyType: _s(j['energy_type']), vehicleType: _s(j['vehicle_type']),
      seats: (j['seats'] as num?)?.toInt());
  }
}

/// Reads the active vehicle catalogue and, when asked, has an AI lookup
/// (Gemini) add a make/model that isn't on file yet.
class VehicleCatalogRepository {
  VehicleCatalogRepository(this._db);
  final SupabaseClient _db;

  /// Every active catalogue entry (make/model/energy/type), for the pickers.
  Future<List<VehicleCatalogEntry>> entries() async {
    final rows = await _db
        .from('vehicle_make_models')
        .select('make, model, energy_type, vehicle_type, seats')
        .eq('status', true)
        .order('make')
        .order('model') as List;
    return [
      for (final r in rows) ?VehicleCatalogEntry.fromJson(Map<String, dynamic>.from(r as Map)),
    ];
  }

  /// Ask the AI lookup to find a make (and optional model) and add what it
  /// returns to the catalogue (migration 0388 / edge function
  /// `vehicle-catalog-lookup`). Returns the entries now on file for that make.
  /// Needs can_manage_vehicle; the function re-checks server-side.
  Future<List<VehicleCatalogEntry>> lookup({required String make, String? model}) async {
    final res = await _db.functions.invoke('vehicle-catalog-lookup', body: {
      'make': make.trim(),
      if ((model ?? '').trim().isNotEmpty) 'model': model!.trim(),
    });
    final data = res.data;
    final list = (data is Map ? data['entries'] : null) as List? ?? const [];
    return [
      for (final r in list) ?VehicleCatalogEntry.fromJson(Map<String, dynamic>.from(r as Map)),
    ];
  }
}

final vehicleCatalogRepositoryProvider =
    Provider((ref) => VehicleCatalogRepository(ref.watch(supabaseProvider)));

/// The active vehicle catalogue, loaded once and shaped in the picker. Empty on
/// a legacy database or when the table can't be read.
final vehicleCatalogProvider =
    FutureProvider.autoDispose<List<VehicleCatalogEntry>>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return const <VehicleCatalogEntry>[];
  try {
    return await ref.watch(vehicleCatalogRepositoryProvider).entries();
  } catch (_) {
    return const <VehicleCatalogEntry>[];
  }
});
