// What the Drive tab tells a partner who cannot take jobs yet, by their
// account status (migration 0118): an application still being filled in,
// one with an admin, one the admin needs documents for, one rejected (with
// the admin's reason, and a way to send it back for review), or a blocked
// account (with the reason, and support). Pure.
import 'partner_onboarding.dart';

enum PartnerStatusKind { active, incomplete, underReview, docsNeeded, rejected, blocked }

class PartnerStatusView {
  const PartnerStatusView({
    required this.kind,
    required this.title,
    required this.message,
    this.reason,
    this.resubmittedAt,
  });

  final PartnerStatusKind kind;
  final String title;
  final String message;

  /// The admin's note on a rejection or block, when they left one.
  final String? reason;

  /// When the partner last sent a rejected application back for review.
  final DateTime? resubmittedAt;

  /// Only a rejected application can be sent back; only an admin approves.
  bool get canResubmit => kind == PartnerStatusKind.rejected;
  bool get canDrive => kind == PartnerStatusKind.active;
}

String? _text(Object? v) {
  final t = v is String ? v.trim() : '';
  return t.isEmpty ? null : t;
}

/// The view for a `partners` row.
PartnerStatusView partnerStatusView(Map<String, dynamic> partner) {
  final status = _text(partner['status']) ?? 'unapproved';
  final reason = _text(partner['status_note']);
  final resubmitted = DateTime.tryParse('${partner['resubmitted_at'] ?? ''}');
  if (status == 'approved' || status.startsWith('permit-')) {
    return const PartnerStatusView(kind: PartnerStatusKind.active, title: 'Active', message: '');
  }
  if (status == 'blocked') {
    return PartnerStatusView(
      kind: PartnerStatusKind.blocked,
      title: 'Account blocked',
      message:
          'Your partner account has been blocked, so you cannot take jobs. '
          'Contact support if you think this is a mistake.',
      reason: reason,
    );
  }
  if (status == 'rejected') {
    return PartnerStatusView(
      kind: PartnerStatusKind.rejected,
      title: 'Application not approved',
      message:
          'An admin could not approve your application. Fix what they pointed out, '
          'then send it back for review.',
      reason: reason,
    );
  }
  if (partnerSetupIncomplete(partner)) {
    return const PartnerStatusView(
      kind: PartnerStatusKind.incomplete,
      title: 'Finish your partner application',
      message: 'A few steps are still missing before an admin can review your account.',
    );
  }
  if (status == 'unapproved-docs') {
    return const PartnerStatusView(
      kind: PartnerStatusKind.docsNeeded,
      title: 'Documents needed',
      message:
          'An admin needs some of your documents updated before approving your account. '
          'Check your documents and upload any that are rejected or expired.',
    );
  }
  return PartnerStatusView(
    kind: PartnerStatusKind.underReview,
    title: 'Waiting for approval',
    message: resubmitted == null
        ? 'Your application is with an admin for review. You can take jobs here once your account is approved.'
        : 'You sent your application back for review. You can take jobs here once an admin approves it.',
    resubmittedAt: resubmitted,
  );
}

/// The admin's status choices that come with a reason for the partner.
bool statusTakesReason(String status) => status == 'rejected' || status == 'blocked';

/// The partner patch for an admin's status change: the reason goes with a
/// rejection or block and is cleared otherwise, so an approved partner never
/// sees an old reason.
Map<String, dynamic> partnerStatusPatch(String status, {String? reason}) => {
  'status': status,
  'status_note': statusTakesReason(status) ? _text(reason) : null,
};
