// Document reading, part 3: the photo check before upload (sharp, no glare,
// all four corners), on generated document photos.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/photo_quality.dart';
import 'package:image/image.dart' as img;

/// A made-up document on a table: a light card with lines of text.
img.Image _doc({int top = 60, int left = 80, int right = 80, int bottom = 60}) {
  final im = img.Image(width: 1000, height: 700);
  img.fill(im, color: img.ColorRgb8(120, 100, 80));
  img.fillRect(im, x1: left, y1: top, x2: 1000 - right, y2: 700 - bottom, color: img.ColorRgb8(235, 232, 225));
  for (var i = 0; i < 12; i++) {
    img.drawString(im, 'NO. KAD PENGENALAN 900101-14-5678 SAMPLE', font: img.arial24, x: left + 30, y: top + 20 + i * 45,
        color: img.ColorRgb8(20, 20, 20));
  }
  return im;
}

void main() {
  test('a good photo passes all three', () {
    final q = checkPhoto(_doc());
    expect(q.good, isTrue);
    expect(q.advice, isNull);
    expect(q.toJson(), {'sharp': true, 'glare': false, 'corners': true});
    expect(checkPhoto(_doc(top: 15, left: 15, right: 15, bottom: 15)).allCorners, isTrue, reason: 'framed tight');
    expect(checkPhoto(img.copyResize(_doc(), width: 400)).good, isTrue, reason: 'a small photo');
  });

  test('blurred', () {
    expect(checkPhoto(img.gaussianBlur(_doc(), radius: 2)).sharp, isTrue, reason: 'slightly soft is fine');
    final q = checkPhoto(img.gaussianBlur(_doc(), radius: 8));
    expect(q.sharp, isFalse);
    expect(q.advice, contains('hold the phone still'));
  });

  test('glare', () {
    final g = _doc();
    img.fillCircle(g, x: 500, y: 350, radius: 110, color: img.ColorRgb8(255, 255, 255));
    final q = checkPhoto(g);
    expect(q.noGlare, isFalse);
    expect(q.sharp && q.allCorners, isTrue);
    expect(q.toJson()['glare'], isTrue);
    expect(q.advice, contains('reflection'));
  });

  test('an edge cut off', () {
    expect(checkPhoto(_doc(top: -40)).cutSides, ['top']);
    expect(checkPhoto(_doc(left: -60)).cutSides, ['left']);
    final both = checkPhoto(_doc(top: -40, right: -40));
    expect(both.cutSides, ['top', 'right']);
    expect(both.advice, contains('whole document is in the photo'));
  });

  test('bytes that aren\'t a photo', () {
    expect(checkPhotoBytes(img.encodePng(_doc())), isNotNull);
    expect(checkPhotoBytes(img.encodeJpg(img.Image(width: 8, height: 8))), isNotNull);
    expect(checkPhotoBytes(Uint8List.fromList([1, 2, 3])), isNull);
  });
}
