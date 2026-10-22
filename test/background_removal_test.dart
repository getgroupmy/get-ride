// Media Gallery uploads: the edge flood fill that takes a plain background
// off, and what each kind of upload is kept as (core/background_removal.dart).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/background_removal.dart';
import 'package:get_ride/src/core/media_assets.dart';
import 'package:image/image.dart' as img;

/// A [w] × [h] picture in [bg] with a [fg] square in the middle (a quarter
/// of each side in from the edge) and, when [hole], a [bg]-coloured dot in
/// the square's middle that the edge can't reach.
img.Image _picture({
  int w = 40,
  int h = 40,
  List<int> bg = const [244, 241, 230],
  List<int> fg = const [210, 59, 59],
  bool hole = false,
}) {
  final im = img.Image(width: w, height: h, numChannels: 4);
  for (final p in im) {
    final inside = p.x >= w ~/ 4 && p.x < w - w ~/ 4 && p.y >= h ~/ 4 && p.y < h - h ~/ 4;
    final dot = hole && (p.x - w ~/ 2).abs() <= 1 && (p.y - h ~/ 2).abs() <= 1;
    final c = inside && !dot ? fg : bg;
    p
      ..r = c[0]
      ..g = c[1]
      ..b = c[2]
      ..a = 255;
  }
  return im;
}

int _alpha(img.Image im, int x, int y) => im.getPixel(x, y).a.toInt();

