// The public "Delete your GET.ride account" page (getride.my/delete-account,
// migration 0334): what it says, and the server's answers. Pure.
//
// What the page says is deleted, kept and for how long follows what the
// server does (0194 and 0334): the retention and grace days come from the
// server (account_deletion_public_info). Where the code sets no period, the
// text below holds a placeholder the owner fills in ([ownerFill]).
import 'package:flutter/foundation.dart';

/// Marks text the owner has to write before the page goes to Google Play.
const ownerFill = 'to be filled in by GET.ride';

/// Who makes GET.ride: the company's registered name (and number).
const deletionPageDeveloper = 'PUNCAK NIAGA BERSAMA SDN. BHD. (202201025129 (1470826-D))';

/// How long anonymised trip, payment and wallet records are kept. The code
/// keeps them with no end date (0194: "financial records stay, anonymised").
const deletionPageFinancialPeriod = 'kept with no end date, without your name and phone number';

/// How long support conversations and call records are kept. No end date in the code.
const deletionPageSupportPeriod = 'kept with no end date';

/// How long backups hold a deleted account's data. The office backup keeps
/// nightly copies and monthly copies for an admin-set number of months (0318).
const deletionPageBackupPeriod = 'kept with no end date';

/// Where people write with questions (as on the privacy page).
const deletionPageContact = 'support@getride.my';

/// The page's public address.
const deletionPageUrl = 'https://getride.my/delete-account';

/// The app's own Delete account page on the web (0194), for someone already
/// signed in on this browser: getride.my/account/settings/delete.
const deletionPageInAppPath = '/account/settings/delete';

/// The owner's retention rule (kept as 0194 sets it), in plain words: the
/// account is closed and hidden at once, what is kept for [AccountDeletionInfo.retentionDays]
/// and why, then wiped. The same words go in the privacy policy.
List<String> deletionRetentionStatement(AccountDeletionInfo i) => [
  'When your account is deleted, it is closed and hidden at once: you are signed out on every device, '
      'nobody can sign in to it or find it by your phone number, open ride requests and upcoming bookings '
      'are cancelled, and your number is free to use for a new account.',
  'We then keep the closed account for ${dayCount(i.retentionDays)}. During that time we keep your trips, '
      'receipts and payments, your GET.wallet, GET.credit and GET.coin records, safety reports and support '
      'conversations, with the personal details that go with them.',
  'We keep them because the law requires us to keep tax and financial records, because we must be able to '
      'look into safety reports and fraud, and so we can settle disputes about trips and payments.',
  'After ${dayCount(i.retentionDays)} your personal details are wiped for good. Trip and payment records '
      'are then kept only without your name and phone number.',
];

/// Every placeholder on the page, for the owner's checklist.
const deletionPagePlaceholders = <String>[];

/// The server's numbers for the page.
@immutable
class AccountDeletionInfo {
  const AccountDeletionInfo({this.retentionDays = 365, this.graceDays = 7, this.codeMinutes = 10});

  /// Days a deleted account is kept, frozen, before its personal details
  /// are wiped (0194, admin-set).
  final int retentionDays;

  /// Days a request by phone waits before the account is deleted (0334, admin-set).
  final int graceDays;

  /// How long a texted code works.
  final int codeMinutes;

  factory AccountDeletionInfo.fromJson(Object? json) {
    if (json is! Map) return const AccountDeletionInfo();
    int n(String k, int d) => json[k] is num ? (json[k] as num).toInt() : d;
    return AccountDeletionInfo(
      retentionDays: n('retentionDays', 365),
      graceDays: n('graceDays', 7),
      codeMinutes: n('codeMinutes', 10),
    );
  }
}

String dayCount(int n) => n == 1 ? '1 day' : '$n days';

/// A titled list on the page.
@immutable
class DeletionPageSection {
  const DeletionPageSection(this.title, this.lines, {this.intro});
  final String title;
  final String? intro;
  final List<String> lines;
}

/// The steps for "Sign in and delete".
const signInDeleteSteps = [
  'Enter your mobile number and tap Text me a code.',
  'Enter the 6-digit code we text you. This signs you in.',
  'Read what happens, then tap Delete my account. It is deleted straight away.',
];

/// The steps for "Request by phone".
List<String> phoneRequestSteps(AccountDeletionInfo i) => [
  'Enter the mobile number of your account and tap Text me a code.',
  'Enter the 6-digit code we text you (it works for ${i.codeMinutes} minutes).',
  i.graceDays == 0
      ? 'Your account is deleted straight away.'
      : 'We sign you out on every device and delete your account after ${dayCount(i.graceDays)}. '
            'To change your mind, just sign in to GET.ride again before then.',
];

