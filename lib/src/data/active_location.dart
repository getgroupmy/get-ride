// Location that keeps running while the app is in the background, for the
// things that are live while the phone is in a pocket or another app is in
// front: a driver online for requests, a trip in progress on either side, and
// the taxi meter.
//
// Android keeps the GPS on through a foreground service, which must show a
// notification while it runs (it says what is sharing the location); iOS
// keeps it on through the `location` background mode (Info.plist), with the
// blue status-bar indicator. Without these both platforms stop the stream a
// few seconds after the app leaves the screen.
library;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// What the location is for: what the Android notification says.
enum ActiveLocationUse {
  driverOnline('You are online', 'Sharing your location so riders nearby can find you.'),
  driverTrip('Trip in progress', 'Sharing your location with your passenger.'),
  riderTrip('Your driver is on the way', 'Sharing your location with your driver.'),
  meter('Meter Digital is running', 'Measuring the trip for the fare.');

  const ActiveLocationUse(this.title, this.text);
  final String title;
  final String text;
}

/// The location settings for [use] on this platform, keeping the stream
/// alive in the background.
LocationSettings activeLocationSettings(
  ActiveLocationUse use, {
  required LocationAccuracy accuracy,
  int distanceFilter = 0,
  TargetPlatform? platform,
  bool? web,
}) {
  if (web ?? kIsWeb) return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.android:
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: use.title,
          notificationText: use.text,
          notificationChannelName: 'Live location',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return AppleSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        activityType: use == ActiveLocationUse.riderTrip
            ? ActivityType.otherNavigation
            : ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    default:
      return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
  }
}
