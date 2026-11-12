import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/battery_reliability.dart';

void main() {
  group('shouldNudgeBatteryExemption', () {
    test('nudges on Android when armed, restricted and not shown before', () {
      expect(
        shouldNudgeBatteryExemption(android: true, armed: true, unrestricted: false, alreadyNudged: false),
        isTrue,
      );
    });

    test('never on iOS / web (not Android)', () {
      expect(
        shouldNudgeBatteryExemption(android: false, armed: true, unrestricted: false, alreadyNudged: false),
        isFalse,
      );
    });

    test('not when the reporter is not armed (nudge would be irrelevant)', () {
      expect(
        shouldNudgeBatteryExemption(android: true, armed: false, unrestricted: false, alreadyNudged: false),
        isFalse,
      );
    });

    test('not when the phone already lets the app run unrestricted', () {
      expect(
        shouldNudgeBatteryExemption(android: true, armed: true, unrestricted: true, alreadyNudged: false),
        isFalse,
      );
    });

    test('only once — not after it has been shown', () {
      expect(
        shouldNudgeBatteryExemption(android: true, armed: true, unrestricted: false, alreadyNudged: true),
        isFalse,
      );
    });
  });

  test('BatteryReliability is a no-op off Android (reports unrestricted)', () async {
    const b = BatteryReliability(supportedOverride: false);
    expect(b.supported, isFalse);
    expect(await b.unrestricted(), isTrue); // never nags where there is no such setting
  });
}
