// Multi-angle map icons (0336): how a ZIP's file names become headings,
// which frame a car heading picks, and the media row's `angles`.
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/map_icon_angles.dart';
import 'package:get_ride/src/core/media_assets.dart';

const _id = '44444444-4444-4444-4444-444444444444';

List<int> _degs(ZipFrameMapping m) => [for (final f in m.frames) f.deg];

Uint8List _zip(Map<String, List<int>> files) {
  final a = Archive();
  for (final e in files.entries) {
    a.addFile(ArchiveFile.bytes(e.key, Uint8List.fromList(e.value)));
  }
  return Uint8List.fromList(ZipEncoder().encode(a));
}

void main() {
  group('ZIP names to headings', () {
    test('a number in each name is its heading', () {
      final m = mapZipFrameNames(['car_090.png', 'car_000.png', 'car_270.png', 'car_180.png']);
      expect(m.ok, isTrue);
      expect(m.spread, isFalse);
      expect(_degs(m), [0, 90, 180, 270]);
      expect(m.frames.first.name, 'car_000.png');
    });

    test('plain numbers, other prefixes, WebP and JPG, folders', () {
      expect(_degs(mapZipFrameNames(['45.png', '0.png', '315.png'])), [0, 45, 315]);
      expect(_degs(mapZipFrameNames(['angle-090.webp', 'angle-000.jpg', 'angle-180.JPEG'])), [0, 90, 180]);
      expect(_degs(mapZipFrameNames(['blue2/car_045.png', 'blue2/car_225.png'])), [45, 225],
          reason: 'the last number in the file name, not the folder');
      expect(_degs(mapZipFrameNames(['taxi2_000.png', 'taxi2_120.png', 'taxi2_240.png'])), [0, 120, 240]);
    });

    test('a sequence is spread evenly round 360° in name order', () {
      final names = [for (var i = 16; i >= 1; i--) 'frame_${i.toString().padLeft(2, '0')}.png'];
      final m = mapZipFrameNames(names);
      expect(m.ok, isTrue);
      expect(m.spread, isTrue);
      expect(m.frames.length, 16);
      expect(m.frames.first.name, 'frame_01.png');
      expect(m.frames[1], (name: 'frame_02.png', deg: 23), reason: '22.5° kept as 23');
      expect(m.frames[4], (name: 'frame_05.png', deg: 90));
      expect(m.frames.last, (name: 'frame_16.png', deg: 338));
      // Unpadded numbers sort as people read them.
      final n = mapZipFrameNames(['f1.png', 'f10.png', 'f2.png', 'f3.png', 'f4.png', 'f5.png', 'f6.png', 'f7.png', 'f8.png', 'f9.png']);
      expect(n.spread, isTrue);
      expect([for (final f in n.frames) f.name].take(3), ['f1.png', 'f2.png', 'f3.png']);
      expect(n.frames[9], (name: 'f10.png', deg: 324));
      // From 0 too, and names with no numbers at all.
      expect(_degs(mapZipFrameNames(['a0.png', 'a1.png', 'a2.png', 'a3.png'])), [0, 90, 180, 270]);
      final words = mapZipFrameNames(['north.png', 'east.png', 'south.png', 'west.png']);
      expect(words.spread, isTrue);
      expect([for (final f in words.frames) f.name], ['east.png', 'north.png', 'south.png', 'west.png']);
    });

    test('junk is left out: __MACOSX, hidden files, folders, Thumbs.db', () {
      final m = mapZipFrameNames([
        'cars/',
        '__MACOSX/cars/._car_000.png',
        'cars/.DS_Store',
        'cars/._car_090.png',
        '.hidden/car_180.png',
        'cars/Thumbs.db',
        'cars/car_000.png',
        'cars/car_090.png',
      ]);
      expect(m.ok, isTrue, reason: m.error);
      expect(_degs(m), [0, 90]);
      expect(m.skipped, 6);
    });

    test('refused: not pictures, more than 72, fewer than 2, twice, over 359', () {
      final txt = mapZipFrameNames(['car_000.png', 'readme.txt', 'car_090.png']);
      expect(txt.ok, isFalse);
      expect(txt.error, contains('readme.txt'));
      expect(txt.error, contains('not pictures'));
      expect(mapZipFrameNames(['a.png', 'b.svg']).error, contains('b.svg'), reason: 'an SVG is not a frame');
      final many = mapZipFrameNames([for (var i = 0; i < 73; i++) 'f_$i.png']);
      expect(many.error, 'The ZIP has 73 pictures. A map icon takes at most 72 angles.');
      expect(mapZipFrameNames([for (var i = 0; i < 72; i++) 'f_$i.png']).ok, isTrue);
      expect(mapZipFrameNames(['car_000.png']).error, contains('only one picture'));
      expect(mapZipFrameNames(['__MACOSX/a.png', '.x.png']).error, contains('no PNG'));
      expect(mapZipFrameNames(['car_045.png', 'car45.webp', 'car_090.png']).error, contains('both 45°'));
      expect(mapZipFrameNames(['car_000.png', 'car_400.png']).error, contains('0 to 359'));
    });

    test('reads a real ZIP and checks its sizes', () {
      final r = readZipFrames(_zip({
        'cars/car_090.png': [1, 2, 3],
        'cars/car_000.png': [4, 5],
        '__MACOSX/cars/._car_000.png': [0],
      }));
      expect(r.error, isNull);
      expect([for (final f in r.frames) (f.name, f.deg, f.bytes.length)], [('car_000.png', 0, 2), ('car_090.png', 90, 3)]);
      expect(readZipFrames(Uint8List.fromList([1, 2, 3])).error, 'This file could not be opened as a ZIP.');
      expect(readZipFrames(Uint8List(mapIconZipMaxBytes + 1)).error, contains('over 20 MB'));
      final big = readZipFrames(_zip({'a_000.png': Uint8List(mapIconFrameMaxBytes + 1), 'a_180.png': [1]}));
      expect(big.error, '"a_000.png" is over 2 MB. Each angle must be smaller.');
    });
  });

  group('the frame for a heading', () {
    final four = [for (final d in [0, 90, 180, 270]) MediaAngle(d, 'map_icon/$_id/${d.toString().padLeft(3, '0')}.png')];

    test('the nearest frame', () {
      expect(nearestAngle(four, 0)!.deg, 0);
      expect(nearestAngle(four, 44)!.deg, 0);
      expect(nearestAngle(four, 46)!.deg, 90);
      expect(nearestAngle(four, 200)!.deg, 180);
      expect(nearestAngle(four, 260)!.deg, 270);
    });

    test('wraps round 360', () {
      expect(nearestAngle(four, 350)!.deg, 0);
      expect(nearestAngle(four, 359.9)!.deg, 0);
      expect(nearestAngle(four, 360)!.deg, 0);
      expect(nearestAngle(four, 405)!.deg, 0, reason: '45 after a full turn: a tie, the lower heading');
      expect(nearestAngle(four, -10)!.deg, 0);
      expect(nearestAngle(four, -80)!.deg, 270);
      final two = [const MediaAngle(10, 'a'), const MediaAngle(300, 'b')];
      expect(nearestAngle(two, 350)!.deg, 10, reason: '20° away across north, not 50°');
      expect(nearestAngle(two, 330)!.deg, 300);
    });

    test('a tie goes to the lower heading; no frames, no frame', () {
      expect(nearestAngle(four, 45)!.deg, 0);
      expect(nearestAngle(four, 135)!.deg, 90);
      expect(nearestAngle(const [], 90), isNull);
      expect(headingGap(350, 10), 20);
      expect(headingGap(10, 350), 20);
      expect(headingGap(0, 180), 180);
    });

    test('16 slots, labels, stored degrees and paths', () {
      expect(mapIconSlots(8), [0, 45, 90, 135, 180, 225, 270, 315]);
      expect(mapIconSlots(16)[1], 22.5);
      expect(degreeLabel(22.5), '22.5°');
      expect(degreeLabel(45), '45°');
      expect(storedDegree(22.5), 23);
      expect(storedDegree(359.6), 0);
      expect(mapIconFramePath(_id, 45, 'image/png'), 'map_icon/$_id/045.png');
      expect(mapIconFramePath(_id, 5, 'image/webp'), 'map_icon/$_id/005.webp');
    });
  });

  group('the media row', () {
    test('angles read, sorted, bad ones left out, and written back', () {
      final a = MediaAsset.fromRow({
        'id': _id,
        'kind': 'map_icon',
        'name': 'Taxi',
        'path': null,
        'angles': [
          {'deg': 180, 'path': 'map_icon/$_id/180.png'},
          {'deg': 0, 'path': 'map_icon/$_id/000.png'},
          {'deg': 'x', 'path': 'nope'},
          {'deg': 400, 'path': 'nope'},
          {'deg': 90, 'path': 'map_icon/$_id/090.png'},
        ],
      })!;
      expect(a.isMultiAngle, isTrue);
      expect([for (final f in a.angles) f.deg], [0, 90, 180]);
      expect(a.pathFor(dark: false), 'map_icon/$_id/000.png', reason: 'the first frame, with no main file');
      expect(a.pathFor(dark: true), 'map_icon/$_id/000.png');
      expect(a.frameFor(100)!.path, 'map_icon/$_id/090.png');
      expect(a.files, ['map_icon/$_id/000.png', 'map_icon/$_id/090.png', 'map_icon/$_id/180.png']);
      expect(a.toRow()['angles'], [
        {'deg': 0, 'path': 'map_icon/$_id/000.png'},
        {'deg': 90, 'path': 'map_icon/$_id/090.png'},
        {'deg': 180, 'path': 'map_icon/$_id/180.png'},
      ]);
    });

    test('a single icon has no angles and writes none', () {
      final a = MediaAsset.fromRow({'id': _id, 'kind': 'map_icon', 'name': 'Car', 'path': 'map_icon/$_id.png'})!;
      expect(a.isMultiAngle, isFalse);
      expect(a.frameFor(90), isNull);
      expect(a.toRow().containsKey('angles'), isFalse);
      expect(a.files, ['map_icon/$_id.png']);
      // Only a map icon reads angles.
      final icon = MediaAsset.fromRow({
        'id': _id,
        'kind': 'icon',
        'name': 'x',
        'path': 'icon/$_id.png',
        'angles': [
          {'deg': 0, 'path': 'a'},
          {'deg': 90, 'path': 'b'},
        ],
      })!;
      expect(icon.angles, isEmpty);
      // A logo's files: both versions.
      const logo = MediaAsset(id: _id, kind: MediaKind.logo, name: 'L', path: 'logo/$_id.png', darkPath: 'logo/$_id-dark.png');
      expect(logo.files, ['logo/$_id.png', 'logo/$_id-dark.png']);
    });
  });
}
