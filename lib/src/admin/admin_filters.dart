/// Pure list filters for the admin people/vehicle screens, matching the
/// Expo `AdminUserList` / `AdminPartnerList` / `AdminVehicleList` rules.
library;

import 'profile_search.dart' show peopleSearchTerm;

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

/// Rows per page of the admin users list and the partner user picker
/// (PERF-55): the `profiles` table is read a page at a time, never whole.
const adminPeoplePageSize = 200;

/// The page on a phone: a user's row is some 113 tall with its Approve and
/// Reject, so 200 put "Load more" 22,000 px down.
const adminPeopleNarrowPageSize = 50;

/// The page size for a list [width] wide: smaller under 600.
int adminPeoplePageSizeFor(double width) => width < 600 ? adminPeopleNarrowPageSize : adminPeoplePageSize;

/// The count over a paged people list: what is loaded, and what of it the
/// filters or search kept. With more on the server and nothing filtered it
/// says how many of the newest are loaded (not "200 of the first 200", which
/// reads as a search result).
String pagedCountLabel({required int shown, required int loaded, required bool more, required bool filtered}) {
  if (!more) return '$shown of $loaded';
  if (!filtered) return 'Showing the newest $loaded';
  return '$shown ${shown == 1 ? 'match' : 'matches'} among the first $loaded loaded';
}

/// One page of rows, and whether more are on the server.
typedef RowsPage = ({List<Map<String, dynamic>> rows, bool more});

/// [rows] fetched with one row past [limit] (`range(0, limit)`) as a page:
/// that extra row only says there are more.
RowsPage rowsPage(List<Map<String, dynamic>> rows, int limit) =>
    rows.length > limit ? (rows: rows.sublist(0, limit), more: true) : (rows: rows, more: false);

/// The columns the users list searches, on the server and on the rows loaded.
const userSearchColumns = ['name', 'phone', 'deleted_phone', 'email', 'display_id', 'ic', 'app_version'];

/// A PostgREST `or` filter matching [query] anywhere in any of [columns]
/// (case-insensitive, as [rowSearch]), or null when there is nothing to
/// search on: the term is made safe the way the people search makes it
/// ([peopleSearchTerm]).
String? searchOrFilter(String query, List<String> columns) {
  final term = peopleSearchTerm(query);
  if (term == null || columns.isEmpty) return null;
  return columns.map((c) => '$c.ilike.*$term*').join(',');
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
  // Sent back to the driver from Review application (0289).
  'changes-needed': 'Changes needed',
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
      // A partner's Approve opens Review application (0296); a vehicle's
      // approves after its documents check.
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
