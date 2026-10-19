// Document and vehicle photos on their way to storage (PERF-67): scaled
// down off the UI thread, uploaded with a year's cache, and a small
// thumbnail stored beside each one for the lists (core/doc_photo.dart).
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/doc_photo.dart';
import '../platform/image_shrink.dart';

/// Turns a photo's bytes into other bytes off the UI thread; null keeps the
/// original (a PDF, or a photo that can't be read).
typedef ImageBytesJob = Future<Uint8List?> Function(Uint8List bytes);

/// [job] (a top-level function) on [bytes] in an isolate; in the browser,
/// which has none, the browser's own decoder and canvas do it first.
Future<Uint8List?> _offThread(
  Uint8List bytes,
  int maxSide,
  int quality,
  Uint8List? Function(Uint8List) job,
) async {
  if (looksLikePdf(bytes)) return null;
  if (kIsWeb) {
    final b = await browserShrinkImage(bytes, maxSide: maxSide, quality: quality);
    if (b != null) return b;
  }
  try {
    return await compute(job, bytes);
  } catch (_) {
    return null;
  }
}

/// A document photo at most [docPhotoMaxSide] px, JPEG [docPhotoQuality].
Future<Uint8List?> shrinkDocPhotoBytes(Uint8List bytes) =>
    _offThread(bytes, docPhotoMaxSide, docPhotoQuality, shrinkDocPhoto);

/// The [docThumbMaxSide] px list thumbnail of a photo.
Future<Uint8List?> docThumbnailBytes(Uint8List bytes) =>
    _offThread(bytes, docThumbMaxSide, docThumbQuality, docThumbnail);

/// Uploads [bytes] to [path] in [files] with a year's cache (every caller
/// names the file with its upload time, so the path is never reused), then,
/// for an image in one of the [docThumbBuckets], its thumbnail at
/// [docThumbPath] beside it. The thumbnail is best effort: without it the
/// lists show the file itself, as they do for older uploads.
Future<void> uploadStoredFile(
  StorageFileApi files,
  String path,
  Uint8List bytes, {
  required String contentType,
  ImageBytesJob? thumbnail,
}) async {
  await files.uploadBinary(
    path,
    bytes,
    fileOptions: FileOptions(upsert: true, contentType: contentType, cacheControl: docUploadCacheControl),
  );
  if (!docThumbBuckets.contains(files.bucketId) || !contentType.startsWith('image/')) return;
  try {
    final thumb = await (thumbnail ?? docThumbnailBytes)(bytes);
    if (thumb == null) return;
    await files.uploadBinary(
      docThumbPath(path),
      thumb,
      fileOptions: FileOptions(upsert: true, contentType: 'image/jpeg', cacheControl: docUploadCacheControl),
    );
  } catch (_) {}
}
