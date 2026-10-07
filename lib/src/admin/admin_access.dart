/// Admin access, resolved from the signed-in user's `admin_access` rows —
/// the same rows `public.caller_is_admin()` checks in every RLS policy, so
/// the UI can never offer more than the database will allow.
///
/// Page keys are the Expo route keys (`admin-users`, `admin-settings-promocode`,
/// …) so grants made in either app apply to both. `page = '*'` grants every
/// page. Unlike the Expo panel there is deliberately no local "super admin"
/// login: admin rights come from the database only.
library;

enum AccessLevel { none, read, edit }

class AdminGrant {
  const AdminGrant({required this.page, required this.edit, this.id, this.profileId, this.notes});

  factory AdminGrant.fromRow(Map<String, dynamic> r) => AdminGrant(
        id: r['id'] as String?,
        profileId: r['profile_id'] as String?,
        page: (r['page'] as String?) ?? '',
        edit: r['access_level'] == 'edit',
        notes: r['notes'] as String?,
      );

  final String? id;
  final String? profileId;
  final String page;
  final bool edit;
  final String? notes;
}

class AdminAccess {
  const AdminAccess(this.grants);
  static const none = AdminAccess([]);

  final List<AdminGrant> grants;

  bool get isAdmin => grants.isNotEmpty;
  bool get isFullAdmin => grants.any((g) => g.page == '*' && g.edit);

  /// Highest level granted on any of [pages] (a module spans several Expo
  /// pages, e.g. every `admin-users-*` list).
  AccessLevel levelFor(Iterable<String> pages) {
    var level = AccessLevel.none;
    for (final g in grants) {
      if (g.page == '*' || pages.contains(g.page)) {
        if (g.edit) return AccessLevel.edit;
        level = AccessLevel.read;
      }
    }
    return level;
  }

  bool canRead(Iterable<String> pages) => levelFor(pages) != AccessLevel.none;
  bool canEdit(Iterable<String> pages) => levelFor(pages) == AccessLevel.edit;
}

/// A section of the Flutter admin panel and the Expo pages it covers.
class AdminModule {
  const AdminModule(this.id, this.label, this.pages);
  final String id;
  final String label;
  final List<String> pages;
}

const _userLists = ['all', 'approved', 'blocked', 'deleted', 'rejected', 'unapproved', 'unapproved-docs'];
const _partnerLists = [
  'all', 'approved', 'blocked', 'rejected', 'unapproved', 'unapproved-docs',
  'permit-pending', 'permit-non-verified', 'permit-verified',
];

final adminModules = <String, AdminModule>{
  'dashboard': const AdminModule('dashboard', 'Dashboard', ['admin-dashboard']),
  'users': AdminModule('users', 'Users', [
    'admin-users', 'admin-user-edit', 'admin-user-add',
    for (final s in _userLists) 'admin-users-$s',
  ]),
  'partners': AdminModule('partners', 'Partners', [
    'admin-partners', 'admin-partner-edit', 'admin-partner-add',
    for (final s in _partnerLists) 'admin-partners-$s',
  ]),
  'vehicles': AdminModule('vehicles', 'Vehicles', [
    'admin-vehicles', 'admin-vehicle-edit', 'admin-vehicle-add',
    for (final s in _partnerLists) 'admin-vehicles-$s',
  ]),
  'documents': const AdminModule('documents', 'Documents', [
    'admin-documents', 'admin-documents-partners', 'admin-documents-users', 'admin-documents-vehicles',
  ]),
  'rides': const AdminModule('rides', 'Rides', ['admin-rides', 'admin-trace-fraud']),
  'support': const AdminModule('support', 'Support', ['admin-support', 'admin-support-pool', 'admin-support-chat']),
  'push': const AdminModule('push', 'Push notifications', ['admin-settings-push-notification']),
  'commission': const AdminModule('commission', 'Commission rates', ['admin-settings-commission']),
  'fare-tariffs': const AdminModule('fare-tariffs', 'Fare tariffs', ['admin-settings-fare-tariffs']),
  'settings': const AdminModule('settings', 'Settings', ['admin-settings']),
  'sub-admins': const AdminModule('sub-admins', 'Sub-admins', ['admin-settings-sub-admin']),
};
