/// Who may drive which vehicle, and who is driving it now — pure port of
/// Expo `utils/vehicleAssignmentStore.ts`.
///
/// A vehicle can have several drivers: its owner (who added it), plus
/// drivers and co-drivers an admin links in `vehicle_user_assignment`. Only
/// one of them drives it at a time: the `claim_vehicle` RPC opens a
/// `vehicle_active_session` (one per vehicle, one per driver) and
/// `release_vehicle` closes it so the next driver can take the car.
library;

import 'vehicle_onboarding.dart';

enum VehicleRole { owner, driver, coDriver }

VehicleRole parseVehicleRole(Object? v) => switch ('${v ?? ''}'.trim().toLowerCase()) {
  'owner' => VehicleRole.owner,
  'co-driver' || 'codriver' || 'co_driver' => VehicleRole.coDriver,
  _ => VehicleRole.driver,
};

/// The value stored in `vehicle_user_assignment.role`.
String vehicleRoleValue(VehicleRole r) => switch (r) {
  VehicleRole.owner => 'owner',
  VehicleRole.driver => 'driver',
  VehicleRole.coDriver => 'co-driver',
};

String vehicleRoleLabel(VehicleRole r) => switch (r) {
  VehicleRole.owner => 'Owner',
  VehicleRole.driver => 'Driver',
  VehicleRole.coDriver => 'Co-driver',
};

enum AssignableStatus { inUseByYou, available, pendingReview, incomplete, contactAdmin }

String assignableStatusLabel(AssignableStatus s) => switch (s) {
  AssignableStatus.inUseByYou => 'Driving now',
  AssignableStatus.available => 'Available',
  AssignableStatus.pendingReview => 'Pending review',
  AssignableStatus.incomplete => 'Setup not finished',
  AssignableStatus.contactAdmin => 'Contact admin',
};

const _blocked = {'blocked', 'deleted', 'rejected'};
const _pending = {
  'unapproved',
  'unapproved-docs',
  'permit-pending',
  'permit-non-verified',
  'permit-verified',
  'pending',
};

String _t(Object? v) => '${v ?? ''}'.trim().toLowerCase();

/// Expo `classifyVehicle`.
AssignableStatus _approval(Map<String, dynamic> v) {
  final s = _t(v['status']);
  final p = _t(v['permit']);
  if (_blocked.contains(s) || _blocked.contains(p)) return AssignableStatus.contactAdmin;
  if (v['documents_ok'] != true || _pending.contains(s) || _pending.contains(p)) {
    return AssignableStatus.pendingReview;
  }
  return AssignableStatus.available;
}

class AssignableVehicle {
  const AssignableVehicle({required this.vehicle, required this.role, required this.status});

  final Map<String, dynamic> vehicle;
  final VehicleRole role;
  final AssignableStatus status;

  String get id => '${vehicle['id']}';
  String get plate => '${vehicle['plate'] ?? ''}'.trim();
  String get title {
    final name = '${vehicle['make'] ?? ''} ${vehicle['model'] ?? ''}'.trim();
    return name.isEmpty ? 'Vehicle' : name;
  }

  bool get inUseByMe => status == AssignableStatus.inUseByYou;

  /// Whether picking it claims it (or re-confirms the one already held).
  bool get selectable => status == AssignableStatus.available || status == AssignableStatus.inUseByYou;

  /// Why it can't be picked, when it can't.
  String? get blockedReason => switch (status) {
    AssignableStatus.contactAdmin => 'This vehicle is locked. Contact an admin.',
    AssignableStatus.pendingReview => 'An admin is still reviewing this vehicle.',
    AssignableStatus.incomplete =>
      role == VehicleRole.owner ? 'Finish setting it up first.' : "The owner hasn't finished setting it up.",
    _ => null,
  };
}

