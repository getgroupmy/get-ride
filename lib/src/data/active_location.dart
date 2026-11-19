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

/// How often Android is asked for a fix while someone is driving: as often as
/// a phone's GPS gives them, and as often as iOS does without being asked.
const driverFixInterval = Duration(seconds: 1);

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
        // A fix a second for whoever is driving. The plugin's own default is
        // one every five seconds, which draws a moving car in jumps and
        // measures a bend as the straight line across it (the meter's fare, the
        // trip's distance). The passenger's phone, which is only being found,
        // keeps the default.
        intervalDuration: use == ActiveLocationUse.riderTrip ? null : driverFixInterval,
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

/// The location settings for a map that follows the driver while it is on
/// screen, the way a navigation app does: the best fix the phone can give
/// (iOS's navigation accuracy, with its sensor fusion and the automotive
/// activity type), every fix rather than every few metres, and one a second on
/// Android, whose plugin otherwise asks for one every five.
///
/// Nothing here keeps running in the background: that is
/// [activeLocationSettings]'s job, for what is live while the phone is in a
/// pocket (online, a trip, the meter). The shared stream
/// (shared_location.dart) runs at the strongest of whatever is being asked
/// for, so a map on screen never lowers those, and they never coarsen it.
LocationSettings mapFollowLocationSettings({TargetPlatform? platform, bool? web}) {
  const accuracy = LocationAccuracy.bestForNavigation;
  if (web ?? kIsWeb) return const LocationSettings(accuracy: accuracy);
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.android:
      return AndroidSettings(accuracy: accuracy, intervalDuration: driverFixInterval);
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return AppleSettings(
        accuracy: accuracy,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: false,
        showBackgroundLocationIndicator: false,
      );
    default:
      return const LocationSettings(accuracy: accuracy);
  }
}
