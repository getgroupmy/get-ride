// The confirm map's pickup/drop/stop marks, drawn as PNG images so MapKit can
// place them as native annotations on the Apple base (apple_native_layer.dart).
// On the Apple base the route is MapKit's own polyline, locked to the roads;
// a flutter_map marker on top sits in a slightly different projection and drifts
// off the route. Drawing the marks as native annotations too — from this same
// inDrive badge design — keeps the marks, the route and Apple's roads all in one
// projection, so they line up exactly.
//
// A MapKit annotation is placed by its anchor (a fraction of the image): the
// ringed dot's centre is the anchor, so the dot lands on the point with the
// badge standing above it, exactly as the flutter badge does. The geometry is
// pure and tested (badgeImageMetrics); the raster needs the engine (a running
// app). The plugin builds the UIImage at the screen scale, so the caller renders
// at the device pixel ratio for a crisp mark at the right size.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'ride_map.dart' show confirmBadgeSize, confirmPickupGap, confirmPickupDot;

/// A confirm-badge image's size (logical px) and the anchor MapKit places it by
/// — the fraction of the image where the ringed dot's centre sits, so the dot
/// lands on the point. A stop (no dot) anchors at its centre. Pure; see
/// test/map_badge_bitmap_test.dart.
class BadgeImageMetrics {
  const BadgeImageMetrics({required this.width, required this.height, required this.anchor});
  final double width, height;
  final Offset anchor;
}

/// The badge image's size and anchor for a square of [square], a [gap] below it
/// and a ringed dot of [dot]. With [withDot] the dot stands below the square and
/// the anchor is the dot's centre; without it (a stop's plain square) the image
/// is just the square, anchored at its centre. Pure.
BadgeImageMetrics badgeImageMetrics({
  double square = confirmBadgeSize,
  double gap = confirmPickupGap,
  double dot = confirmPickupDot,
  bool withDot = true,
}) {
  if (!withDot) return BadgeImageMetrics(width: square, height: square, anchor: const Offset(0.5, 0.5));
  final height = square + gap + dot;
  final dotCenterY = square + gap + dot / 2;
  return BadgeImageMetrics(width: square, height: height, anchor: Offset(0.5, dotCenterY / height));
}

/// Draws one confirm badge ([glyph] in a rounded square, over a ringed dot when
/// [withDot]) to a PNG, at [scale] device pixels per logical pixel, for a native
/// MapKit annotation. [fill] is the square/ring colour, [ink] the glyph/dot
/// colour (inDrive's: dark on a light map, light on a dark one — the same as the
/// flutter badge). A stop passes a [number] and `withDot: false`.
Future<Uint8List> renderConfirmBadgePng({
  IconData? glyph,
  String? number,
  required Color fill,
  required Color ink,
  double square = confirmBadgeSize,
  double gap = confirmPickupGap,
  double dot = confirmPickupDot,
  double glyphSize = 22,
  bool withDot = true,
  double scale = 3,
}) async {
  final m = badgeImageMetrics(square: square, gap: gap, dot: dot, withDot: withDot);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);

  // The rounded square at the top (the image is as wide as the square).
  final squareRect = RRect.fromRectAndRadius(
    Rect.fromLTWH(0, 0, square, square),
    Radius.circular(square * 0.28),
  );
  canvas.drawRRect(squareRect, Paint()..color = fill);

  // The glyph: an icon through its font, or a stop's number.
  final span = glyph != null
      ? TextSpan(
          text: String.fromCharCode(glyph.codePoint),
          style: TextStyle(
            fontFamily: glyph.fontFamily,
            package: glyph.fontPackage,
            fontSize: glyphSize,
            color: ink,
            height: 1,
          ),
        )
      : TextSpan(
          text: number ?? '',
          style: TextStyle(fontSize: glyphSize, fontWeight: FontWeight.w700, color: ink, height: 1),
        );
  final tp = TextPainter(text: span, textDirection: TextDirection.ltr)..layout();
  tp.paint(canvas, Offset(square / 2 - tp.width / 2, square / 2 - tp.height / 2));

  // The ringed dot on the point, like the flutter badge: a 4px [fill] ring
  // around an [ink] centre, below the square.
  if (withDot) {
    final dotC = Offset(square / 2, square + gap + dot / 2);
    canvas.drawCircle(dotC, dot / 2, Paint()..color = fill);
    canvas.drawCircle(dotC, dot / 2 - 4, Paint()..color = ink);
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage((m.width * scale).round(), (m.height * scale).round());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  return bytes!.buffer.asUint8List();
}
