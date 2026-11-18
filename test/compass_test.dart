import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/compass.dart';

void main() {
  group('angleGap', () {
    test('the short way round, across the wrap', () {
      expect(angleGap(10, 20), 10);
      expect(angleGap(20, 10), 10);
      expect(angleGap(350, 10), 20);
      expect(angleGap(10, 350), 20);
      expect(angleGap(0, 180), 180);
      expect(angleGap(0, 181), 179);
      expect(angleGap(90, 270), 180);
    });
  });

  group('nextHeading', () {
    test('drops nothing-readings', () {
      expect(nextHeading(null, null), isNull);
      expect(nextHeading(double.nan, null), isNull);
      expect(nextHeading(-1, null), isNull, reason: 'iOS sends -1 when the heading is unknown');
    });
    test('normalises into 0–360', () {
      expect(nextHeading(370, null), 10);
      expect(nextHeading(0, null), 0);
    });
    test('holds back a turn smaller than the step', () {
      expect(nextHeading(30, null), 30, reason: 'the first reading always emits');
      expect(nextHeading(31, 30), isNull, reason: '1° < step');
      expect(nextHeading(34, 30), 34, reason: '4° >= step');
      // Across the wrap, a tiny turn is still tiny.
      expect(nextHeading(1, 359), isNull);
      expect(nextHeading(5, 359), 5);
    });
  });
}
