import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/request_alert.dart' show requestAlertWindow;
import 'package:get_ride/src/data/offer_alert_sound.dart';

void main() {
  group('offerAlertRingFor', () {
    test('0 seconds is silence', () {
      expect(offerAlertRingFor(alertSoundSeconds: 0, spotlight: requestAlertWindow), Duration.zero);
    });

    test('negative is silence', () {
      expect(offerAlertRingFor(alertSoundSeconds: -3, spotlight: requestAlertWindow), Duration.zero);
    });

    test('rings for the admin length when within the spotlight', () {
      expect(
        offerAlertRingFor(alertSoundSeconds: 10, spotlight: const Duration(seconds: 35)),
        const Duration(seconds: 10),
      );
    });

    test('never outlasts the spotlight window', () {
      // Admin asked for 60s but the request is only spotlighted for 35s.
      expect(
        offerAlertRingFor(alertSoundSeconds: 60, spotlight: const Duration(seconds: 35)),
        const Duration(seconds: 35),
      );
    });

    test('a zero spotlight rings nothing', () {
      expect(offerAlertRingFor(alertSoundSeconds: 20, spotlight: Duration.zero), Duration.zero);
    });
  });
}
