// Booking on a business account (migration 0313): the "Business: <company>"
// payment offered where the member may book that kind of trip, and the
// server's check before the booking goes out: a trip note when the company
// asks for one, an Admin's approval for a trip above its amount (asked from
// here), or the reason it can't be booked. The database checks the booking
// again as it is written.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_accounts.dart';
import '../../core/payment_types.dart';
import '../../data/business_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';

/// The admin's payment methods, then the member's business accounts that
/// may book [kind].
List<PaymentChoice> withBusinessPayments(List<PaymentChoice> admin, List<BusinessMembership> accounts, BusinessService kind) =>
    [...admin, ...businessPaymentChoices(accounts, kind)];

/// What [payment] stores as the ride's payment_mode: "Business: (company)"
/// for a business account, else itself.
String bookedPaymentMode(String payment, List<PaymentChoice> choices) {
  if (businessAccountIdOf(payment) == null) return payment;
  for (final c in choices) {
    if (c.value == payment) return c.label;
  }
  return 'Business';
}

/// Asks for the trip note (the project or the reason); null when cancelled.
Future<String?> askBusinessNote(BuildContext context, {required String company}) async {
  final text = TextEditingController();
  final note = await showAppDialog<String>(
    id: 'business.trip-note',
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Trip note'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$company asks for the project or the reason for each trip.'),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('business-note-field'),
          controller: text,
          autofocus: true,
          maxLength: 200,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Project or reason', border: OutlineInputBorder()),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('business-note-ok'),
          onPressed: () => text.text.trim().isEmpty ? null : Navigator.pop(c, text.text.trim()),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  text.dispose();
  return note;
}

/// Whether to ask the company's Admins to approve the trip.
Future<bool> askBusinessApproval(BuildContext context, {required String message, required String fare}) async =>
    await showAppDialog<bool>(
      id: 'business.ask-approval',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Approval needed'),
        content: Text('$message Ask your company\'s Admins to approve this $fare trip? You\'ll be told when they answer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          FilledButton(
            key: const ValueKey('business-ask-approval'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Ask for approval'),
          ),
        ],
      ),
    ) ==
    true;

/// The business booking's checks before it goes out. Null: not booked (the
/// reason was shown, or an approval asked for); else the note to book with.
Future<({String? note})?> prepareBusinessBooking(
  BuildContext context,
  WidgetRef ref, {
  required String accountId,
  required String company,
  required String service,
  required double fare,
  DateTime? pickupAt,
  bool forOther = false,
  String? payer,
  String? pickup,
  String? dropoff,
}) async {
  final repo = ref.read(businessRepositoryProvider);
  String? note;
  for (var round = 0; round < 3; round++) {
    final BusinessCheck c;
    try {
      c = await repo.check(
        accountId: accountId,
        service: service,
        fare: fare,
        pickupAt: pickupAt,
        note: note,
        forOther: forOther,
        payer: payer,
      );
    } catch (e) {
      if (context.mounted) showError(context, e);
      return null;
    }
    if (!context.mounted) return null;
    if (c.ok) return (note: note);
    if (c.needsNote && note == null) {
      note = await askBusinessNote(context, company: company);
      if (note == null || !context.mounted) return null;
      continue;
    }
    if (c.needsApproval) {
      if (c.approvalPending) {
        showInfo(context, 'Your approval request is waiting for an Admin of $company. Book again once it is approved.');
        return null;
      }
      final ask = await askBusinessApproval(context, message: c.message ?? '', fare: businessMoney(fare));
      if (!ask || !context.mounted) return null;
      try {
        await repo.askApproval(
          accountId: accountId,
          amount: fare,
          service: service,
          pickup: pickup,
          dropoff: dropoff,
          note: note,
        );
        if (context.mounted) {
          showInfo(context, "Sent to $company's Admins. You'll be told when they answer; then book again.");
        }
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
      return null;
    }
    showInfo(context, c.message ?? "This trip can't be booked on $company's account.");
    return null;
  }
  return null;
}
