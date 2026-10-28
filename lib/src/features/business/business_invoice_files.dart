// A business invoice (migration 0313) as a PDF and a CSV: the get.ride logo,
// the company, the month, the due date, every trip and the totals. Saved
// the way the partner statements and Admin › Reports save theirs: the PDF
// through the share-or-download choice (pdf_actions.dart), the CSV through
// the share sheet, or a download on the website.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../admin/screens/reports/report_export.dart' show csvMime, reportFileSaverProvider, reportLogo, ReportFileOutcome;
import '../../core/business_accounts.dart';
import '../../data/business_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/pdf_actions.dart';

/// The standard PDF fonts cover Latin-1 only.
String _latin1(String s) => s
    .replaceAll(RegExp('[–—]'), '-')
    .replaceAll(RegExp('[‘’]'), "'")
    .replaceAll(RegExp('[“”]'), '"')
    .replaceAll('·', '-')
    .replaceAll(RegExp(r'[^\x20-\x7e\xa0-\xff]'), '?');

/// [f] as a PDF. [logo] is the app's icon; [today] dates the status.
Future<Uint8List> buildBusinessInvoicePdf(BusinessInvoiceFile f, {Uint8List? logo, DateTime? today}) {
  final i = f.invoice;
  final wallet = i.terms == BusinessTerms.wallet;
  final doc = pw.Document(title: _latin1('${wallet ? 'Statement' : 'Invoice'} ${i.invoiceNo}'), author: 'GET.ride', creator: 'GET.ride');
  const ink = PdfColor.fromInt(0xff17202b);
  const muted = PdfColor.fromInt(0xff5d6b7b);
  const rule = PdfColor.fromInt(0xffd6dde5);
  final small = pw.TextStyle(fontSize: 8, color: ink);
  final head = pw.TextStyle(fontSize: 8, color: muted, fontWeight: pw.FontWeight.bold);
  double sum(double Function(BusinessInvoiceLine) v) => f.lines.fold(0, (s, l) => s + v(l));
  pw.Widget kv(String k, String v) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 2),
    child: pw.Row(children: [
      pw.SizedBox(width: 90, child: pw.Text(_latin1(k), style: pw.TextStyle(fontSize: 9, color: muted))),
      pw.Expanded(child: pw.Text(_latin1(v), style: const pw.TextStyle(fontSize: 9, color: ink))),
    ]),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      maxPages: 100,
      footer: (ctx) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('GET.ride', style: const pw.TextStyle(fontSize: 8, color: muted)),
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: muted)),
        ],
      ),
      build: (ctx) => [
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          if (logo != null) pw.Image(pw.MemoryImage(logo), width: 40, height: 40),
          if (logo != null) pw.SizedBox(width: 12),
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(wallet ? 'Statement' : 'Invoice', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: ink)),
              pw.Text(_latin1(i.invoiceNo), style: const pw.TextStyle(fontSize: 11, color: muted)),
            ]),
          ),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text(businessMoneyCents(i.amount), style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: ink)),
            pw.Text(_latin1(i.statusLabel(today ?? DateTime.now())), style: const pw.TextStyle(fontSize: 10, color: muted)),
          ]),
        ]),
        pw.SizedBox(height: 16),
        kv('Billed to', f.companyName),
        if (f.regNo.isNotEmpty) kv('SSM no.', f.regNo),
        if (f.address.isNotEmpty) kv('Address', f.address),
        kv('Period', i.monthLabel),
        kv('Terms', i.terms.label),
        if (!wallet && i.dueDate != null) kv('Due', '${i.dueDate!.day} ${shortDate(i.dueDate!).split(' ').last} ${i.dueDate!.year}'),
        kv('Trips', '${f.lines.length}'),
        pw.SizedBox(height: 14),
        pw.TableHelper.fromTextArray(
          border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: rule, width: 0.5)),
          headerStyle: head,
          cellStyle: small,
          headerDecoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: rule))),
          columnWidths: {
            0: const pw.FixedColumnWidth(62),
            1: const pw.FlexColumnWidth(1.2),
            2: const pw.FlexColumnWidth(2.4),
            3: const pw.FlexColumnWidth(1.2),
            4: const pw.FixedColumnWidth(48),
            5: const pw.FixedColumnWidth(44),
            6: const pw.FixedColumnWidth(50),
          },
          cellAlignments: {4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight, 6: pw.Alignment.centerRight},
          headers: ['Date', 'Member', 'Trip', 'Note', 'Fare', 'Discount', 'Charged'],
          data: [
            for (final l in f.lines)
              [
                businessStamp(l.at),
                _latin1([l.member, if (l.team.isNotEmpty) l.team].join(' - ')),
                _latin1('${l.service}: ${l.pickup} to ${l.dropoff}${l.bookedFor.isEmpty ? '' : ' (for ${l.bookedFor})'}'),
                _latin1(l.note),
                l.gross.toStringAsFixed(2),
                l.discount.toStringAsFixed(2),
                l.charged.toStringAsFixed(2),
              ],
          ],
        ),
        pw.Divider(color: rule),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.SizedBox(
            width: 220,
            child: pw.Column(children: [
              kv('Fares', businessMoneyCents(sum((l) => l.gross))),
              kv('Business discount', '-${businessMoneyCents(sum((l) => l.discount))}'),
              kv(wallet ? 'Paid from the wallet' : 'Total due', businessMoneyCents(sum((l) => l.charged))),
            ]),
          ),
        ),
      ],
    ),
  );
  return doc.save();
}

/// The invoice's PDF, shared or downloaded.
Future<void> saveBusinessInvoicePdf(BuildContext context, WidgetRef ref, BusinessInvoice invoice) async {
  final repo = ref.read(businessRepositoryProvider);
  try {
    await sharePdfOrDownload(
      context,
      filename: 'get-ride-${invoice.invoiceNo}.pdf',
      title: 'Invoice ${invoice.invoiceNo}',
      build: () async => buildBusinessInvoicePdf(await repo.invoiceFile(invoice.id), logo: await reportLogo()),
    );
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// The invoice's trips as CSV, shared or downloaded.
Future<void> saveBusinessInvoiceCsv(BuildContext context, WidgetRef ref, BusinessInvoice invoice) async {
  try {
    final f = await ref.read(businessRepositoryProvider).invoiceFile(invoice.id);
    final bytes = Uint8List.fromList([0xef, 0xbb, 0xbf, ...utf8.encode(businessInvoiceCsv(f))]);
    final outcome = await ref.read(reportFileSaverProvider)(bytes, '${f.fileStem}.csv', csvMime, null);
    if (outcome == ReportFileOutcome.failed && context.mounted) showInfo(context, "The CSV couldn't be saved.");
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// "PDF" and "CSV" buttons for one invoice.
class BusinessInvoiceFileButtons extends ConsumerWidget {
  const BusinessInvoiceFileButtons({super.key, required this.invoice});
  final BusinessInvoice invoice;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Wrap(spacing: 4, children: [
    TextButton.icon(
      key: ValueKey('business-invoice-pdf-${invoice.id}'),
      onPressed: () => saveBusinessInvoicePdf(context, ref, invoice),
      icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
      label: const Text('PDF'),
    ),
    TextButton.icon(
      key: ValueKey('business-invoice-csv-${invoice.id}'),
      onPressed: () => saveBusinessInvoiceCsv(context, ref, invoice),
      icon: const Icon(Icons.table_view_outlined, size: 18),
      label: const Text('CSV'),
    ),
  ]);
}
