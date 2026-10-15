// The PDF button's choice: share the PDF (the phone's share sheet: WhatsApp,
// email, Files…) or download it (saved where the person picks; a download
// on the web).
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'common.dart';

enum PdfAction { share, download }

/// Asks whether to share or download; null when dismissed.
Future<PdfAction?> askPdfAction(BuildContext context, {required String title}) => showModalBottomSheet<PdfAction>(
  context: context,
  showDragHandle: true,
  builder: (c) => SafeArea(
    child: Column(
      key: const ValueKey('pdf-actions'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(title, style: Theme.of(c).textTheme.titleMedium),
        ),
        ListTile(
          key: const ValueKey('pdf-share'),
          leading: const Icon(Icons.ios_share),
          title: const Text('Share'),
          subtitle: const Text('Send it by WhatsApp, email or another app'),
          onTap: () => Navigator.pop(c, PdfAction.share),
        ),
        ListTile(
          key: const ValueKey('pdf-download'),
          leading: const Icon(Icons.download_outlined),
          title: const Text('Download'),
          subtitle: const Text('Save it to this device'),
          onTap: () => Navigator.pop(c, PdfAction.download),
        ),
        const SizedBox(height: 8),
      ],
    ),
  ),
);

/// The PDF button: builds the PDF only once the person has chosen, then
/// shares or saves it. Saving falls back to sharing where the platform
/// can't save a file.
Future<void> sharePdfOrDownload(
  BuildContext context, {
  required String filename,
  required String title,
  required Future<Uint8List> Function() build,
}) async {
  final action = await askPdfAction(context, title: title);
  if (action == null || !context.mounted) return;
  final bytes = await build();
  switch (action) {
    case PdfAction.share:
      await Printing.sharePdf(bytes: bytes, filename: filename);
    case PdfAction.download:
      try {
        final saved = await FilePicker.saveFile(
          fileName: filename,
          bytes: bytes,
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
        );
        if (saved != null && context.mounted) showInfo(context, 'Saved $filename');
      } catch (_) {
        await Printing.sharePdf(bytes: bytes, filename: filename);
      }
  }
}
