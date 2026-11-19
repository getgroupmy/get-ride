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

  test('Android: a fix a second for whoever is driving, the plugin default for a passenger', () {
    AndroidSettings on(ActiveLocationUse use) =>
        activeLocationSettings(use, accuracy: LocationAccuracy.high, platform: TargetPlatform.android, web: false)
            as AndroidSettings;
    for (final use in [ActiveLocationUse.driverOnline, ActiveLocationUse.driverTrip, ActiveLocationUse.meter]) {
      expect(on(use).intervalDuration, driverFixInterval, reason: '$use (the plugin would ask for one every 5 s)');
    }
    expect(driverFixInterval, const Duration(seconds: 1));
    expect(on(ActiveLocationUse.riderTrip).intervalDuration, isNull);
    final map = mapFollowLocationSettings(platform: TargetPlatform.android, web: false) as AndroidSettings;
    expect(map.intervalDuration, driverFixInterval);
    expect(map.accuracy, LocationAccuracy.bestForNavigation);
    expect(map.foregroundNotificationConfig, isNull, reason: 'a map on screen keeps nothing running in the background');
  });

  test('iOS: the map asks for navigation accuracy, and for nothing in the background', () {
    final map = mapFollowLocationSettings(platform: TargetPlatform.iOS, web: false) as AppleSettings;
    expect(map.accuracy, LocationAccuracy.bestForNavigation);
    expect(map.distanceFilter, 0, reason: 'every fix, not one every few metres');
    expect(map.activityType, ActivityType.automotiveNavigation);
    expect(map.pauseLocationUpdatesAutomatically, isFalse);
    expect(map.allowBackgroundLocationUpdates, isFalse);
    expect(map.showBackgroundLocationIndicator, isFalse);
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
