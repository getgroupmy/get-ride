import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get_ride/src/data/active_location.dart';

void main() {
  test('Android keeps live location on through a foreground service that says why', () {
    final s = activeLocationSettings(
      ActiveLocationUse.driverTrip,
      accuracy: LocationAccuracy.high,
      distanceFilter: 15,
      platform: TargetPlatform.android,
      web: false,
    );
    expect(s, isA<AndroidSettings>());
    final a = s as AndroidSettings;
    expect(a.distanceFilter, 15);
    expect(a.foregroundNotificationConfig?.notificationText, 'Sharing your location with your passenger.');
    expect(a.foregroundNotificationConfig?.setOngoing, isTrue);
  });

  test('iOS keeps it on in the background, with the status-bar indicator', () {
    final s = activeLocationSettings(
      ActiveLocationUse.meter,
      accuracy: LocationAccuracy.bestForNavigation,
      platform: TargetPlatform.iOS,
      web: false,
    );
    expect(s, isA<AppleSettings>());
    final a = s as AppleSettings;
    expect(a.allowBackgroundLocationUpdates, isTrue);
    expect(a.pauseLocationUpdatesAutomatically, isFalse);
    expect(a.showBackgroundLocationIndicator, isTrue);
  });

  test('the web has no background: plain settings', () {
    final s = activeLocationSettings(ActiveLocationUse.riderTrip, accuracy: LocationAccuracy.medium, web: true);
    expect(s, isNot(isA<AndroidSettings>()));
    expect(s, isNot(isA<AppleSettings>()));
  });

  test('every use says what it is sharing for', () {
    for (final u in ActiveLocationUse.values) {
      expect(u.title, isNotEmpty);
      expect(u.text, isNotEmpty);
    }
  });
}
