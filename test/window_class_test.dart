import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/window_class.dart';
import 'package:get_ride/src/widgets/map_sheet_layout.dart' show wideLayoutAt;

DisplayFeature _fold(Rect bounds, {DisplayFeatureState state = DisplayFeatureState.postureFlat}) =>
    DisplayFeature(bounds: bounds, type: DisplayFeatureType.fold, state: state);

DisplayFeature _hinge(Rect bounds) =>
    DisplayFeature(bounds: bounds, type: DisplayFeatureType.hinge, state: DisplayFeatureState.unknown);

void main() {
  group('width class', () {
    test('regular once wide enough for two panes', () {
      expect(widthClassOf(const Size(390, 844)), WindowWidthClass.compact, reason: 'a phone');
      expect(widthClassOf(const Size(760, 1020)), WindowWidthClass.regular, reason: 'an unfolded inner display');
      expect(widthClassOf(const Size(1024, 768)), WindowWidthClass.regular, reason: 'a tablet');
      // >= 720 wide needs >= 500 high; a wide-but-short strip stays compact.
      expect(widthClassOf(const Size(800, 400)), WindowWidthClass.compact);
      // >= 900 wide is regular at any height.
      expect(widthClassOf(const Size(950, 400)), WindowWidthClass.regular);
    });

    test('boundaries', () {
      expect(widthClassOf(const Size(719, 900)), WindowWidthClass.compact);
      expect(widthClassOf(const Size(720, 500)), WindowWidthClass.regular);
      expect(widthClassOf(const Size(720, 499)), WindowWidthClass.compact);
      expect(widthClassOf(const Size(899, 499)), WindowWidthClass.compact);
      expect(widthClassOf(const Size(900, 499)), WindowWidthClass.regular);
    });

    test('never drifts from wideLayoutAt', () {
      for (final w in [320.0, 500.0, 719.0, 720.0, 820.0, 899.0, 900.0, 1200.0]) {
        for (final h in [390.0, 499.0, 500.0, 700.0, 1024.0]) {
          final size = Size(w, h);
          expect(
            widthClassOf(size) == WindowWidthClass.regular,
            wideLayoutAt(size),
            reason: 'width class and wideLayoutAt disagree at $size',
          );
        }
      }
    });

    test('height class', () {
      expect(heightClassOf(const Size(844, 390)), WindowHeightClass.compact);
      expect(heightClassOf(const Size(390, 844)), WindowHeightClass.regular);
      expect(heightClassOf(const Size(800, 500)), WindowHeightClass.regular);
    });
  });

  group('fold', () {
    test('no features means no fold and a flat pose', () {
      expect(foldOf(const []), isNull);
      expect(postureOf(const []), FoldPosture.flat);
    });

    test('a flat fold is a seamless display: present but not separating', () {
      final f = foldOf([_fold(const Rect.fromLTWH(390, 0, 0, 844))]);
      expect(f, isNotNull);
      expect(f!.separates, isFalse);
      expect(postureOf([_fold(const Rect.fromLTWH(390, 0, 0, 844))]), FoldPosture.flat);
    });

    test('a half-opened fold separates, and a tall seam is vertical', () {
      final features = [_fold(const Rect.fromLTWH(390, 0, 0, 844), state: DisplayFeatureState.postureHalfOpened)];
      final f = foldOf(features)!;
      expect(f.separates, isTrue);
      expect(f.vertical, isTrue, reason: 'splits into left and right panes');
      expect(postureOf(features), FoldPosture.halfOpened);
    });

    test('a hinge separates whatever the pose, and a wide seam is horizontal', () {
      final f = foldOf([_hinge(const Rect.fromLTWH(0, 500, 1340, 40))])!;
      expect(f.separates, isTrue);
      expect(f.vertical, isFalse, reason: 'splits into top and bottom panes');
    });
  });

  group('hitsFold', () {
    final fold = WindowFold(bounds: const Rect.fromLTWH(380, 0, 20, 844), separates: true, vertical: true);

    test('a rect over the seam hits it; one clear of it does not', () {
      expect(hitsFold(const Rect.fromLTWH(360, 700, 60, 60), fold), isTrue);
      expect(hitsFold(const Rect.fromLTWH(100, 700, 60, 60), fold), isFalse);
    });

    test('never hits a non-separating or absent fold', () {
      final flat = WindowFold(bounds: const Rect.fromLTWH(380, 0, 20, 844), separates: false, vertical: true);
      expect(hitsFold(const Rect.fromLTWH(360, 700, 60, 60), flat), isFalse);
      expect(hitsFold(const Rect.fromLTWH(360, 700, 60, 60), null), isFalse);
    });
  });

  group('panesAround', () {
    final area = const Rect.fromLTWH(0, 0, 800, 1000);

    test('a vertical seam splits into left and right, leaving its thickness empty', () {
      final fold = WindowFold(bounds: const Rect.fromLTWH(380, 0, 40, 1000), separates: true, vertical: true);
      final panes = panesAround(area, fold)!;
      expect(panes.$1, const Rect.fromLTRB(0, 0, 380, 1000));
      expect(panes.$2, const Rect.fromLTRB(420, 0, 800, 1000));
    });

    test('a horizontal seam splits into top and bottom', () {
      final fold = WindowFold(bounds: const Rect.fromLTWH(0, 480, 800, 40), separates: true, vertical: false);
      final panes = panesAround(area, fold)!;
      expect(panes.$1, const Rect.fromLTRB(0, 0, 800, 480));
      expect(panes.$2, const Rect.fromLTRB(0, 520, 800, 1000));
    });

    test('no panes for a non-separating fold, none at all, or one outside the area', () {
      final flat = WindowFold(bounds: const Rect.fromLTWH(380, 0, 40, 1000), separates: false, vertical: true);
      expect(panesAround(area, flat), isNull);
      expect(panesAround(area, null), isNull);
      final outside = WindowFold(bounds: const Rect.fromLTWH(0, 0, 0, 1000), separates: true, vertical: true);
      expect(panesAround(area, outside), isNull, reason: 'a seam at the very edge divides nothing');
    });
  });
}
