/// Pure list filters for the admin people/vehicle screens, matching the
/// Expo `AdminUserList` / `AdminPartnerList` / `AdminVehicleList` rules.
library;

/// A user's effective status: `profile_status` (the admin decision) wins,
/// falling back to `status` (Expo `mapProfileStatus`).
String userStatus(Map<String, dynamic> row) {
  final ps = '${row['profile_status'] ?? ''}'.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  return switch (ps) {
    'approved' => 'approved',
    'un-approved' || 'unapproved' => 'unapproved',
    'blocked' => 'blocked',
    'rejected' => 'rejected',
    'deleted' => 'deleted',
    _ => (row['status'] as String?) ?? 'unapproved',
  };
}

bool userMatches(Map<String, dynamic> row, String filter) => switch (filter) {
      'all' => true,
      'unapproved-docs' => row['id_verified'] == 'Failed',
      _ => userStatus(row) == filter,
    };

/// Partners and vehicles share `partner_status` + `permit_status`.
bool partnerMatches(Map<String, dynamic> row, String filter) => switch (filter) {
      'all' => true,
      'unapproved-docs' => row['documents_ok'] != true,
      'permit-pending' => row['permit'] == 'pending',
      'permit-non-verified' => row['permit'] == 'non-verified',
      'permit-verified' => row['permit'] == 'verified',
      _ => row['status'] == filter,
    };

/// Case-insensitive search across the given columns.
bool rowSearch(Map<String, dynamic> row, String query, List<String> columns) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return columns.any((c) => '${row[c] ?? ''}'.toLowerCase().contains(q));
}

const userFilters = {
  'all': 'All',
  'approved': 'Approved',
  'unapproved': 'Unapproved',
  'unapproved-docs': 'ID failed',
  'blocked': 'Blocked',
  'rejected': 'Rejected',
  'deleted': 'Deleted',
};

const partnerFilters = {
  'all': 'All',
  'approved': 'Approved',
  'unapproved': 'Unapproved',
  'unapproved-docs': 'Docs incomplete',
  'permit-pending': 'Permit pending',
  'permit-non-verified': 'Permit not verified',
  'permit-verified': 'Permit verified',
  'blocked': 'Blocked',
  'rejected': 'Rejected',
};

const userStatusChoices = ['approved', 'unapproved', 'blocked', 'rejected', 'deleted'];
const partnerStatusChoices = ['approved', 'unapproved', 'unapproved-docs', 'blocked', 'rejected'];
const permitChoices = ['pending', 'non-verified', 'verified', 'none'];

/// Rides grouped the way the admin rides filter offers them.
const rideStatusGroups = {
  'all': <String>[],
  'open': ['open'],
  'active': ['accepted', 'arrived', 'on_trip'],
  'completed': ['completed'],
  'cancelled': ['cancelled', 'expired'],
};
