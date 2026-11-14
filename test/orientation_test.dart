import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
  });
}
