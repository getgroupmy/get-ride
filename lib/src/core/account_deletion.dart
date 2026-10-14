// Deleting your own account, and an admin linking a deleted account's
// history to the new one (migration 0194). Pure.
import 'package:flutter/foundation.dart';

/// What the app checks before asking to delete.
@immutable
class AccountDeletionCheck {
  const AccountDeletionCheck({this.activeRide = false, this.bookings = 0, this.retentionDays = 365});

  final bool activeRide;

  /// Upcoming scheduled rides that will be cancelled, free.
  final int bookings;

  /// How long the deleted account is kept before its personal data is wiped.
  final int retentionDays;

  factory AccountDeletionCheck.fromJson(Object? json) {
    if (json is! Map) return const AccountDeletionCheck();
    int n(String k, int d) => json[k] is num ? (json[k] as num).toInt() : d;
    return AccountDeletionCheck(
      activeRide: json['activeRide'] == true,
      bookings: n('bookings', 0),
      retentionDays: n('retentionDays', 365),
    );
  }
}

/// What happens, in the order the screen lists it.
List<String> accountDeletionEffects(AccountDeletionCheck c) => [
  if (c.bookings > 0)
    c.bookings == 1
        ? 'Your upcoming scheduled ride is cancelled, with no fee.'
        : 'Your ${c.bookings} upcoming scheduled rides are cancelled, with no fee.',
  'You are signed out on every device and can\'t sign in to this account again.',
  'Your GET.wallet, GET.credit and GET.coin balances are frozen. Use or settle them first.',
  'Your rides and receipts are kept on record, as the law requires.',
  'Your phone number is free: signing up with it again makes a new account. '
      'Support can move your old history to it if you ask.',
  'After ${c.retentionDays} days your personal details are wiped for good.',
];

/// The server's answer, as a sentence; null when it was deleted.
String? deleteAccountProblem(Object? result) {
  final error = result is Map ? result['error'] : 'unknown';
  if (result is Map && result['ok'] == true) return null;
  return switch (error) {
    'wrong_pin' => 'Incorrect PIN. Please try again.',
    'confirm_needed' => 'Confirm it\'s you with your PIN or an SMS code first.',
    'active_ride' => 'Finish your ride first. You can delete your account once it ends.',
    'already_deleted' => 'This account has already been deleted.',
    _ => 'Couldn\'t delete your account. Please try again.',
  };
}

/// What an admin can move from a deleted account to the new one.
enum AccountLinkCategory {
  trips('trips', 'Trips and receipts'),
  ratings('ratings', 'Ratings'),
  wallet('wallet', 'GET.wallet, GET.credit and GET.coin balances'),
  places('places', 'Saved places and favourite drivers'),
  referral('referral', 'Referral code and referrals'),
  partner('partner', 'Partner profile, documents and vehicles'),
  tickets('tickets', 'Support tickets');

  const AccountLinkCategory(this.key, this.label);
  final String key;
  final String label;

  static AccountLinkCategory? byKey(String key) {
    for (final c in values) {
      if (c.key == key) return c;
    }
    return null;
  }
}

/// A row of `account_events`, as the admin reads it.
@immutable
class AccountEvent {
  const AccountEvent(this.raw);
  final Map<String, dynamic> raw;

  String get kind => '${raw['kind'] ?? ''}';
  String? get otherProfileId => raw['other_profile_id'] as String?;
  DateTime? get at => DateTime.tryParse('${raw['created_at'] ?? ''}')?.toLocal();
  List<String> get categories => [for (final c in (raw['categories'] as List? ?? const [])) '$c'];

  /// "Deleted by the user", "Linked: Trips and receipts, Ratings", ….
  String get summary => switch (kind) {
    'deleted' => 'Deleted by the user',
    'linked' =>
      'Linked to a new account: ${categories.map((c) => AccountLinkCategory.byKey(c)?.label ?? c).join(', ')}',
    'final_deleted' => 'Personal data wiped (final deletion)',
    _ => kind,
  };
}

/// Parts of a deleted account already moved, which can't move again.
Set<String> linkedCategories(Iterable<AccountEvent> events) => {
  for (final e in events)
    if (e.kind == 'linked') ...e.categories,
};

/// When a deleted account becomes due for final deletion; null when it isn't deleted.
DateTime? finalDeletionDueAt(Map<String, dynamic> profile, int retentionDays) {
  final at = DateTime.tryParse('${profile['deleted_at'] ?? ''}');
  return at?.toLocal().add(Duration(days: retentionDays));
}

/// Whether an admin may approve the final deletion now.
bool dueForFinalDeletion(Map<String, dynamic> profile, int retentionDays, DateTime now) {
  if (profile['final_deleted_at'] != null) return false;
  final due = finalDeletionDueAt(profile, retentionDays);
  return due != null && !due.isAfter(now);
}

/// A refusal from the server: its hint when it gave one (the sentence),
/// else its message.
String serverRefusalText(String message, String? hint) =>
    hint != null && hint.trim().isNotEmpty ? hint.trim() : message;