/// Builds the picker list: the vehicles this account added (owner) and the
/// ones an admin assigned to it, each with its role and whether it can be
/// driven now. A driver can only read their own session, so a car someone
/// else is driving shows as available and the claim reports it.
List<AssignableVehicle> buildAssignableVehicles({
  required List<Map<String, dynamic>> owned,
  required List<Map<String, dynamic>> assignments,
  required List<Map<String, dynamic>> assignedVehicles,
  required String? mySessionVehicleId,
}) {
  final roles = <String, VehicleRole>{
    for (final a in assignments) '${a['vehicle_id']}': parseVehicleRole(a['role']),
    for (final v in owned) '${v['id']}': VehicleRole.owner,
  };
  final seen = <String>{};
  final all = [
    for (final v in [...owned, ...assignedVehicles])
      if (seen.add('${v['id']}')) v,
  ];
  final list = [
    for (final v in all)
      AssignableVehicle(
        vehicle: v,
        role: roles['${v['id']}'] ?? VehicleRole.driver,
        status: () {
          final approval = _approval(v);
          if (approval == AssignableStatus.contactAdmin) return approval;
          if (firstVehicleStep(v) != VehicleStep.done) return AssignableStatus.incomplete;
          if (approval == AssignableStatus.pendingReview) return approval;
          return '${v['id']}' == mySessionVehicleId ? AssignableStatus.inUseByYou : AssignableStatus.available;
        }(),
      ),
  ];
  int rank(AssignableVehicle a) => a.inUseByMe ? 0 : (a.selectable ? 1 : 2);
  list.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : a.plate.compareTo(b.plate);
  });
  return list;
}

/// True when the database refused the caller rather than the request: the
/// vehicle-session RPCs only act on the signed-in user's own id
/// (`not_authorized`, 42501) and can't be called without a session at all.
bool _vehicleSessionRefusedCaller(String msg) =>
    msg.contains('not_authorized') || msg.contains('42501') || msg.contains('permission denied');

/// The words for a `claim_vehicle` refusal.
String claimVehicleErrorMessage(Object error) {
  final msg = '$error';
  if (_vehicleSessionRefusedCaller(msg)) return 'Sign in again to use a vehicle.';
  if (msg.contains('vehicle_in_use')) return 'Another driver is using this vehicle. Ask them to hand it back first.';
  if (msg.contains('user_busy')) return "You're already driving another vehicle. Hand that one back first.";
  if (msg.contains('not_assigned')) return "You're not assigned to this vehicle any more.";
  return "Couldn't select this vehicle. Please try again.";
}

/// The words for a `release_vehicle` failure.
String releaseVehicleErrorMessage(Object error) {
  if (_vehicleSessionRefusedCaller('$error')) return 'Sign in again to hand the vehicle back.';
  return "Couldn't hand the vehicle back. Try again.";
}

// ---- Admin -------------------------------------------------------------------

/// The `vehicle_user_assignment` row an admin writes. Upserted on
/// (vehicle_id, user_id), so assigning someone again just updates the role
/// and switches the link back on.
Map<String, dynamic> assignmentRow({
  required String vehicleId,
  required String userId,
  required String? partnerId,
  required VehicleRole role,
  required String? adminId,
}) => {
  'vehicle_id': vehicleId,
  'user_id': userId,
  'partner_id': partnerId,
  'role': vehicleRoleValue(role),
  'assigned_by': adminId,
  'assigned_at': DateTime.now().toUtc().toIso8601String(),
  'is_active': true,
};

/// Digits only, for matching a typed phone number against stored ones.
String phoneDigits(String phone) => phone.replaceAll(RegExp(r'\D'), '');

/// Whether two phone numbers are the same line: equal digits, or (for
/// numbers typed with or without a country code) the same last nine digits —
/// the rule `wallet_request_coin_transfer` uses.
bool samePhone(String a, String b) {
  final x = phoneDigits(a);
  final y = phoneDigits(b);
  if (x.length < 7 || y.length < 7) return false;
  if (x == y) return true;
  return x.length >= 9 && y.length >= 9 && x.substring(x.length - 9) == y.substring(y.length - 9);
}
