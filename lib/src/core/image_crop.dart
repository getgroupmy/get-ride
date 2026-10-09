/// Cropping photos before they are uploaded: the driver's portrait cut out
/// of a taxi permit (Expo `cropImageRegionToFile`) and the square profile
/// photo (Expo's 1:1 avatar crop). Pure Dart (the `image` package), so it
/// runs the same on every platform and in tests; callers run the decode in
/// `compute` so a large photo does not stall a frame.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A region of an image as fractions (0..1) of its size; [x], [y] is the
/// top-left corner.
class FractionBox {
  const FractionBox({required this.x, required this.y, required this.width, required this.height});

  final double x, y, width, height;

  /// The AI's `photoBox` (Expo `normBox`): each value clamped to 0..1, and
  /// null unless all four are numbers and the size is positive.
  static FractionBox? parse(Object? v) {
    if (v is! Map) return null;
    double? n(Object? k) {
      final d = k is num ? k.toDouble() : (k is String ? double.tryParse(k.trim()) : null);
      if (d == null || !d.isFinite) return null;
      return d.clamp(0.0, 1.0);
    }

    final x = n(v['x']), y = n(v['y']), w = n(v['width']), h = n(v['height']);
    if (x == null || y == null || w == null || h == null || w <= 0 || h <= 0) return null;
    return FractionBox(x: x, y: y, width: w, height: h);
  }

  @override
  bool operator ==(Object other) =>
      other is FractionBox && other.x == x && other.y == y && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'FractionBox($x, $y, $width, $height)';
}

/// A rectangle in pixels.
typedef PixelRect = ({int x, int y, int width, int height});

/// The pixels to cut for [box] on an image of [imageWidth] × [imageHeight]:
/// the box grown by [pad] of its size on every side (a portrait box drawn
/// tight to the face would clip the hair and chin), kept inside the image.
/// Null when the image is empty or the result is a sliver (≤ 1 px).
PixelRect? paddedCropRect(FractionBox box, int imageWidth, int imageHeight, {double pad = 0.12}) {
  if (imageWidth <= 0 || imageHeight <= 0) return null;
  final padX = box.width * pad, padY = box.height * pad;
  final fx = (box.x - padX).clamp(0.0, 1.0);
  final fy = (box.y - padY).clamp(0.0, 1.0);
  final fw = (box.width + padX * 2).clamp(0.0, 1 - fx);
  final fh = (box.height + padY * 2).clamp(0.0, 1 - fy);
  final x = (fx * imageWidth).round(), y = (fy * imageHeight).round();
  final w = (fw * imageWidth).round().clamp(0, imageWidth - x);
  final h = (fh * imageHeight).round().clamp(0, imageHeight - y);
  if (w <= 1 || h <= 1) return null;
  return (x: x, y: y, width: w, height: h);
}

/// The largest centred square of a [width] × [height] image, or null when
/// it is empty.
PixelRect? squareCropRect(int width, int height) {
  if (width <= 0 || height <= 0) return null;
  final side = width < height ? width : height;
  return (x: (width - side) ~/ 2, y: (height - side) ~/ 2, width: side, height: side);
}

/// Decodes a photo upright: a phone camera stores the pixels sideways and
/// says so in EXIF, and the boxes and squares here are of the photo as seen.
img.Image? _decodeUpright(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    return decoded == null ? null : img.bakeOrientation(decoded);
  } catch (_) {
    return null;
  }
}

/// [box] cut out of the photo as a JPEG, or null when the photo can't be
/// read or the box is too small to be a portrait.
Uint8List? cropImageRegion(Uint8List bytes, FractionBox box, {double pad = 0.12}) {
  final image = _decodeUpright(bytes);
  if (image == null) return null;
  final r = paddedCropRect(box, image.width, image.height, pad: pad);
  if (r == null) return null;
  final out = img.copyCrop(image, x: r.x, y: r.y, width: r.width, height: r.height);
  return img.encodeJpg(out, quality: 85);
}

/// The centred square of the photo as a JPEG, scaled down to at most
/// [maxSide] pixels, or null when the photo can't be read.
Uint8List? squareCropImage(Uint8List bytes, {int maxSide = 1024}) {
  final image = _decodeUpright(bytes);
  if (image == null) return null;
  final r = squareCropRect(image.width, image.height);
  if (r == null) return null;
  var out = img.copyCrop(image, x: r.x, y: r.y, width: r.width, height: r.height);
  if (out.width > maxSide) out = img.copyResize(out, width: maxSide, height: maxSide);
  return img.encodeJpg(out, quality: 88);
}

/// [cropImageRegion] in the shape `compute` takes.
Uint8List? cropImageRegionJob(({Uint8List bytes, FractionBox box}) job) => cropImageRegion(job.bytes, job.box);

/// [squareCropImage] in the shape `compute` takes.
Uint8List? squareCropImageJob(Uint8List bytes) => squareCropImage(bytes);
