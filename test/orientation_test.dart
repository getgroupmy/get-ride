import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/orientation.dart';

void main() {
  const portrait = [DeviceOrientation.portraitUp];

  group('appDefaultOrientations', () {
    test('iPhone Duo portrait (466x678) is portrait-only', () {
      expect(appDefaultOrientations(466, 678, web: false), portrait);
    });

    test('iPhone Duo held sideways (956x440) stays portrait-only — a phone, not a tablet', () {
      // Its shortest side (440) is under the 600 tablet line, so landscape is
      // still blocked however the device is turned.
      expect(appDefaultOrientations(956, 440, web: false), portrait);
    });

    test('an ordinary phone is portrait-only in either orientation', () {
      expect(appDefaultOrientations(390, 844, web: false), portrait);
      expect(appDefaultOrientations(844, 390, web: false), portrait);
    });

    test('a tablet (shortest side >= 600) keeps every orientation', () {
      expect(appDefaultOrientations(834, 1112, web: false), DeviceOrientation.values);
      expect(appDefaultOrientations(1112, 834, web: false), DeviceOrientation.values);
      // Exactly on the line counts as a tablet.
      expect(appDefaultOrientations(600, 960, web: false), DeviceOrientation.values);
    });

    test('web uses the wider 768 line', () {
      expect(appDefaultOrientations(700, 1024, web: true), portrait); // 700 < 768
      expect(appDefaultOrientations(800, 1024, web: true), DeviceOrientation.values); // 800 >= 768
    });
  });
}
