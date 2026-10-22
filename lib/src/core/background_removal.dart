/// Media Gallery uploads, worked out on the admin's own device (no outside
/// service): taking a plain background off an icon or logo, and making each
/// kind of upload the file it is kept as. Pure Dart on the `image` package,
/// so it runs in an isolate (`compute`) and in unit tests.
///
/// Background removal is an edge flood fill: starting from every pixel on
/// the border, it clears each pixel whose colour is within [strength] (RGB
/// distance) of the corner colour, and keeps going inward while it does. A
/// plain background around a shape goes; the same colour inside the shape,
/// cut off from the edge, stays. It suits logos and icons on a flat
/// background, not photos.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'media_assets.dart';

/// The strength slider: its ends and where it starts.
const removalStrengthMin = 5.0;
const removalStrengthMax = 120.0;
const removalStrengthDefault = 40.0;

/// An icon is kept as a square this many pixels across.
const iconSide = 256;

/// An image is kept at most this wide.
const imageMaxWidth = 1600;

/// A logo is kept at most this long on its longer side.
const logoMaxSide = 1024;

/// The colour the background is taken to be: of the four corners, the one
/// closest to the others (so one odd corner, a watermark or a shape that
/// touches it, does not decide). Each as `[r, g, b]`. A see-through corner
/// has no colour to give and is passed over; with all four see-through,
/// the top left's.
List<int> cornerColour(img.Image src) {
  final w = src.width, h = src.height;
  final all = [for (final (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]) src.getPixel(x, y)];
  final opaque = all.where((p) => p.a > 0).toList();
  final corners = [
    for (final p in opaque.isEmpty ? all.take(1) : opaque) [p.r.toInt(), p.g.toInt(), p.b.toInt()],
  ];
  var best = corners.first;
  var bestSum = double.infinity;
  for (final c in corners) {
    var sum = 0.0;
    for (final o in corners) {
      sum += _distance(c[0], c[1], c[2], o[0], o[1], o[2]);
    }
    if (sum < bestSum) {
      bestSum = sum;
      best = c;
    }
  }
  return best;
}

double _distance(int r1, int g1, int b1, int r2, int g2, int b2) {
  final dr = r1 - r2, dg = g1 - g2, db = b1 - b2;
  return math.sqrt(dr * dr + dg * dg + db * db);
}

/// [src] as an 8-bit RGBA image (a copy).
img.Image _rgba(img.Image src) => src.convert(format: img.Format.uint8, numChannels: 4);

/// A copy of [src] with the background around its shape made transparent
/// (see the library comment). [strength] is how far from the corner colour a
/// pixel may be and still count as background: 0 takes only that exact
/// colour, 120 a good deal around it. Pixels at the edge of what was taken
/// that are close to it are made partly see-through, which softens the
/// fringe a plain cut leaves round a smooth shape.
img.Image removeEdgeBackground(img.Image src, {double strength = removalStrengthDefault}) {
  final out = _rgba(src);
  final w = out.width, h = out.height;
  if (w == 0 || h == 0) return out;
  final px = out.getBytes(order: img.ChannelOrder.rgba);
  final bg = cornerColour(out);
  final tol = strength.clamp(0, 442).toDouble();
  double dist(int i) => _distance(px[i * 4], px[i * 4 + 1], px[i * 4 + 2], bg[0], bg[1], bg[2]);

  final seen = Uint8List(w * h);
  final removed = Uint8List(w * h);
  final stack = <int>[];
  for (var x = 0; x < w; x++) {
    stack
      ..add(x)
      ..add((h - 1) * w + x);
  }
  for (var y = 0; y < h; y++) {
    stack
      ..add(y * w)
      ..add(y * w + w - 1);
  }
  while (stack.isNotEmpty) {
    final k = stack.removeLast();
    if (seen[k] == 1) continue;
    seen[k] = 1;
    // Already see-through: background, and the fill goes on through it.
    final clear = px[k * 4 + 3] == 0;
    if (!clear && dist(k) > tol) continue;
    px[k * 4 + 3] = 0;
    removed[k] = 1;
    final x = k % w, y = k ~/ w;
    if (x > 0) stack.add(k - 1);
    if (x < w - 1) stack.add(k + 1);
    if (y > 0) stack.add(k - w);
    if (y < h - 1) stack.add(k + w);
  }

  // The fringe: a kept pixel beside a removed one, near the background
  // colour, keeps only as much of itself as it differs from it.
  if (tol > 0) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final k = y * w + x;
        if (removed[k] == 1 || px[k * 4 + 3] == 0) continue;
        final touches = (x > 0 && removed[k - 1] == 1) ||
            (x < w - 1 && removed[k + 1] == 1) ||
            (y > 0 && removed[k - w] == 1) ||
            (y < h - 1 && removed[k + w] == 1);
        if (!touches) continue;
        final d = dist(k);
        if (d >= tol * 2) continue;
        final keep = ((d - tol) / tol).clamp(0.0, 1.0);
        px[k * 4 + 3] = (px[k * 4 + 3] * keep).round();
      }
    }
  }
  return img.Image.fromBytes(width: w, height: h, bytes: px.buffer, numChannels: 4, order: img.ChannelOrder.rgba);
}

