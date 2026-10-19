/// Document and vehicle photos as they are stored (PERF-67): scaled down to
/// [docPhotoMaxSide] on the long side as a JPEG before upload, with a small
/// [docThumbMaxSide] JPEG beside each one at `<path>.thumb.jpg` for the
/// lists, and a year's cache on both (every upload goes to a new path).
/// Pure Dart (the `image` package): callers run it in `compute`.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'storage_links.dart';

/// The long side a stored document photo is scaled down to: a licence or a
/// permit stays legible, and the file is a few hundred KB, not 5 MB.
const docPhotoMaxSide = 1600;
const docPhotoQuality = 80;

/// The long side of the list thumbnail stored next to each photo.
const docThumbMaxSide = 320;
const docThumbQuality = 70;

/// `Cache-Control: max-age` for an upload whose path is never reused (each
/// upload is named with its millisecond time), so a cached copy is never
/// stale: one year.
const docUploadCacheControl = '31536000';

/// The buckets whose image uploads get a thumbnail.
const docThumbBuckets = {'provider-documents', 'vehicle-documents', 'ID_Image'};

const _thumbSuffix = '.thumb.jpg';

/// Where the thumbnail of the file at [path] is stored.
String docThumbPath(String path) => '$path$_thumbSuffix';

bool isDocThumbPath(String path) => path.endsWith(_thumbSuffix);

/// Whether [bytes] are a PDF (`%PDF`), which is stored as it is.
bool looksLikePdf(Uint8List bytes) =>
    bytes.length >= 4 && bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46;

/// [width] x [height] scaled down so neither side is over [maxSide]; never
/// scaled up, never below 1 px.
({int width, int height}) fitWithin(int width, int height, int maxSide) {
  final long = width > height ? width : height;
  if (long <= maxSide || long <= 0) return (width: width, height: height);
  final s = maxSide / long;
  int side(int v) {
    final r = (v * s).round();
    return r < 1 ? 1 : r;
  }

  return (width: side(width), height: side(height));
}

/// The photo as a JPEG at most [maxSide] px on its long side, upright (a
/// phone camera stores the pixels sideways and says so in EXIF; the JPEG
/// written here has the pixels turned and no orientation tag), with any
/// transparency on white. Null for a PDF or anything that can't be read,
/// which the caller keeps as it is.
Uint8List? reencodeJpeg(Uint8List bytes, {required int maxSide, required int quality}) {
  if (looksLikePdf(bytes)) return null;
  img.Image? image;
  try {
    image = img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
  if (image == null || image.width <= 0 || image.height <= 0) return null;
  image = img.bakeOrientation(image);
  final size = fitWithin(image.width, image.height, maxSide);
  if (size.width != image.width || size.height != image.height) {
    image = img.copyResize(image,
        width: size.width, height: size.height, interpolation: img.Interpolation.average);
  }
  if (image.hasAlpha || image.hasPalette || image.format != img.Format.uint8) {
    final flat = img.Image(width: image.width, height: image.height);
    img.fill(flat, color: img.ColorRgb8(255, 255, 255));
    image = img.compositeImage(flat, image);
  }
  image.exif = img.ExifData();
  return img.encodeJpg(image, quality: quality);
}

/// A document photo ready to upload, or null to keep the original.
Uint8List? shrinkDocPhoto(Uint8List bytes) => reencodeJpeg(bytes, maxSide: docPhotoMaxSide, quality: docPhotoQuality);

/// The list thumbnail of a photo, or null when it isn't one.
Uint8List? docThumbnail(Uint8List bytes) => reencodeJpeg(bytes, maxSide: docThumbMaxSide, quality: docThumbQuality);

/// [name] with a `.jpg` extension (`licence.png` → `licence.jpg`).
String jpgName(String name) {
  final base = name.replaceFirst(RegExp(r'\.[A-Za-z0-9]+$'), '');
  return '${base.isEmpty ? 'photo' : base}.jpg';
}

/// The stored link of the thumbnail beside the image at [url], or null when
/// it has none: not in a [docThumbBuckets] bucket, a PDF, or already a
/// thumbnail. Old uploads have no thumbnail either; the reader falls back to
/// [url] when this one can't be had.
String? docThumbUrl(String? url) {
  final ref = privateStorageRef(url);
  if (ref == null || !docThumbBuckets.contains(ref.bucket)) return null;
  final path = ref.path.toLowerCase();
  if (path.endsWith('.pdf') || isDocThumbPath(path)) return null;
  final u = url!.trim();
  final cut = u.indexOf(RegExp(r'[?#]'));
  return cut < 0 ? docThumbPath(u) : '${docThumbPath(u.substring(0, cut))}${u.substring(cut)}';
}
