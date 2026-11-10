import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart' show currentUserIdProvider, supabaseProvider;

/// A driver another approver added to the signed-in owner's vehicle, waiting on
/// the owner's consent (migrations 0377 + 0391).
class OwnerDriverRequest {
  const OwnerDriverRequest({
    required this.assignmentId,
    required this.vehicleId,
    this.plate,
    this.vehicleLabel,
    required this.driverId,
    required this.driverName,
    this.driverPhone,
    this.driverAvatar,
    this.requestedAt,
  });

  final String assignmentId;
  final String vehicleId;
  final String? plate;
  final String? vehicleLabel;
  final String driverId;
  final String driverName;
  final String? driverPhone;
  final String? driverAvatar;
  final DateTime? requestedAt;

  static String? _s(Object? v) {
    final t = '${v ?? ''}'.trim();
    return t.isEmpty ? null : t;
  }

  static OwnerDriverRequest fromJson(Map<String, dynamic> j) => OwnerDriverRequest(
        assignmentId: '${j['assignment_id']}',
        vehicleId: '${j['vehicle_id']}',
        plate: _s(j['plate']),
        vehicleLabel: _s(j['vehicle_label']),
        driverId: '${j['driver_id']}',
        driverName: _s(j['driver_name']) ?? 'A driver',
        driverPhone: _s(j['driver_phone']),
        driverAvatar: _s(j['driver_avatar']),
        requestedAt: j['requested_at'] == null ? null : DateTime.tryParse('${j['requested_at']}')?.toLocal(),
      );
}

/// The owner's side of driver access: the requests waiting on them, and
/// approve / decline. Owner-scoped server-side (vehicle.auth_user_id = caller).
class VehicleAccessRepository {
  VehicleAccessRepository(this._db);
  final SupabaseClient _db;

  Future<List<OwnerDriverRequest>> pendingDrivers() async {
    final r = await _db.rpc('vehicle_owner_pending_drivers');
    return [for (final e in (r as List? ?? const [])) OwnerDriverRequest.fromJson(Map<String, dynamic>.from(e as Map))];
  }

  /// Approve ([approve] true) or decline a pending driver. Returns the new
  /// approval state. Throws `not_allowed` if the caller doesn't own the vehicle.
  Future<String> respond(String assignmentId, {required bool approve}) async {
    final r = await _db.rpc('vehicle_owner_respond_driver',
        params: {'p_assignment': assignmentId, 'p_approve': approve});
    final m = r is Map ? Map<String, dynamic>.from(r) : const <String, dynamic>{};
    return '${m['approval'] ?? (approve ? 'approved' : 'declined')}';
  }
}

final vehicleAccessRepositoryProvider =
    Provider((ref) => VehicleAccessRepository(ref.watch(supabaseProvider)));

/// The driver-access requests waiting on the signed-in owner. Empty when signed
/// out or on a legacy database without the RPC.
final ownerDriverRequestsProvider =
    FutureProvider.autoDispose<List<OwnerDriverRequest>>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return const <OwnerDriverRequest>[];
  try {
    return await ref.watch(vehicleAccessRepositoryProvider).pendingDrivers();
  } catch (_) {
    return const <OwnerDriverRequest>[];
  }
});