/// What is deleted, what is kept and why, and for how long: what 0194 and
/// 0334 do, in plain words.
List<DeletionPageSection> deletionPageSections(AccountDeletionInfo i) => [
  const DeletionPageSection('What is deleted straight away', [
    'You are signed out on every device and can\'t sign in to this account again.',
    'Your phone number is released. Signing up with it again makes a new account.',
    'A ride request still looking for a driver, and your upcoming scheduled rides, are cancelled with no fee.',
    'Drivers: you are taken off the map, your partner profile is closed, and bookings you took go to another driver.',
    'The notification tokens of your devices are removed.',
  ], intro: 'When your account is deleted:'),
  DeletionPageSection(
    'What is wiped after ${dayCount(i.retentionDays)}',
    const [
      'Your name, email, ID number, address, date of birth, gender and nationality.',
      'Your profile photo, ID photos and PIN.',
      'Partner documents (licence, permits, insurance, vehicle papers) and their files.',
      'Emergency contacts, saved places, favourite drivers, personal QR codes and notifications.',
      'Your location history and Voice Protection recordings.',
      'Your name and number on past trips and safety reports. They then read "Deleted user".',
    ],
    intro:
        'Until then the deleted account is kept, frozen, so we can answer disputes and, if you ask, '
        'move your history to a new account. After ${dayCount(i.retentionDays)} our team wipes:',
  ),
  DeletionPageSection('What we keep and why', const [
    'Trips and receipts (times, places, fares) and payments: tax and financial record-keeping law requires them. '
        'Your name and number are removed.',
    'The GET.wallet, GET.credit and GET.coin ledger, and any amount a partner still owes: the same reason. '
        'Balances are frozen when you delete, so use or settle them first.',
    'Ratings and support conversations, without your name: to settle disputes and keep riders and drivers safe.',
    'A record that the account was deleted, and when: to show we did what you asked.',
  ]),
  DeletionPageSection('How long', [
    'A request by phone: ${i.graceDays == 0 ? 'no waiting' : '${dayCount(i.graceDays)} to change your mind'}.',
    'The deleted account, frozen: ${dayCount(i.retentionDays)}, then personal details are wiped.',
    'Location history: at most 90 days, deleted or not.',
    'Notifications: at most 90 days.',
    'Anonymised trips, payments and the wallet ledger: $deletionPageFinancialPeriod.',
    'Support conversations and call records: $deletionPageSupportPeriod.',
    'Backup copies: $deletionPageBackupPeriod. They are not used to bring the account back.',
  ]),
];

/// The confirm's answer, as a sentence; null when the request was taken.
String? deletionRequestProblem(Object? result) {
  if (result is Map && result['ok'] == true) return null;
  return switch (result is Map ? result['error'] : null) {
    'wrong_code' => 'That code is wrong or has expired. Check it, or ask for a new one.',
    _ => 'Couldn\'t send your request. Please try again.',
  };
}

/// When a request by phone deletes the account, from the confirm's answer.
DateTime? deletionRequestDeleteAfter(Object? result) =>
    result is Map ? DateTime.tryParse('${result['deleteAfter'] ?? ''}')?.toLocal() : null;

/// What the page says once a code is sent. Never whether the number has an account.
String deletionCodeSentText(String phone) =>
    'If $phone has a GET.ride account, we have texted it a 6-digit code. No text after a minute? '
    'Check the number, or ask for a new code.';

/// A request as the admin reads it (admin_account_deletion_requests).
@immutable
class AccountDeletionRequest {
  const AccountDeletionRequest(this.raw);
  final Map<String, dynamic> raw;

  String get id => '${raw['id'] ?? ''}';
  String get userId => '${raw['user_id'] ?? ''}';
  String get status => '${raw['status'] ?? ''}';
  String get method => '${raw['method'] ?? ''}';
  String? get reason => (raw['reason'] as String?)?.trim().isEmpty == true ? null : raw['reason'] as String?;
  String? get lastError => raw['last_error'] as String?;
  DateTime? _at(String k) => DateTime.tryParse('${raw[k] ?? ''}')?.toLocal();
  DateTime? get createdAt => _at('created_at');
  DateTime? get graceUntil => _at('grace_until');
  DateTime? get deletedAt => _at('deleted_at');
  DateTime? get cancelledAt => _at('cancelled_at');

  bool get open => status == 'in_grace';

  /// "Requested", "In grace", "Deleted", "Cancelled", "Not confirmed".
  String get statusLabel => deletionRequestStatusLabel(status);

  /// "Web, by phone code" or "Web, signed in".
  String get methodLabel => method == 'sign_in' ? 'Web, signed in' : 'Web, by phone code';

  /// Why it was cancelled, in words.
  String? get cancelLabel => switch (raw['cancel_reason']) {
    'signed_in' => 'The user signed in',
    'admin' => 'Cancelled by an admin',
    _ => null,
  };
}

String deletionRequestStatusLabel(String status) => switch (status) {
  'requested' => 'Requested',
  'in_grace' => 'In grace',
  'deleted' => 'Deleted',
  'cancelled' => 'Cancelled',
  'expired' => 'Not confirmed',
  _ => status,
};

/// The accounts with a request in grace, for the Users list's filter.
Set<String> deletionRequestedIds(Iterable<AccountDeletionRequest> requests) => {
  for (final r in requests)
    if (r.open) r.userId,
};
