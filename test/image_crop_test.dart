import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/image_crop.dart';
import 'package:image/image.dart' as img;

/// A [w]×[h] PNG, red on the left half and blue on the right.
Uint8List _halves(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, x < w ~/ 2 ? 255 : 0, 0, x < w ~/ 2 ? 0 : 255);
    }
  }
  return img.encodePng(image);
}

void main() {
  group('FractionBox.parse', () {
    test('reads numbers and numeric strings, clamped to the image', () {
      expect(
        FractionBox.parse({'x': 0.1, 'y': '0.2', 'width': 0.3, 'height': 0.4}),
        const FractionBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
      );
      expect(
        FractionBox.parse({'x': -0.5, 'y': 2, 'width': 1.5, 'height': 0.5}),
        const FractionBox(x: 0, y: 1, width: 1, height: 0.5),
      );
    });

    test('refuses a missing value, a non-number or an empty box', () {
      expect(FractionBox.parse(null), isNull);
      expect(FractionBox.parse('0,0,1,1'), isNull);
      expect(FractionBox.parse({'x': 0, 'y': 0, 'width': 0.5}), isNull);
      expect(FractionBox.parse({'x': 0, 'y': 0, 'width': 'wide', 'height': 0.5}), isNull);
      expect(FractionBox.parse({'x': 0, 'y': 0, 'width': 0, 'height': 0.5}), isNull);
      expect(FractionBox.parse({'x': 0, 'y': 0, 'width': -1, 'height': 0.5}), isNull);
      expect(FractionBox.parse({'x': 0, 'y': 0, 'width': double.nan, 'height': 0.5}), isNull);
    });
  });

  group('paddedCropRect', () {
    test('grows the box by the padding on every side', () {
      // 0.2..0.4 wide on 1000 px, padded by 12% of 0.2 = 0.024 each side.
      final r = paddedCropRect(const FractionBox(x: 0.2, y: 0.3, width: 0.2, height: 0.4), 1000, 500);
      expect(r, (x: 176, y: 126, width: 248, height: 248));
    });

    test('stays inside the image at the edges', () {
      final r = paddedCropRect(const FractionBox(x: 0, y: 0.9, width: 1, height: 0.1), 200, 100);
      expect(r!.x, 0);
      expect(r.width, 200);
      expect(r.y + r.height, lessThanOrEqualTo(100));
      expect(r.y, 89);
    });

    test('skips an empty image or a sliver', () {
      const box = FractionBox(x: 0.1, y: 0.1, width: 0.5, height: 0.5);
      expect(paddedCropRect(box, 0, 100), isNull);
      expect(paddedCropRect(box, 100, 0), isNull);
      expect(paddedCropRect(const FractionBox(x: 1, y: 0, width: 0.01, height: 0.5), 100, 100), isNull);
      expect(paddedCropRect(const FractionBox(x: 0, y: 0, width: 0.001, height: 0.5), 100, 100), isNull);
    });
  });

  test('squareCropRect takes the centred square', () {
    expect(squareCropRect(400, 300), (x: 50, y: 0, width: 300, height: 300));
    expect(squareCropRect(300, 401), (x: 0, y: 50, width: 300, height: 300));
    expect(squareCropRect(10, 10), (x: 0, y: 0, width: 10, height: 10));
    expect(squareCropRect(0, 10), isNull);
  });

  group('cropping a photo', () {
    test('cuts the box out as a JPEG', () {
      final out = cropImageRegion(
        _halves(200, 100),
        const FractionBox(x: 0.6, y: 0.2, width: 0.3, height: 0.6),
        pad: 0,
      );
      expect(out, isNotNull);
      final decoded = img.decodeJpg(out!)!;
      expect((decoded.width, decoded.height), (60, 60));
      // Entirely in the blue half.
      final p = decoded.getPixel(30, 30);
      expect(p.b, greaterThan(200));
      expect(p.r, lessThan(60));
    });

    test('an unreadable photo or a sliver is skipped', () {
      expect(
        cropImageRegion(Uint8List.fromList([1, 2, 3]), const FractionBox(x: 0, y: 0, width: 1, height: 1)),
        isNull,
      );
      expect(cropImageRegion(_halves(10, 10), const FractionBox(x: 0, y: 0, width: 0.01, height: 1)), isNull);
    });

    test('a profile photo is cut square and scaled down', () {
      final out = squareCropImage(_halves(300, 120))!;
      final decoded = img.decodeJpg(out)!;
      expect((decoded.width, decoded.height), (120, 120));

      final big = img.decodeJpg(squareCropImage(_halves(400, 300), maxSide: 100)!)!;
      expect((big.width, big.height), (100, 100));
      expect(squareCropImage(Uint8List(8)), isNull);
    });
  });
}
