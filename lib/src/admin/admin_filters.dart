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
      // No version recorded: hasn't opened the app on 1.4.6 or later (0176).
      'old-app' => '${row['app_version'] ?? ''}'.trim().isEmpty,
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
  'final-delete': 'Due for final deletion',
  'old-app': 'App before 1.4.6',
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

/// A one-tap status change on a list card (Expo `AdminUserList`
/// `primaryActions`). [destructive] ones are confirmed first.
class QuickStatusAction {
  const QuickStatusAction(this.label, this.next, {this.destructive = false});
  final String label;
  final String next;
  final bool destructive;

  @override
  bool operator ==(Object other) =>
      other is QuickStatusAction && other.label == label && other.next == next && other.destructive == destructive;

  @override
  int get hashCode => Object.hash(label, next, destructive);
}

/// The quick actions a user, partner or vehicle card offers in [status]:
/// waiting → Approve / Reject, approved → Block, blocked → Unblock,
/// rejected → Re-open; none for anything else (deleted).
List<QuickStatusAction> quickStatusActions(String? status) => switch (status) {
      'unapproved' || 'unapproved-docs' => const [
          QuickStatusAction('Approve', 'approved'),
          QuickStatusAction('Reject', 'rejected', destructive: true),
        ],
      'approved' => const [QuickStatusAction('Block', 'blocked', destructive: true)],
      'blocked' => const [QuickStatusAction('Unblock', 'approved')],
      'rejected' => const [QuickStatusAction('Re-open', 'unapproved')],
      _ => const [],
    };

/// The `tel:` link for a stored phone number, keeping only `+` and digits;
/// null when there is no number to call.
Uri? phoneCallUri(Object? phone) {
  final cleaned = '${phone ?? ''}'.replaceAll(RegExp(r'[^+\d]'), '');
  if (cleaned.replaceAll('+', '').length < 3) return null;
  return Uri(scheme: 'tel', path: cleaned);
}

/// Rides grouped the way the admin rides filter offers them.
const rideStatusGroups = {
  'all': <String>[],
  'open': ['open'],
  'active': ['accepted', 'arrived', 'on_trip'],
  'completed': ['completed'],
  'cancelled': ['cancelled', 'expired'],
};
