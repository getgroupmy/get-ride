/// PDF documents (Expo `DocumentUploadModal`'s "Upload PDF"): where the admin
/// allows it on a required document (`allowPdfUpload`), a partner can pick a
/// PDF instead of photographing the document. Its first page is rasterized
/// to a PNG and that image is what is uploaded and AI-checked — the raw PDF
/// is never stored, so every document stays an image an admin can view.
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import 'people_data.dart';

/// Largest PDF accepted, in bytes.
const docPdfMaxBytes = 15 * 1024 * 1024;

bool isPdfName(String name) => name.toLowerCase().split('?').first.endsWith('.pdf');

/// The stored name of a PDF's first-page image: `licence.pdf` → `licence.png`.
String pdfPreviewName(String name) {
  final base = name.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');
  return '${base.isEmpty ? 'document' : base}.png';
}

/// Why a picked PDF can't be used, or null.
String? docPdfProblem(String name, int bytes) {
  if (!isPdfName(name)) return 'Choose a PDF file.';
  if (bytes <= 0) return "That PDF couldn't be read.";
  if (bytes > docPdfMaxBytes) return 'Choose a PDF under 15 MB.';
  return null;
}

/// Picking and rasterizing, behind a seam so tests run without plugins.
class DocPdfTools {
  const DocPdfTools();

  Future<PickedPeopleFile?> pick() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf']);
    final f = files.firstOrNull;
    if (f == null) return null;
    return (bytes: await f.readAsBytes(), name: f.name);
  }

  /// The first page as PNG bytes, or null when the PDF can't be rendered.
  Future<Uint8List?> firstPagePng(Uint8List pdf) async {
    try {
      await for (final page in Printing.raster(pdf, pages: const [0], dpi: 150)) {
        return await page.toPng();
      }
    } catch (_) {}
    return null;
  }
}

final docPdfToolsProvider = Provider<DocPdfTools>((_) => const DocPdfTools());
