import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/duo_fold.dart';
import 'package:get_ride/src/core/window_class.dart';

void main() {
  group('duoFoldFromNative', () {
    test('parses a dividing crease', () {
      final s = duoFoldFromNative({
        'hinge': 'partiallyOpen',
        'angle': 120.0,
        'division': {'x': 456, 'y': 0, 'w': 14, 'h': 669},
        'divisionActive': true,
        'occlusions': [
          {'x': 220, 'y': 0, 'w': 30, 'h': 20},
        ],
      });
      expect(s.hinge, DuoHinge.partiallyOpen);
      expect(s.angleDegrees, 120);
      expect(s.division, const Rect.fromLTWH(456, 0, 14, 669));
      expect(s.separates, isTrue);
      expect(s.occlusions.single, const Rect.fromLTWH(220, 0, 30, 20));
    });

    test('an inactive crease does not divide', () {
      final s = duoFoldFromNative({
        'hinge': 'fullyOpen',
        'division': {'x': 0, 'y': 0, 'w': 14, 'h': 669},
        'divisionActive': false,
      });
      expect(s.separates, isFalse);
    });

    test('a malformed or empty message is no hinge', () {
      expect(duoFoldFromNative(null).hinge, DuoHinge.none);
      expect(duoFoldFromNative(const {}).hinge, DuoHinge.unknown);
      expect(duoFoldFromNative({'hinge': 'closed', 'division': 'nonsense'}).division, isNull);
    });
  });

  group('displayFeatureFor', () {
    test('a dividing crease becomes a half-opened fold feature', () {
      final f = displayFeatureFor(duoFoldFromNative({
        'hinge': 'partiallyOpen',
        'division': {'x': 456, 'y': 0, 'w': 14, 'h': 669},
        'divisionActive': true,
      }));
      expect(f, isNotNull);
      expect(f!.type, DisplayFeatureType.fold);
      expect(f.state, DisplayFeatureState.postureHalfOpened);
      expect(f.bounds, const Rect.fromLTWH(456, 0, 14, 669));
    });

    test('no feature without a dividing crease', () {
      expect(displayFeatureFor(const DuoFoldSignal(hinge: DuoHinge.closed)), isNull);
      expect(
        displayFeatureFor(duoFoldFromNative({
          'hinge': 'fullyOpen',
          'division': {'x': 0, 'y': 0, 'w': 14, 'h': 669},
          'divisionActive': false,
        })),
        isNull,
      );
    });

    test('the feature flows through window_class as a separating fold', () {
      // End to end: a native signal → a feature → the same metrics the layout
      // reads, now reporting a separating vertical fold.
      final f = displayFeatureFor(simulatedBookFold(const Size(1000, 1200)))!;
      final m = windowMetricsOf(const Size(1000, 1200), [f]);
      expect(m.hasSeparatingFold, isTrue);
      expect(m.fold!.vertical, isTrue);
      expect(verticalSplitFor(m), isNotNull);
    });
  });

  group('mergeFoldFeatures', () {
    final synth = DisplayFeature(
      bounds: const Rect.fromLTWH(456, 0, 14, 669),
      type: DisplayFeatureType.fold,
      state: DisplayFeatureState.postureHalfOpened,
    );

    test('adds the synthesized fold when the platform reports none', () {
      expect(mergeFoldFeatures(const [], synth), [synth]);
    });

    test('keeps the platform fold and ignores the synthesized one (no doubling)', () {
      final real = DisplayFeature(
        bounds: const Rect.fromLTWH(0, 500, 1340, 40),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      );
      expect(mergeFoldFeatures([real], synth), [real]);
    });

    test('null synthesized is a no-op', () {
      expect(mergeFoldFeatures(const [], null), const []);
    });
  });

  group('simulated poses', () {
    test('book fold is a centred vertical seam', () {
      final s = simulatedBookFold(const Size(1000, 1200));
      expect(s.separates, isTrue);
      expect(s.division, const Rect.fromLTWH(493, 0, 14, 1200));
    });

    test('tabletop fold is a centred horizontal seam', () {
      final s = simulatedTabletopFold(const Size(1000, 1200));
      expect(s.division, const Rect.fromLTWH(0, 593, 1000, 14));
      final f = displayFeatureFor(s)!;
      expect(windowMetricsOf(const Size(1000, 1200), [f]).fold!.vertical, isFalse);
    });
  });
}
