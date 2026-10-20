// The customer's ticket for a stand order: shown on the console (and sent by
// SMS by the server when a phone was given). The trip code is what the
// driver asks for at pickup; the link is the shared-ride page.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/dispatch.dart';
import '../../core/ride_share.dart';
import '../../widgets/page_style_host.dart';

/// The ticket as plain text (copied, or read out to the customer).
String dispatchTicketText(DispatchOrder o) {
  final total = o.customerTotal;
  return [
    'GET.ride · ${o.standName}',
    'Ticket ${o.ticketNo}: ${o.routeLine}',
    if (o.pickupAt != null) 'Pickup: ${formatPickupAt(o.pickupAt!)}',
    [?o.service, o.fareText, o.payment.label].join(' · '),
    if (total != null && (o.feeAmount ?? 0) > 0 && o.feePayer == FeePayer.customer)
      'To pay: RM ${total.toStringAsFixed(2)} (fare and stand fee)',
    if (o.paidByLink)
      'Paid by card / e-wallet'
    else if (o.payLink && o.payUrl != null && !o.cancelled)
      'Pay by card / e-wallet: ${o.payUrl}',
    if (o.tripCode != null) 'Trip code: ${o.tripCode} (give it to the driver)',
    if (o.hasDriver || o.status == 'completed')
      ...o.driverLines
    else if (!o.cancelled)
      'Finding your driver… Please wait at the stand.',
    if (o.shareToken != null) 'Track: ${rideShareUrl(o.shareToken!)}',
  ].join('\n');
}

Future<void> showDispatchTicket(BuildContext context, DispatchOrder order) => showAppDialog<void>(
  id: 'dispatch.ticket',
  context: context,
  builder: (_) => DispatchTicketDialog(order: order),
);

class DispatchTicketDialog extends StatelessWidget {
  const DispatchTicketDialog({super.key, required this.order});
  final DispatchOrder order;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final o = order;
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final total = o.customerTotal;
    return AlertDialog(
      title: const Text("Customer's ticket"),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: t.colorScheme.outline),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(o.standName, style: muted),
                    Text(
                      o.ticketNo,
                      key: const ValueKey('ticket-no'),
                      style: t.textTheme.headlineSmall?.copyWith(fontFamily: 'monospace', fontWeight: FontWeight.w700),
                    ),
                    Text(o.bookedVia != null ? o.routeLine : 'to ${o.dropName}'),
                    if (o.pickupAt != null)
                      Text(
                        'Pickup: ${formatPickupAt(o.pickupAt!)}',
                        key: const ValueKey('ticket-pickup-at'),
                        style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    Text([?o.service, o.fareText, o.payment.label].join(' · '), style: muted),
                    if (total != null && (o.feeAmount ?? 0) > 0 && o.feePayer == FeePayer.customer)
                      Text('To pay: RM ${total.toStringAsFixed(2)} (fare and stand fee)'),
                    if (o.paidByLink)
                      Text('Paid by card / e-wallet', key: const ValueKey('ticket-paid'))
                    else if (o.payLink && o.payUrl != null && !o.cancelled) ...[
                      const SizedBox(height: 6),
                      Text('Pay by card / e-wallet', style: muted),
                      SelectableText(o.payUrl!, key: const ValueKey('ticket-pay-url')),
                    ],
                    if (o.tripCode != null) ...[
                      const SizedBox(height: 6),
                      Text('Trip code', style: muted),
                      Text(o.tripCode!, style: t.textTheme.titleLarge?.copyWith(letterSpacing: 4)),
                    ],
                    const SizedBox(height: 6),
                    if (o.hasDriver || o.status == 'completed')
                      for (final (i, line) in o.driverLines.indexed)
                        Text(
                          line,
                          key: ValueKey('ticket-driver-$i'),
                          style: i == 0 ? t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700) : null,
                        )
                    else if (!o.cancelled)
                      Text('Finding your driver… Please wait at the stand.', style: muted),
                    if (o.shareToken != null) Text('Track: ${rideShareUrl(o.shareToken!)}', style: muted),
                  ],
                ),
              ),
              if (o.events.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Action log', style: t.textTheme.titleSmall),
                for (final e in o.events)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${e.at == null ? '' : TimeOfDay.fromDateTime(e.at!.toLocal()).format(context)}  ${e.line}',
                      style: muted,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: dispatchTicketText(o)));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Ticket copied')));
          },
          child: const Text('Copy'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}
