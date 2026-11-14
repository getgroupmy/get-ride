import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/duo_fold.dart' show DuoHinge;
import 'package:get_ride/src/core/orientation.dart';

void main() {
  const portrait = [DeviceOrientation.portraitUp];

  group('appDefaultOrientations', () {
    test('iPhone Duo folded cover (466x678 / 678x466, shortest 466) is portrait only', () {
      expect(appDefaultOrientations(466, 678, web: false), portrait);
      expect(appDefaultOrientations(678, 466, web: false), portrait); // caught before it could rotate
    });

    test('iPhone Duo unfolded inner (951x669 / 669x951, shortest 669) rotates freely', () {
      expect(appDefaultOrientations(951, 669, web: false), DeviceOrientation.values);
      expect(appDefaultOrientations(669, 951, web: false), DeviceOrientation.values);
    });

    test('an ordinary phone is portrait only in either orientation', () {
      expect(appDefaultOrientations(390, 844, web: false), portrait);
      expect(appDefaultOrientations(844, 390, web: false), portrait);
    });

    test('a tablet (shortest side >= 600) rotates freely', () {
      expect(appDefaultOrientations(834, 1112, web: false), DeviceOrientation.values);
      expect(appDefaultOrientations(600, 960, web: false), DeviceOrientation.values); // on the line
    });

    test('the split sits between the Duo cover (shortest 466) and inner (shortest 669)', () {
      // The whole rule set reduces to this one line crossing 600 on the
      // shortest side (rotation-invariant).
      expect(appDefaultOrientations(466, 678, web: false), portrait);
      expect(appDefaultOrientations(669, 951, web: false), DeviceOrientation.values);
    });

    test('web uses the wider 768 line', () {
      expect(appDefaultOrientations(700, 1024, web: true), portrait);
      expect(appDefaultOrientations(800, 1024, web: true), DeviceOrientation.values);
    });

    test('no/unknown hinge falls back to the size rule (every non-Duo device)', () {
      expect(appDefaultOrientations(390, 844, web: false, hinge: DuoHinge.none), portrait);
      expect(appDefaultOrientations(834, 1112, web: false, hinge: DuoHinge.none), DeviceOrientation.values);
      expect(appDefaultOrientations(390, 844, web: false, hinge: DuoHinge.unknown), portrait);
    });
  });

  group('the Duo hinge pose overrides the size rule (breaks the deadlock)', () {
    test('the unfolded inner display rotates even while the window is still cover-sized', () {
      // The bug: opening on the folded cover pins portrait, which can keep iOS
      // from ever handing over the inner display's larger size. The hinge pose
      // arrives first, so an open hinge unlocks rotation on the frozen size.
      expect(appDefaultOrientations(466, 678, web: false, hinge: DuoHinge.fullyOpen), DeviceOrientation.values);
      expect(appDefaultOrientations(466, 678, web: false, hinge: DuoHinge.partiallyOpen), DeviceOrientation.values);
    });

    test('the folded cover stays portrait even while the window is still inner-sized', () {
      expect(appDefaultOrientations(951, 669, web: false, hinge: DuoHinge.closed), [DeviceOrientation.portraitUp]);
    });
  });
}