/// How many pixels of [image] are fully see-through.
int transparentPixels(img.Image image) {
  var n = 0;
  for (final p in image) {
    if (p.a == 0) n++;
  }
  return n;
}

/// [src] cut down to the box round its non-transparent pixels; [src] itself
/// when nothing is see-through or everything is.
img.Image trimTransparent(img.Image src) {
  var minX = src.width, minY = src.height, maxX = -1, maxY = -1;
  for (final p in src) {
    if (p.a == 0) continue;
    if (p.x < minX) minX = p.x;
    if (p.y < minY) minY = p.y;
    if (p.x > maxX) maxX = p.x;
    if (p.y > maxY) maxY = p.y;
  }
  if (maxX < 0) return src;
  if (minX == 0 && minY == 0 && maxX == src.width - 1 && maxY == src.height - 1) return src;
  return img.copyCrop(src, x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1);
}

/// [src] fitted, its shape kept, in the middle of a transparent [side] ×
/// [side] square.
img.Image fitInSquare(img.Image src, int side) {
  final scale = math.min(side / src.width, side / src.height);
  final w = math.max(1, (src.width * scale).round()), h = math.max(1, (src.height * scale).round());
  final resized = img.copyResize(_rgba(src), width: w, height: h, interpolation: img.Interpolation.average);
  final canvas = img.Image(width: side, height: side, numChannels: 4);
  img.compositeImage(canvas, resized, dstX: (side - w) ~/ 2, dstY: (side - h) ~/ 2, blend: img.BlendMode.direct);
  return canvas;
}

/// [src] scaled down, its shape kept, so its longer side is at most [max]
/// (the same picture when it already is).
img.Image limitSide(img.Image src, int max) {
  final long = math.max(src.width, src.height);
  if (long <= max) return src;
  final scale = max / long;
  return img.copyResize(
    src,
    width: math.max(1, (src.width * scale).round()),
    height: math.max(1, (src.height * scale).round()),
    interpolation: img.Interpolation.average,
  );
}

/// [src] scaled down, its shape kept, to at most [max] wide.
img.Image limitWidth(img.Image src, int max) => src.width <= max
    ? src
    : img.copyResize(src, width: max, height: math.max(1, (src.height * max / src.width).round()),
        interpolation: img.Interpolation.average);

/// Whether [bytes] look like an SVG file.
bool looksLikeSvg(Uint8List bytes) {
  final head = utf8.decode(bytes.length > 2048 ? bytes.sublist(0, 2048) : bytes, allowMalformed: true).toLowerCase();
  return head.contains('<svg');
}

