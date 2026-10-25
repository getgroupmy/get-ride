/// Document reading, part 3: is a document photo good enough to read? Three
/// checks on the phone, before upload, so a bad photo is retaken at once
/// rather than rejected days later:
///
/// - sharp: the photo isn't blurred (variance of the Laplacian);
/// - no glare: no patch of the photo is burnt out to white by a reflection;
/// - all four corners: the document doesn't run off an edge of the photo
///   (its own edge shows near each side of the photo).
///
/// They are hints, never a block: the driver can still send the photo, and
/// a reviewer sees what the checks said. Pure: see test/photo_quality_test.dart.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class PhotoQuality {
  const PhotoQuality({
    required this.sharp,
    required this.noGlare,
    required this.allCorners,
    this.sharpness = 0,
    this.glarePart = 0,
    this.cutSides = const [],
  });

  final bool sharp;
  final bool noGlare;
  final bool allCorners;

  /// Variance of the Laplacian (higher is sharper).
  final double sharpness;

  /// The burnt-out share of the brightest grid cell (0..1).
  final double glarePart;

  /// The sides the document seems to run off: 'top', 'right', 'bottom', 'left'.
  final List<String> cutSides;

  bool get good => sharp && noGlare && allCorners;

  Map<String, dynamic> toJson() => {'sharp': sharp, 'glare': !noGlare, 'corners': allCorners};

  /// What to do about it, or null when the photo is fine.
  String? get advice {
    if (good) return null;
    final steps = [
      if (!sharp) 'hold the phone still and tap the document to focus',
      if (!noGlare) 'tilt the document or move away from the light to stop the reflection',
      if (!allCorners) 'step back so the whole document is in the photo with a little space around it',
    ];
    return 'For a clearer photo, ${steps.join(', and ')}. You can still send this one.';
  }
}

/// Below this the photo is blurred (calibrated on document photos at 512 px).
const sharpnessFloor = 100.0;

/// A grid cell this burnt out (≥ 252 grey) is glare.
const glareCellPart = 0.6;

/// A brightness step this big (0..255, across 2 px) can be the document's edge.
const edgeStep = 24.0;

/// The share of the middle 60% a line of such steps must cover to be an edge.
const edgeLinePart = 0.7;

/// The checks, on a photo's bytes; null when they can't be decoded.
PhotoQuality? checkPhotoBytes(Uint8List bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    // Some decoders throw on bytes that aren't theirs instead of saying no.
    return null;
  }
  return decoded == null ? null : checkPhoto(decoded);
}

PhotoQuality checkPhoto(img.Image photo) {
  final small = photo.width > 512 ? img.copyResize(photo, width: 512) : photo;
  final w = small.width, h = small.height;
  final grey = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = small.getPixel(x, y);
      grey[y * w + x] = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
    }
  }
  double at(int x, int y) => grey[y * w + x];

  // Sharpness: variance of the Laplacian over the inside of the photo.
  var sum = 0.0, sumSq = 0.0, n = 0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final c = at(x, y);
      final lap = 4 * c - at(x - 1, y) - at(x + 1, y) - at(x, y - 1) - at(x, y + 1);
      sum += lap;
      sumSq += lap * lap;
      n++;
    }
  }
  final mean = n == 0 ? 0.0 : sum / n;
  final sharpness = n == 0 ? 0.0 : sumSq / n - mean * mean;

  // Glare: the most burnt-out cell of an 8 x 8 grid.
  var worst = 0.0;
  const cells = 8;
  for (var cy = 0; cy < cells; cy++) {
    for (var cx = 0; cx < cells; cx++) {
      final x0 = cx * w ~/ cells, x1 = (cx + 1) * w ~/ cells;
      final y0 = cy * h ~/ cells, y1 = (cy + 1) * h ~/ cells;
      var burnt = 0, all = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          all++;
          if (at(x, y) >= 252) burnt++;
        }
      }
      if (all > 0) worst = math.max(worst, burnt / all);
    }
  }

  // Corners: near each side, the document's own edge, a line across most of
  // the middle of the photo where the brightness steps. A side with no such
  // line between the photo's edge and the document is one it runs off.
  bool edgeNear(String side) {
    final across = side == 'top' || side == 'bottom';
    final len = across ? w : h, depth = across ? h : w;
    final from = (len * 0.2).round(), to = (len * 0.8).round();
    final reach = math.max(3, (depth * 0.3).round());
    for (var d = 1; d < reach; d++) {
      final line = switch (side) { 'top' || 'left' => d, _ => depth - 1 - d };
      var steps = 0;
      for (var i = from; i < to; i++) {
        final x = across ? i : line, y = across ? line : i;
        if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
        final g = across ? (at(x, y + 1) - at(x, y - 1)).abs() : (at(x + 1, y) - at(x - 1, y)).abs();
        if (g >= edgeStep) steps++;
      }
      if (steps >= (to - from) * edgeLinePart) return true;
    }
    return false;
  }

  final cut = [for (final side in ['top', 'right', 'bottom', 'left']) if (!edgeNear(side)) side];

  return PhotoQuality(
    sharp: sharpness >= sharpnessFloor,
    noGlare: worst < glareCellPart,
    allCorners: cut.isEmpty,
    sharpness: sharpness,
    glarePart: worst,
    cutSides: cut,
  );
}
