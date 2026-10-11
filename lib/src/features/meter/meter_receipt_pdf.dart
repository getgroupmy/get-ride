import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/meter_trip.dart';
import '../partner/driver_permit_screen.dart' show driverPermitProvider;

/// The meter receipt as a PDF, for the phone's own print service (Expo
/// `buildMeterReceiptHtml` + `expo-print`): what is printed when there is no
/// mini printer to hand, or the one set up can't be reached. Its lines come
/// from [meterReceiptLines], as the paper roll's and the screen's do, so the
/// three never disagree on a total.
Future<Uint8List> buildMeterReceiptPdf(
  MeterTrip trip, {
  PdfPageFormat format = PdfPageFormat.roll80,
  String title = 'GET TAXI METER',
  String? subtitle,
}) {
  final doc = pw.Document(title: '$title receipt', author: 'GET.ride');
  pw.Widget row(ReceiptLine l) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 2),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(l.label, style: pw.TextStyle(fontWeight: l.strong ? pw.FontWeight.bold : pw.FontWeight.normal)),
        pw.SizedBox(width: 8),
        pw.Expanded(
          child: pw.Text(
            l.value,
            textAlign: pw.TextAlign.right,
            style: pw.TextStyle(fontWeight: l.strong ? pw.FontWeight.bold : pw.FontWeight.normal),
          ),
        ),
      ],
    ),
  );
  doc.addPage(
    pw.Page(
      pageFormat: format,
      margin: const pw.EdgeInsets.all(12),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(
            title,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
          ),
          if (subtitle != null) pw.Text(subtitle, textAlign: pw.TextAlign.center),
          if (trip.plate != null) pw.Text('Vehicle ${trip.plate}', textAlign: pw.TextAlign.center),
          if (trip.driver != null) pw.Text('Driver ${trip.driver}', textAlign: pw.TextAlign.center),
          pw.Divider(),
          for (final l in meterReceiptLines(trip)) row(l),
          pw.Divider(),
          pw.Text(
            meterReceiptFooterNote(trip),
            textAlign: pw.TextAlign.center,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 4),
          pw.Text('Thank you for riding.', textAlign: pw.TextAlign.center),
        ],
      ),
    ),
  );
  return doc.save();
}

/// Sends a meter receipt to the phone's print service; answers whether it
/// was printed. A seam so tests don't open the platform dialog.
final meterSystemPrintProvider = Provider<Future<bool> Function(MeterTrip trip, {String? subtitle})>(
  (_) =>
      (trip, {subtitle}) => Printing.layoutPdf(
        name: 'GET TAXI METER receipt',
        onLayout: (format) => buildMeterReceiptPdf(trip, format: format, subtitle: subtitle),
      ),
);

/// The receipt's licence line, from the driver's permit ("Licence" and the number),
/// or null when the permit can't be read. A seam for tests.
final meterLicenceProvider = FutureProvider.autoDispose<String?>((ref) async {
  try {
    final permit = await ref.watch(driverPermitProvider.future);
    return meterReceiptSubtitle(permit.permitNumber);
  } catch (_) {
    return null;
  }
});
