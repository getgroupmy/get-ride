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

  group('courseWhenMoving', () {
    test('uses the GPS course only when moving fast enough', () {
      expect(courseWhenMoving(90, 10), 90, reason: 'driving: the course is the travel direction');
      expect(courseWhenMoving(90, 0), isNull, reason: 'parked: the course is random, use the compass');
      expect(courseWhenMoving(90, movingSpeed - 0.1), isNull, reason: 'crawling: below the threshold');
      expect(courseWhenMoving(90, movingSpeed), 90, reason: 'at the threshold');
    });
    test('drops an unknown or invalid course', () {
      expect(courseWhenMoving(null, 10), isNull);
      expect(courseWhenMoving(-1, 10), isNull, reason: 'iOS sends -1 when the course is unknown');
      expect(courseWhenMoving(double.nan, 10), isNull);
      expect(courseWhenMoving(90, null), isNull);
    });
    test('normalises into 0–360', () {
      expect(courseWhenMoving(370, 10), 10);
    });
  });

  group('holdCourse', () {
    test('holds the last travel course until it goes stale', () {
      // No course seen yet: nothing to hold, so the compass is used.
      expect(holdCourse(null, 1000), isFalse);
      // A course seen just now is held.
      expect(holdCourse(1000, 1000), isTrue, reason: 'same instant');
      expect(holdCourse(1000, 1000 + courseHoldMs - 1), isTrue, reason: 'within the window');
      // Once the window lapses the course is stale and the compass takes over.
      expect(holdCourse(1000, 1000 + courseHoldMs), isFalse, reason: 'at the edge');
      expect(holdCourse(1000, 1000 + courseHoldMs + 1), isFalse, reason: 'past the window');
    });
    test('respects an overridden hold window', () {
      expect(holdCourse(0, 500, holdMs: 1000), isTrue);
      expect(holdCourse(0, 1500, holdMs: 1000), isFalse);
    });
  });

  group('preferredHeading', () {
    test('travel direction while moving, the compass while stopped', () {
      expect(preferredHeading(90, 200), 90, reason: 'course wins when it is known (moving)');
      expect(preferredHeading(null, 200), 200, reason: 'fall back to the compass when stopped');
      expect(preferredHeading(null, null), isNull);
    });
  });
}
