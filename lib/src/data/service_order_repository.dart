// The vehicle service order for every booking (migration 0250): the admin's
// switch, and the approved vehicles still without an approved service type,
// to set before turning it on. The order itself is
// airport_repository.dart's (vehicle_service_order, 0249).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';
import 'live_tables.dart';

/// An approved vehicle without an approved service type.
typedef VehicleMissingService = ({
  String id,
  String plate,
  String label,
  String requested,
});

class ServiceOrderRepository {
  ServiceOrderRepository(this._db);
  final SupabaseClient _db;

  /// Whether the order applies to every booking (off when unreadable).
  Future<bool> enforced() async {
    final row = await _db
        .from('service_order_settings')
        .select('enforce_all')
        .eq('id', 1)
        .maybeSingle();
    return row?['enforce_all'] == true;
  }

  Future<void> setEnforced(bool on) => _db
      .from('service_order_settings')
      .update({'enforce_all': on})
      .eq('id', 1);

  /// Approved vehicles whose service type isn't approved yet, by plate.
  Future<List<VehicleMissingService>> vehiclesMissingService() async {
    final rows = await _db
        .from('vehicle')
        .select('id, plate, make, model, service_id')
        .eq('status', 'approved')
        .isFilter('service_approved_id', null)
        .order('plate')
        .limit(1000);
    return [
      for (final r in rows)
        (
          id: '${r['id']}',
          plate: '${r['plate'] ?? ''}',
          label: [r['make'], r['model']]
              .map((x) => '${x ?? ''}'.trim())
              .where((x) => x.isNotEmpty)
              .join(' '),
          requested: '${r['service_id'] ?? ''}',
        ),
    ];
  }
}

final serviceOrderRepositoryProvider = Provider(
  (ref) => ServiceOrderRepository(ref.watch(supabaseProvider)),
);

final serviceOrderEnforcedProvider = FutureProvider<bool>((ref) async {
  ref.watchLive('service_order_settings');
  try {
    return await ref.watch(serviceOrderRepositoryProvider).enforced();
  } catch (_) {
    return false;
  }
});

final vehiclesMissingServiceProvider =
    FutureProvider.autoDispose<List<VehicleMissingService>>((ref) async {
      ref.watchAdminLive('vehicle');
      return ref.watch(serviceOrderRepositoryProvider).vehiclesMissingService();
    });

/// "Turn it on now and N vehicles without an approved service type only get
/// orders of a service that isn't ranked." Null when none are missing.
String? enforceWarning(int missing) => missing == 0
    ? null
    : '$missing approved ${missing == 1 ? 'vehicle has' : 'vehicles have'} no approved service type. '
          "With the order on for every booking, ${missing == 1 ? 'its driver' : 'their drivers'} only get orders "
          "of a service that isn't one of the Vehicle Services. Set ${missing == 1 ? 'it' : 'them'} first.";