/// Why an SVG can't be kept, or null. The files are served from a public
/// address, so one that could run script (a `<script>`, an `on…=` handler,
/// a `javascript:` link, embedded HTML) is refused.
String? svgProblem(Uint8List bytes) {
  final text = utf8.decode(bytes, allowMalformed: true).toLowerCase();
  if (!text.contains('<svg')) return 'This is not an SVG file.';
  if (text.contains('<script') ||
      RegExp(r'\son[a-z]+\s*=').hasMatch(text) ||
      text.contains('javascript:') ||
      text.contains('<foreignobject') ||
      text.contains('<iframe')) {
    return 'This SVG has script or embedded HTML in it. Save it again without them, or use a PNG.';
  }
  return null;
}

/// One file to make into an upload.
class MediaJob {
  const MediaJob({
    required this.bytes,
    required this.mime,
    required this.kind,
    this.removeBackground = false,
    this.strength = removalStrengthDefault,
  });

  final Uint8List bytes;

  /// What the file says it is (from its name).
  final String mime;
  final MediaKind kind;
  final bool removeBackground;
  final double strength;
}

/// An upload's file as it is kept.
class ProcessedMedia {
  const ProcessedMedia({required this.bytes, required this.mime, this.width, this.height});

  final Uint8List bytes;
  final String mime;
  final int? width, height;
}

/// [bytes] decoded; null for a file the decoders can't read (some throw
/// on a short or broken file rather than answering null).
img.Image? _decode(Uint8List bytes) {
  try {
    return img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
}

/// [job] made into the file the gallery keeps (a top-level function, for
/// `compute`):
///  * an icon: background taken off when asked, cut to its shape, fitted in
///    a 256 × 256 transparent PNG;
///  * an image: at most 1600 px wide, its shape kept, as WebP (smaller than
///    PNG or JPEG for the same look, and it keeps transparency);
///  * a logo: background taken off when asked, cut to its shape, at most
///    1024 px on its longer side, as a transparent PNG.
/// An SVG is kept as it is (after [svgProblem]). Throws a [FormatException]
/// for a file that can't be read.
ProcessedMedia processMediaJob(MediaJob job) {
  if (job.mime == 'image/svg+xml' || looksLikeSvg(job.bytes)) {
    final problem = svgProblem(job.bytes);
    if (problem != null) throw FormatException(problem);
    return ProcessedMedia(bytes: job.bytes, mime: 'image/svg+xml');
  }
  final decoded = _decode(job.bytes);
  if (decoded == null) throw const FormatException('This file could not be read as a picture.');
  var image = img.bakeOrientation(decoded);
  if (job.removeBackground) image = removeEdgeBackground(image, strength: job.strength);
  switch (job.kind) {
    case MediaKind.icon:
      if (job.removeBackground) image = trimTransparent(image);
      final out = fitInSquare(image, iconSide);
      return ProcessedMedia(bytes: img.encodePng(out), mime: 'image/png', width: iconSide, height: iconSide);
    case MediaKind.logo:
      if (job.removeBackground) image = trimTransparent(image);
      final out = limitSide(_rgba(image), logoMaxSide);
      return ProcessedMedia(bytes: img.encodePng(out), mime: 'image/png', width: out.width, height: out.height);
    case MediaKind.image:
      final out = limitWidth(image, imageMaxWidth);
      return ProcessedMedia(
        bytes: img.encodeWebP(out, lossless: false, quality: 80),
        mime: 'image/webp',
        width: out.width,
        height: out.height,
      );
  }
}

/// A small copy of [bytes] for the dialog's before/after preview, at most
/// [maxSide] on its longer side; null for an SVG or a file that can't be
/// read.
img.Image? previewImage(Uint8List bytes, {int maxSide = 192}) {
  if (looksLikeSvg(bytes)) return null;
  final decoded = _decode(bytes);
  if (decoded == null) return null;
  return limitSide(_rgba(img.bakeOrientation(decoded)), maxSide);
}

/// The "after" preview of [small] as PNG bytes: the background taken off
/// when [remove], else as it is.
Uint8List previewAfter(img.Image small, {required bool remove, required double strength}) =>
    img.encodePng(remove ? removeEdgeBackground(small, strength: strength) : small);
