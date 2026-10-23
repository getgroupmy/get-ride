// Admin > Reports: the downloads. CSV (UTF-8 with a BOM), Excel (.xlsx: the
// table, then "What the AI understood") and PDF (the get.ride logo, the
// title, the period, the chart, the table and page numbers). The website
// downloads them; a phone hands them to its share sheet (Save to Files,
// email, WhatsApp), the PDF through the same share-or-download choice as
// the partner statements (pdf_actions.dart).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show Rect;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../../core/ai_report.dart';
import '../../../platform/web_download.dart';

export '../../../core/ai_report_xlsx.dart' show reportXlsx;

/// The PDF lists this many rows at most; the CSV and Excel files have them all.
const reportPdfMaxRows = 2000;

const csvMime = 'text/csv';
const xlsxMime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

Uint8List reportCsvBytes(ReportResult r) => Uint8List.fromList(utf8.encode(reportCsv(r)));

/// The standard PDF fonts cover Latin-1 only: anything else becomes "?".
String _latin1(String s) => s
    .replaceAll(RegExp('[–—]'), '-')
    .replaceAll(RegExp('[‘’]'), "'")
    .replaceAll(RegExp('[“”]'), '"')
    .replaceAll('·', '-')
    .replaceAll(RegExp(r'[^\x20-\x7e\xa0-\xff]'), '?');

/// The report as a PDF. [logo] is the app's icon (assets/branding/icon.png).
Future<Uint8List> buildReportPdf(
  ReportResult r, {
  required String title,
  required String period,
  required String madeAt,
  Uint8List? logo,
}) {
  final doc = pw.Document(title: _latin1(title), author: 'GET.ride', creator: 'GET.ride');
  const ink = PdfColor.fromInt(0xff17202b);
  const muted = PdfColor.fromInt(0xff5d6b7b);
  const bar = PdfColor.fromInt(0xff0c7ab8);
  const rule = PdfColor.fromInt(0xffd6dde5);
  final bars = r.chartBars();
  final top = bars == null ? 0.0 : bars.map((b) => b.value).reduce((a, b) => a > b ? a : b);
  final small = r.columns.length > 8;
  final cellStyle = pw.TextStyle(fontSize: small ? 7 : 8.5, color: ink);
  final headStyle = pw.TextStyle(fontSize: small ? 7 : 8.5, color: muted, fontWeight: pw.FontWeight.bold);
  final total = r.totalRow;
  final rows = r.rows.take(reportPdfMaxRows).toList();
  final note = r.rows.length > reportPdfMaxRows
      ? 'This PDF lists the first ${reportCellText(reportPdfMaxRows, 'number')} rows; the CSV and Excel files have them all.'
      : r.truncated
      ? 'Showing first ${reportCellText(r.maxRows, 'number')} rows.'
      : null;
  final align = {
    for (final (i, c) in r.columns.indexed) i: c.isNumber ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
  };

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      // 2,000 rows are about 50 pages.
      maxPages: 100,
      footer: (ctx) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('GET.ride', style: const pw.TextStyle(fontSize: 8, color: muted)),
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: muted)),
        ],
      ),
      build: (_) => [
        if (logo != null)
          pw.Image(pw.MemoryImage(logo), height: 32, alignment: pw.Alignment.centerLeft)
        else
          pw.Text('GET.ride', style: pw.TextStyle(fontSize: 16, color: bar, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 10),
        pw.Text(_latin1(title), style: pw.TextStyle(fontSize: 16, color: ink, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text(_latin1(period), style: const pw.TextStyle(fontSize: 10, color: muted)),
        pw.Text(
          'Made $madeAt (Malaysia time). ${reportCellText(r.rowCount, 'number')} rows.',
          style: const pw.TextStyle(fontSize: 9, color: muted),
        ),
        pw.SizedBox(height: 14),
        if (bars != null) ...[
          for (final b in bars)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 4),
              child: pw.Row(
                children: [
                  pw.SizedBox(width: 150, child: pw.Text(_latin1(b.label), style: cellStyle, maxLines: 1)),
                  pw.Expanded(
                    child: pw.LayoutBuilder(
                      builder: (_, box) => pw.Align(
                        alignment: pw.Alignment.centerLeft,
                        child: pw.Container(
                          height: 9,
                          width: top <= 0 ? 1 : ((box?.maxWidth ?? 300) * (b.value < 0 ? 0 : b.value) / top).clamp(1, box?.maxWidth ?? 300),
                          color: bar,
                        ),
                      ),
                    ),
                  ),
                  pw.SizedBox(
                    width: 70,
                    child: pw.Text(reportCellText(b.value, 'number'), style: cellStyle, textAlign: pw.TextAlign.right),
                  ),
                ],
              ),
            ),
          pw.SizedBox(height: 12),
        ],
        pw.TableHelper.fromTextArray(
          headers: [for (final c in r.columns) _latin1(c.label)],
          data: [
            for (final row in rows) [for (final (i, c) in r.columns.indexed) _latin1(reportCellText(i < row.length ? row[i] : null, c.type))],
            if (total != null) [for (final (i, c) in r.columns.indexed) _latin1(reportCellText(total[i], c.type))],
          ],
          headerStyle: headStyle,
          cellStyle: cellStyle,
          headerAlignments: align,
          cellAlignments: align,
          border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: rule, width: 0.5)),
          headerDecoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: rule))),
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 3),
        ),
        if (note != null) ...[pw.SizedBox(height: 8), pw.Text(note, style: const pw.TextStyle(fontSize: 9, color: muted))],
      ],
    ),
  );
  return doc.save();
}

/// The app's icon for the PDF's top; null where it can't be read.
Future<Uint8List?> reportLogo() async {
  try {
    return (await rootBundle.load('assets/branding/icon.png')).buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

enum ReportFileOutcome { shared, downloaded, failed }

/// Hands a file to the share sheet, or downloads it on the website. Overridden in tests.
final reportFileSaverProvider =
    Provider<Future<ReportFileOutcome> Function(Uint8List bytes, String fileName, String mimeType, Rect? origin)>(
  (ref) => (bytes, fileName, mimeType, origin) async {
    if (kIsWeb) {
      return webDownload(bytes, fileName: fileName, mimeType: mimeType) ? ReportFileOutcome.downloaded : ReportFileOutcome.failed;
    }
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: mimeType, name: fileName)],
          fileNameOverrides: [fileName],
          sharePositionOrigin: origin,
        ),
      );
      return ReportFileOutcome.shared;
    } catch (_) {
      return ReportFileOutcome.failed;
    }
  },
);