void main() {
  group('removeEdgeBackground', () {
    test('clears the background from the edges and keeps the shape', () {
      final out = removeEdgeBackground(_picture());
      expect(_alpha(out, 0, 0), 0);
      expect(_alpha(out, 39, 39), 0);
      expect(_alpha(out, 5, 20), 0);
      expect(_alpha(out, 20, 20), 255);
      expect(_alpha(out, 11, 11), 255);
      // Only the background: 40² less the 20² square.
      expect(transparentPixels(out), 40 * 40 - 20 * 20);
    });

    test('the background colour inside the shape, cut off from the edge, stays', () {
      final out = removeEdgeBackground(_picture(hole: true));
      expect(_alpha(out, 20, 20), 255, reason: 'the edge fill never reaches it');
      expect(_alpha(out, 0, 0), 0);
    });

    test('strength: a background near the corner colour goes with more, stays with less', () {
      // A slightly different band down the left side.
      final src = _picture();
      for (var y = 2; y < 38; y++) {
        for (var x = 0; x < 4; x++) {
          src.setPixelRgba(x, y, 224, 221, 210, 255);
        }
      }
      // The corners are the plain background.
      expect(cornerColour(src), [244, 241, 230]);
      final weak = removeEdgeBackground(src, strength: 10);
      expect(_alpha(weak, 1, 20), 255, reason: '~35 away: kept at strength 10');
      expect(_alpha(weak, 30, 2), 0);
      final strong = removeEdgeBackground(src, strength: 60);
      expect(_alpha(strong, 1, 20), 0);
      expect(_alpha(strong, 20, 20), 255, reason: 'the red square is far from the background');
    });

    test('a pixel already see-through counts as background and the fill goes on through it', () {
      final src = _picture();
      for (var x = 0; x < 40; x++) {
        src.setPixelRgba(x, 0, 0, 0, 0, 0);
      }
      final out = removeEdgeBackground(src);
      expect(_alpha(out, 5, 5), 0);
      expect(_alpha(out, 20, 20), 255);
    });

    test('the original is left as it was', () {
      final src = _picture();
      removeEdgeBackground(src);
      expect(_alpha(src, 0, 0), 255);
    });

    test('softens the fringe: a pixel next to the cleared ones and near the background keeps part of itself', () {
      final src = _picture();
      // A blended pixel on the square's edge, ~1.5 × the strength away.
      src.setPixelRgba(10, 20, 214, 201, 190, 255);
      final out = removeEdgeBackground(src, strength: 40);
      final a = _alpha(out, 10, 20);
      expect(a, greaterThan(0));
      expect(a, lessThan(255));
    });
  });

  group('trim and fit', () {
    test('trimTransparent cuts to the shape; fitInSquare centres it in a transparent square', () {
      final cut = trimTransparent(removeEdgeBackground(_picture(w: 60, h: 40)));
      expect((cut.width, cut.height), (30, 20));
      final sq = fitInSquare(cut, 256);
      expect((sq.width, sq.height), (256, 256));
      expect(_alpha(sq, 0, 0), 0, reason: 'the space above the wide shape stays clear');
      expect(_alpha(sq, 128, 128), 255);
    });

    test('limitWidth and limitSide keep the shape', () {
      final wide = img.Image(width: 3200, height: 1000);
      final w = limitWidth(wide, imageMaxWidth);
      expect((w.width, w.height), (1600, 500));
      expect(identical(limitWidth(_picture(), 1600), _picture()), isFalse);
      final tall = img.Image(width: 500, height: 2048);
      final t = limitSide(tall, logoMaxSide);
      expect((t.width, t.height), (250, 1024));
    });
  });

  group('processMediaJob', () {
    Uint8List png(img.Image im) => img.encodePng(im);

    test('an icon: a 256 × 256 transparent PNG of the shape', () {
      final out = processMediaJob(MediaJob(
        bytes: png(_picture(w: 120, h: 80)),
        mime: 'image/png',
        kind: MediaKind.icon,
        removeBackground: true,
      ));
      expect(out.mime, 'image/png');
      expect((out.width, out.height), (iconSide, iconSide));
      final back = img.decodePng(out.bytes)!;
      expect((back.width, back.height), (256, 256));
      expect(back.getPixel(0, 0).a, 0, reason: 'above the wide shape');
      expect(back.getPixel(128, 128).a, 255);
    });

    test('an image: at most 1600 wide, its shape kept, as WebP; the background left alone by default', () {
      final big = img.Image(width: 2000, height: 1000);
      img.fill(big, color: img.ColorRgb8(40, 120, 200));
      final out = processMediaJob(MediaJob(bytes: img.encodeJpg(big), mime: 'image/jpeg', kind: MediaKind.image));
      expect(out.mime, 'image/webp');
      expect((out.width, out.height), (1600, 800));
      final back = img.decodeWebP(out.bytes)!;
      expect((back.width, back.height), (1600, 800));
    });

    test('a logo: a transparent PNG cut to the shape', () {
      final out = processMediaJob(MediaJob(
        bytes: png(_picture(w: 100, h: 60)),
        mime: 'image/png',
        kind: MediaKind.logo,
        removeBackground: true,
      ));
      expect(out.mime, 'image/png');
      expect((out.width, out.height), (50, 30));
    });

    test('an SVG is kept as it is; one that could run script is refused', () {
      final svg = Uint8List.fromList(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"><circle r="4"/></svg>'));
      final out = processMediaJob(MediaJob(bytes: svg, mime: 'image/svg+xml', kind: MediaKind.icon, removeBackground: true));
      expect(out.bytes, svg);
      expect(out.mime, 'image/svg+xml');
      for (final bad in [
        '<svg><script>alert(1)</script></svg>',
        '<svg onload="alert(1)"></svg>',
        '<svg><a href="javascript:alert(1)"/></svg>',
        '<svg><foreignObject><iframe/></foreignObject></svg>',
      ]) {
        expect(
          () => processMediaJob(MediaJob(bytes: Uint8List.fromList(utf8.encode(bad)), mime: 'image/svg+xml', kind: MediaKind.icon)),
          throwsFormatException,
          reason: bad,
        );
      }
    });

    test('a file that is not a picture is refused', () {
      expect(
        () => processMediaJob(MediaJob(bytes: Uint8List.fromList([1, 2, 3, 4]), mime: 'image/png', kind: MediaKind.icon)),
        throwsFormatException,
      );
    });
  });

  test('the preview: a small copy, then the after with or without the background', () {
    final small = previewImage(img.encodePng(_picture(w: 400, h: 400)))!;
    expect(small.width, 192);
    final kept = img.decodePng(previewAfter(small, remove: false, strength: 40))!;
    expect(kept.getPixel(0, 0).a, 255);
    final cleared = img.decodePng(previewAfter(small, remove: true, strength: 40))!;
    expect(cleared.getPixel(0, 0).a, 0);
    expect(previewImage(Uint8List.fromList(utf8.encode('<svg></svg>'))), isNull);
  });

  group('media assets', () {
    test('references, paths and addresses', () {
      expect(mediaRefId('media:abc'), 'abc');
      expect(mediaRefId(' media: '), isNull);
      expect(mediaRefId('Truck'), isNull);
      expect(mediaPath(MediaKind.logo, 'id1', 'image/png', dark: true), 'logo/id1-dark.png');
      expect(mediaPath(MediaKind.image, 'id2', 'image/webp'), 'image/id2.webp');
      final url = mediaPublicUrl('https://x.supabase.co/', 'icon/id3.png');
      expect(url, 'https://x.supabase.co/storage/v1/object/public/media/icon/id3.png');
      expect(mediaPathInUrl('$url?v=2'), 'icon/id3.png');
      expect(mediaPathInUrl('https://x.supabase.co/storage/v1/object/public/app-branding/a.png'), isNull);
      expect(mediaMimeFor('A.JPEG'), 'image/jpeg');
      expect(mediaMimeFor('a.gif'), isNull);
    });

    test('limits and defaults by kind', () {
      expect(MediaKind.icon.maxBytes, 2 * 1024 * 1024);
      expect(MediaKind.image.maxBytes, 5 * 1024 * 1024);
      expect(MediaKind.icon.removeBackgroundByDefault, isTrue);
      expect(MediaKind.logo.removeBackgroundByDefault, isTrue);
      expect(MediaKind.image.removeBackgroundByDefault, isFalse);
    });

    test('a row, read back; a logo shows its dark version in dark mode', () {
      final a = MediaAsset.fromRow({
        'id': 'l1',
        'kind': 'logo',
        'name': 'Partner',
        'path': 'logo/l1.png',
        'dark_path': 'logo/l1-dark.png',
        'tint': false,
        'created_at': '2026-10-21T03:00:00Z',
      })!;
      expect(a.ref, 'media:l1');
      expect(a.pathFor(dark: true), 'logo/l1-dark.png');
      expect(a.pathFor(dark: false), 'logo/l1.png');
      expect(MediaAsset.fromRow({'id': 'x', 'kind': 'video', 'path': 'p'}), isNull);
      expect(MediaAsset.fromRow({'id': 'x', 'kind': 'icon'}), isNull, reason: 'no file');
      expect(mediaNameProblem('  '), isNotNull);
      expect(mediaNameProblem('Pharmacy cross'), isNull);
    });
  });
}
