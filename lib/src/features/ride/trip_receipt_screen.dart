import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/format.dart';
import '../../core/trip_receipt.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

final tripProvider = FutureProvider.autoDispose.family<RideRequest?, String>((ref, id) async {
  final repo = ref.watch(rideRepositoryProvider);
  final r = await repo.fetch(id);
  // A rider who wasn't on the live screen at drop-off still gets the ride
  // reward; the server pays it once per ride, so this is a no-op otherwise.
  if (r != null) unawaited(repo.claimRideReward(r));
  return r;
});

/// A finished trip's receipt (Expo `app/ride-detail.tsx`): route, times,
/// the other party, the fare lines, and print / share as a PDF or copy as
/// text. Opened from the trip list for both the rider's and the driver's copy.
class TripReceiptScreen extends ConsumerWidget {
  const TripReceiptScreen({super.key, required this.requestId});
  final String requestId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(currentUserIdProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Trip receipt')),
      body: AsyncView(
        value: ref.watch(tripProvider(requestId)),
        onRetry: () => ref.invalidate(tripProvider(requestId)),
        data: (r) {
          if (r == null) {
            return const EmptyState(icon: Icons.receipt_long_outlined, title: 'Trip not found');
          }
          final asDriver = r.partnerId == uid && r.riderId != uid;
          return _ReceiptBody(receipt: TripReceipt.fromRide(r, asDriver: asDriver));
        },
      ),
    );
  }
}

class _ReceiptBody extends StatelessWidget {
  const _ReceiptBody({required this.receipt});
  final TripReceipt receipt;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final rc = receipt;
    final ok = rc.status == RideStatus.completed;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ResponsiveCenter(
          maxWidth: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Icon(
                        ok ? Icons.check_circle : Icons.cancel_outlined,
                        size: 48,
                        color: ok ? Colors.green : t.colorScheme.error,
                      ),
                      const SizedBox(height: 8),
                      Text(rc.statusLabel, style: t.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        rc.charged ? formatMoney(rc.total, rc.currency) : 'No charge',
                        key: const ValueKey('receipt-total'),
                        style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(rc.bookingNo, style: t.textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.trip_origin, color: Colors.green.shade700),
                      title: Text(rc.pickup),
                      subtitle: rc.startedAt == null ? null : Text(formatTime(rc.startedAt)),
                    ),
                    ListTile(
                      leading: Icon(Icons.location_on, color: Colors.red.shade700),
                      title: Text(rc.drop),
                      subtitle: rc.endedAt == null ? null : Text(formatTime(rc.endedAt)),
                    ),
                  ],
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (k, v) in rc.details) _row(t, k, v),
                      if (rc.charged) ...[
                        const Divider(height: 24),
                        for (final l in rc.lines) _row(t, l.label, formatMoney(l.amount, rc.currency)),
                        const SizedBox(height: 4),
                        _row(t, 'Total', formatMoney(rc.total, rc.currency), bold: true),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('receipt-print'),
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('Print'),
                    onPressed: () => Printing.layoutPdf(
                      name: 'GET.ride ${rc.bookingNo}',
                      onLayout: (format) => buildTripReceiptPdf(rc, format: format),
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('receipt-share'),
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Share PDF'),
                    onPressed: () async =>
                        Printing.sharePdf(bytes: await buildTripReceiptPdf(rc), filename: '${rc.bookingNo}.pdf'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('receipt-copy'),
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: rc.text));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Receipt copied')));
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(ThemeData t, String k, String v, {bool bold = false}) {
    final style = bold ? t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800) : t.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(k, style: bold ? style : style?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(v, textAlign: TextAlign.end, style: style),
          ),
        ],
      ),
    );
  }
}

/// The receipt as an A4 (or [format]) PDF page. Text is kept to the base
/// font's character set, so the route is written "A to B".
Future<Uint8List> buildTripReceiptPdf(TripReceipt rc, {PdfPageFormat format = PdfPageFormat.a4}) {
  final doc = pw.Document(title: 'GET.ride receipt ${rc.bookingNo}', author: 'GET.ride');
  pw.Widget row(String k, String v, {bool bold = false}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 3),
    child: pw.Row(
      children: [
        pw.Expanded(
          child: pw.Text(k, style: pw.TextStyle(color: bold ? PdfColors.black : PdfColors.grey700)),
        ),
        pw.Text(v, style: pw.TextStyle(fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
      ],
    ),
  );
  doc.addPage(
    pw.Page(
      pageFormat: format,
      margin: const pw.EdgeInsets.all(40),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('GET.ride', style: pw.TextStyle(fontSize: 26, fontWeight: pw.FontWeight.bold)),
          pw.Text('Trip receipt', style: const pw.TextStyle(color: PdfColors.grey700)),
          pw.SizedBox(height: 20),
          pw.Text(
            rc.charged ? formatMoney(rc.total, rc.currency) : 'No charge',
            style: pw.TextStyle(fontSize: 30, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Text('${rc.pickup} to ${rc.drop}'),
          pw.Divider(height: 24),
          for (final (k, v) in rc.details) row(k, v),
          if (rc.charged) ...[
            pw.Divider(height: 24),
            for (final l in rc.lines) row(l.label, formatMoney(l.amount, rc.currency)),
            row('Total', formatMoney(rc.total, rc.currency), bold: true),
          ],
          pw.Spacer(),
          pw.Text(
            'This is a computer-generated receipt.',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
        ],
      ),
    ),
  );
  return doc.save();
}
