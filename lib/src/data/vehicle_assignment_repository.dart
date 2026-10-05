import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/vehicle_assignment.dart';
import '../providers.dart';

/// A driver linked to a vehicle, as an admin sees it.
class VehicleDriver {
  const VehicleDriver({
    required this.assignmentId,
    required this.userId,
    required this.role,
    required this.active,
    this.name,
    this.phone,
    this.drivingNow = false,
  });

  final String assignmentId;
  final String userId;
  final VehicleRole role;
  final bool active;
  final String? name;
  final String? phone;
  final bool drivingNow;
}

/// `vehicle_user_assignment` + `vehicle_active_session` (migrations 0031 /
/// 0035). Drivers read their own links and session and move through the
/// `claim_vehicle` / `release_vehicle` RPCs; admins write the links.
class VehicleAssignmentRepository {
  VehicleAssignmentRepository(this._db);
  final SupabaseClient _db;

  String get _uid {
    final id = _db.auth.currentUser?.id;
    if (id == null) throw StateError('Not signed in');
    return id;
  }

  /// Every vehicle this account may drive, with its role and state.
  Future<List<AssignableVehicle>> assignable() async {
    final uid = _uid;
    final results = await Future.wait<Object?>([
      _db.from('vehicle').select().eq('auth_user_id', uid),
      _db
          .from('vehicle_user_assignment')
          .select('vehicle_id, role')
          .eq('user_id', uid)
          .eq('is_active', true)
          .then<Object?>((v) => v, onError: (_) => const <Map<String, dynamic>>[]),
      _db
          .from('vehicle_active_session')
          .select('vehicle_id')
          .eq('user_id', uid)
          .maybeSingle()
          .then<Object?>((v) => v, onError: (_) => null),
    ]);
    final owned = List<Map<String, dynamic>>.from(results[0] as List);
    final assignments = List<Map<String, dynamic>>.from(results[1] as List);
    final ownedIds = {for (final v in owned) '${v['id']}'};
    final missing = [
      for (final a in assignments)
        if (!ownedIds.contains('${a['vehicle_id']}')) '${a['vehicle_id']}',
    ];
    final assigned = missing.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(await _db.from('vehicle').select().inFilter('id', missing));
    final session = results[2] as Map<String, dynamic>?;
    return buildAssignableVehicles(
      owned: owned,
      assignments: assignments,
      assignedVehicles: assigned,
      mySessionVehicleId: session == null ? null : '${session['vehicle_id']}',
    );
  }

  /// Takes the vehicle (or re-confirms it). Throws the RPC's refusal
  /// (`vehicle_in_use`, `user_busy`, `not_assigned`).
  Future<void> claim(String vehicleId) =>
      _db.rpc('claim_vehicle', params: {'p_vehicle_id': vehicleId, 'p_user_id': _uid});

  /// Hands the vehicle back, so another driver can take it.
  Future<void> release() => _db.rpc('release_vehicle', params: {'p_user_id': _uid});

  // ---- Admin -----------------------------------------------------------------

  Future<List<VehicleDriver>> driversFor(String vehicleId) async {
    final rows = List<Map<String, dynamic>>.from(
      await _db
          .from('vehicle_user_assignment')
          .select('id, user_id, role, is_active')
          .eq('vehicle_id', vehicleId)
          .order('assigned_at'),
    );
    final session = await _db
        .from('vehicle_active_session')
        .select('user_id')
        .eq('vehicle_id', vehicleId)
        .maybeSingle();
    final ids = {for (final r in rows) '${r['user_id']}'}.toList();
    final profiles = ids.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(await _db.from('profiles').select('id, name, phone').inFilter('id', ids));
    final byId = {for (final p in profiles) '${p['id']}': p};
    return [
      for (final r in rows)
        VehicleDriver(
          assignmentId: '${r['id']}',
          userId: '${r['user_id']}',
          role: parseVehicleRole(r['role']),
          active: r['is_active'] != false,
          name: byId['${r['user_id']}']?['name'] as String?,
          phone: byId['${r['user_id']}']?['phone'] as String?,
          drivingNow: session != null && '${session['user_id']}' == '${r['user_id']}',
        ),
    ];
  }

  /// The account with this phone number (and its partner row, when it has
  /// one), or null.
  Future<({String userId, String? name, String? partnerId})?> findByPhone(String phone) async {
    final digits = phoneDigits(phone);
    if (digits.length < 7) return null;
    final tail = digits.substring(digits.length - 4);
    final candidates = List<Map<String, dynamic>>.from(
      await _db.from('profiles').select('id, name, phone').ilike('phone', '%$tail'),
    );
    final match = candidates.where((p) => samePhone('${p['phone'] ?? ''}', phone)).firstOrNull;
    if (match == null) return null;
    final partner = await _db.from('partners').select('id').eq('auth_user_id', '${match['id']}').limit(1).maybeSingle();
    return (userId: '${match['id']}', name: match['name'] as String?, partnerId: partner?['id'] as String?);
  }

  Future<void> assign(Map<String, dynamic> row) =>
      _db.from('vehicle_user_assignment').upsert(row, onConflict: 'vehicle_id,user_id');

  Future<void> setActive(String assignmentId, bool active) =>
      _db.from('vehicle_user_assignment').update({'is_active': active}).eq('id', assignmentId);

  Future<void> remove(String assignmentId) => _db.from('vehicle_user_assignment').delete().eq('id', assignmentId);

  /// Ends whoever is driving the vehicle now (e.g. a phone left signed in).
  Future<void> endSession(String vehicleId) => _db.from('vehicle_active_session').delete().eq('vehicle_id', vehicleId);
}

final vehicleAssignmentRepositoryProvider = Provider((ref) => VehicleAssignmentRepository(ref.watch(supabaseProvider)));

final assignableVehiclesProvider = FutureProvider.autoDispose(
  (ref) => ref.watch(vehicleAssignmentRepositoryProvider).assignable(),
);
