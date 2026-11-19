import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get_ride/src/data/active_location.dart';
import 'package:get_ride/src/data/shared_location.dart';

Position _at(double lat, double lng) => Position(
  latitude: lat,
  longitude: lng,
  timestamp: DateTime.utc(2026, 11, 19),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

/// The platform stream, faked: each open is recorded with its settings and is
/// a stream of its own, so a test sees when the hub closes and reopens it.
class _Platform {
  final opened = <LocationSettings>[];
  final sources = <StreamController<Position>>[];
  final closed = <int>[];

  Stream<Position> open(LocationSettings settings) {
    final index = opened.length;
    opened.add(settings);
    final source = StreamController<Position>(onCancel: () => closed.add(index));
    sources.add(source);
    return source.stream;
  }

  /// The stream now open.
  StreamController<Position> get live => sources.last;
}

Future<void> _settle() => pumpEventQueue();

Map<String, List<String>> _libLines() => {
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
    if (f.path.endsWith('.dart') && !f.path.endsWith('.g.dart')) f.path.replaceAll(r'\', '/'): f.readAsLinesSync(),
};

void main() {
  // What the app's own requests look like (lib/src/data/session_tracker.dart,
  // and the driver's map, online tracking and the taxi meter).
  const session = LocationSettings(accuracy: LocationAccuracy.medium, distanceFilter: 10);

  group('accuracyRank', () {
    test('coarsest to finest, reduced below everything', () {
      final ranked = [...LocationAccuracy.values]..sort((a, b) => accuracyRank(a).compareTo(accuracyRank(b)));
      expect(ranked, [
        LocationAccuracy.reduced,
        LocationAccuracy.lowest,
        LocationAccuracy.low,
        LocationAccuracy.medium,
        LocationAccuracy.high,
        LocationAccuracy.best,
        LocationAccuracy.bestForNavigation,
      ]);
    });
  });

  group('mergeLocationSettings', () {
    test('one request is passed through as it is', () {
      expect(identical(mergeLocationSettings([session]), session), isTrue);
    });

    test('plain requests: the finest accuracy and the smallest filter', () {
      final merged = mergeLocationSettings([
        session,
        const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 4),
      ]);
      expect(merged.runtimeType, LocationSettings);
      expect(merged.accuracy, LocationAccuracy.high);
      expect(merged.distanceFilter, 4);
    });

    test('iOS: the map gets navigation accuracy though the session tracker asked first', () {
      final map = mapFollowLocationSettings(platform: TargetPlatform.iOS, web: false);
      final merged = mergeLocationSettings([session, map]) as AppleSettings;
      expect(merged.accuracy, LocationAccuracy.bestForNavigation);
      expect(merged.distanceFilter, 0);
      expect(merged.activityType, ActivityType.automotiveNavigation);
      expect(merged.pauseLocationUpdatesAutomatically, isFalse);
      // The map is only followed while it is on screen: nothing in the background
      // until something that is live there asks for it.
      expect(merged.allowBackgroundLocationUpdates, isFalse);
      expect(merged.showBackgroundLocationIndicator, isFalse);
    });

    test('iOS: going online adds the background updates, the map keeps its accuracy', () {
      final map = mapFollowLocationSettings(platform: TargetPlatform.iOS, web: false);
      final online = activeLocationSettings(
        ActiveLocationUse.driverOnline,
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        platform: TargetPlatform.iOS,
        web: false,
      );
      final merged = mergeLocationSettings([session, map, online]) as AppleSettings;
      expect(merged.accuracy, LocationAccuracy.bestForNavigation);
      expect(merged.distanceFilter, 0);
      expect(merged.allowBackgroundLocationUpdates, isTrue);
      expect(merged.showBackgroundLocationIndicator, isTrue);
      expect(merged.activityType, ActivityType.automotiveNavigation);
    });

    test('iOS: the most specific activity wins; pausing only when every listener allows it', () {
      final walking = AppleSettings(
        accuracy: LocationAccuracy.high,
        activityType: ActivityType.fitness,
        pauseLocationUpdatesAutomatically: true,
        allowBackgroundLocationUpdates: false,
      );
      final rider = AppleSettings(
        accuracy: LocationAccuracy.medium,
        activityType: ActivityType.otherNavigation,
        pauseLocationUpdatesAutomatically: true,
        allowBackgroundLocationUpdates: false,
      );
      final both = mergeLocationSettings([walking, rider]) as AppleSettings;
      expect(both.activityType, ActivityType.otherNavigation);
      expect(both.pauseLocationUpdatesAutomatically, isTrue);
      // A plain request never pauses (the plugin leaves it off), so neither may the merge.
      final withPlain = mergeLocationSettings([walking, rider, session]) as AppleSettings;
      expect(withPlain.pauseLocationUpdatesAutomatically, isFalse);
    });

    test('Android: a fix a second for the map, and the notice of whoever needs the background', () {
      final map = mapFollowLocationSettings(platform: TargetPlatform.android, web: false) as AndroidSettings;
      expect(map.intervalDuration, const Duration(seconds: 1), reason: 'the plugin defaults to one fix every 5 s');
      expect(map.foregroundNotificationConfig, isNull, reason: 'the map is followed on screen only');

      final alone = mergeLocationSettings([session, map]) as AndroidSettings;
      expect(alone.accuracy, LocationAccuracy.bestForNavigation);
      expect(alone.distanceFilter, 0);
      expect(alone.intervalDuration, const Duration(seconds: 1));
      expect(alone.foregroundNotificationConfig, isNull);

      final online = activeLocationSettings(
        ActiveLocationUse.driverOnline,
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        platform: TargetPlatform.android,
        web: false,
      );
      final trip = activeLocationSettings(
        ActiveLocationUse.driverTrip,
        accuracy: LocationAccuracy.high,
        distanceFilter: 15,
        platform: TargetPlatform.android,
        web: false,
      );
      final merged = mergeLocationSettings([session, map, online, trip]) as AndroidSettings;
      expect(merged.intervalDuration, const Duration(seconds: 1));
      expect(merged.distanceFilter, 0);
      expect(merged.foregroundNotificationConfig?.notificationTitle, ActiveLocationUse.driverTrip.title,
          reason: 'the most recent listener says what is sharing the location');
    });

    test('Android: requests that name no interval keep the plugin default', () {
      final rider = activeLocationSettings(
        ActiveLocationUse.riderTrip,
        accuracy: LocationAccuracy.medium,
        platform: TargetPlatform.android,
        web: false,
      );
      final merged = mergeLocationSettings([session, rider]) as AndroidSettings;
      expect(merged.intervalDuration, androidDefaultInterval);
      // A driver online asks for one a second, and that is what runs.
      final online = activeLocationSettings(
        ActiveLocationUse.driverOnline,
        accuracy: LocationAccuracy.high,
        platform: TargetPlatform.android,
        web: false,
      );
      expect((mergeLocationSettings([session, rider, online]) as AndroidSettings).intervalDuration, driverFixInterval);
    });

    test('sameLocationSettings compares what the platform is asked for', () {
      final a = mapFollowLocationSettings(platform: TargetPlatform.iOS, web: false);
      final b = mapFollowLocationSettings(platform: TargetPlatform.iOS, web: false);
      expect(sameLocationSettings(a, b), isTrue);
      expect(sameLocationSettings(a, session), isFalse);
      expect(
        sameLocationSettings(session, const LocationSettings(accuracy: LocationAccuracy.medium, distanceFilter: 10)),
        isTrue,
      );
    });
  });

  test('metresBetweenCoordinates', () {
    expect(metresBetweenCoordinates(3.15, 101.71, 3.15, 101.71), 0);
    // 0.0001° of latitude is about 11.1 m.
    expect(metresBetweenCoordinates(3.15, 101.71, 3.1501, 101.71), closeTo(11.12, 0.05));
  });

  test('runsInBackground: iOS background updates, or the Android foreground service', () {
    expect(runsInBackground(session), isFalse);
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      expect(runsInBackground(mapFollowLocationSettings(platform: platform, web: false)), isFalse, reason: '$platform map');
      expect(
        runsInBackground(
          activeLocationSettings(
            ActiveLocationUse.driverOnline,
            accuracy: LocationAccuracy.high,
            platform: platform,
            web: false,
          ),
        ),
        isTrue,
        reason: '$platform online',
      );
    }
  });

  test('lifecycleInFront: on the screen, or only covered for a moment', () {
    expect(lifecycleInFront(null), isTrue, reason: 'just started');
    expect(lifecycleInFront(AppLifecycleState.resumed), isTrue);
    expect(lifecycleInFront(AppLifecycleState.inactive), isTrue, reason: 'a permission prompt, the notification shade');
    expect(lifecycleInFront(AppLifecycleState.hidden), isFalse);
    expect(lifecycleInFront(AppLifecycleState.paused), isFalse);
    expect(lifecycleInFront(AppLifecycleState.detached), isFalse);
  });

  // Neither platform lets an app start its location updates again from the
  // background, so the hub must not stop a stream that is keeping the app alive
  // there in order to reopen it.
  group('SharedLocation, while the app is away from the screen', () {
    late _Platform platform;
    late SharedLocation hub;
    var front = true;

    LocationSettings online(TargetPlatform on) => activeLocationSettings(
      ActiveLocationUse.driverOnline,
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
      platform: on,
      web: false,
    );
    LocationSettings trip(TargetPlatform on) => activeLocationSettings(
      ActiveLocationUse.driverTrip,
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 15,
      platform: on,
      web: false,
    );

    setUp(() {
      front = true;
      platform = _Platform();
      hub = SharedLocation(open: platform.open, inFront: () => front);
    });

    for (final on in [TargetPlatform.iOS, TargetPlatform.android]) {
      test('$on: a stream keeping the app alive is not restarted there; the change waits for the app', () async {
        // Online, in front: the stream runs with the background flags.
        final got = <Position>[];
        final onlineSub = hub.watch(online(on)).listen(got.add);
        await _settle();
        expect(platform.opened, hasLength(1));
        expect(runsInBackground(hub.running!), isTrue);

        // The driver switches to another app, and something there needs more.
        front = false;
        final tripFixes = <Position>[];
        final tripSub = hub.watch(trip(on)).listen(tripFixes.add);
        await _settle();
        expect(platform.opened, hasLength(1), reason: 'not reopened from the background');
        expect(platform.closed, isEmpty, reason: 'and never stopped');
        // It is still served, by the stream that is running.
        platform.live.add(_at(3.15, 101.71));
        await _settle();
        expect(got, hasLength(1));
        expect(tripFixes, hasLength(1));

        // Back in front: now it is brought up to what is being asked for.
        front = true;
        hub.appCameToFront();
        await _settle();
        expect(platform.closed, [0]);
        expect(platform.opened, hasLength(2));
        expect(platform.opened.last.accuracy, LocationAccuracy.bestForNavigation);
        expect(runsInBackground(platform.opened.last), isTrue);

        // Nothing more is owed: coming to the front again changes nothing.
        hub.appCameToFront();
        await _settle();
        expect(platform.opened, hasLength(2));

        await onlineSub.cancel();
        await tripSub.cancel();
      });

      test('$on: when nothing needs the background any more, it is let go at once', () async {
        final sessionSub = hub.watch(session).listen((_) {});
        final onlineSub = hub.watch(online(on)).listen((_) {});
        await _settle();
        expect(runsInBackground(hub.running!), isTrue);
        final before = platform.opened.length;

        // Away, the driver is taken offline: only the session tracker is left.
        front = false;
        await onlineSub.cancel();
        await _settle();
        expect(platform.opened, hasLength(before + 1));
        expect(runsInBackground(platform.opened.last), isFalse, reason: 'no indicator or notice left behind');
        expect(sameLocationSettings(platform.opened.last, session), isTrue);

        // It was started from the background, where the platform may not have
        // let it: opened afresh in front, once.
        front = true;
        hub.appCameToFront();
        await _settle();
        expect(platform.opened, hasLength(before + 2));
        expect(sameLocationSettings(platform.opened.last, session), isTrue);
        hub.appCameToFront();
        await _settle();
        expect(platform.opened, hasLength(before + 2));

        await sessionSub.cancel();
      });
    }

    test('in front, a change is applied straight away', () async {
      final onlineSub = hub.watch(online(TargetPlatform.iOS)).listen((_) {});
      await _settle();
      final tripSub = hub.watch(trip(TargetPlatform.iOS)).listen((_) {});
      await _settle();
      expect(platform.opened, hasLength(2));
      expect(platform.opened.last.accuracy, LocationAccuracy.bestForNavigation);
      await onlineSub.cancel();
      await tripSub.cancel();
    });

    test('the last listener leaving closes the stream wherever the app is', () async {
      final onlineSub = hub.watch(online(TargetPlatform.android)).listen((_) {});
      await _settle();
      front = false;
      await onlineSub.cancel();
      await _settle();
      expect(platform.closed, [0]);
      expect(hub.running, isNull);
    });
  });

  group('SharedLocation', () {
    late _Platform platform;
    late SharedLocation hub;

    setUp(() {
      platform = _Platform();
      hub = SharedLocation(open: platform.open);
    });

    test('opens with the first listener at what it asked for, closes with the last', () async {
      expect(hub.running, isNull);
      final sub = hub.watch(session).listen((_) {});
      await _settle();
      expect(platform.opened, hasLength(1));
      expect(identical(platform.opened.single, session), isTrue);
      expect(hub.listeners, 1);

      await sub.cancel();
      await _settle();
      expect(platform.closed, [0]);
      expect(hub.running, isNull);
      expect(hub.listeners, 0);
    });

    test('a listener that needs more reopens the stream — the first one no longer decides for everybody', () async {
      // The session tracker listens from sign-in on...
      final coarse = <Position>[];
      final sessionSub = hub.watch(session).listen(coarse.add);
      await _settle();
      // ...and then the driver's map asks for navigation accuracy.
      final map = mapFollowLocationSettings(platform: TargetPlatform.iOS, web: false);
      final fine = <Position>[];
      final mapSub = hub.watch(map).listen(fine.add);
      await _settle();

      expect(platform.closed, [0], reason: 'the coarse stream is closed before the better one opens');
      expect(platform.opened, hasLength(2));
      final running = platform.opened.last as AppleSettings;
      expect(running.accuracy, LocationAccuracy.bestForNavigation);
      expect(running.distanceFilter, 0);
      expect(sameLocationSettings(hub.running!, running), isTrue);

      // Both get fixes from the one stream; the session tracker still only every 10 m.
      platform.live.add(_at(3.1500, 101.7100));
      platform.live.add(_at(3.15002, 101.7100)); // ~2 m on
      platform.live.add(_at(3.15005, 101.7100)); // ~5.6 m from the first
      platform.live.add(_at(3.15012, 101.7100)); // ~13 m from the first
      await _settle();
      expect(fine, hasLength(4), reason: 'the map takes every fix');
      expect(coarse.map((p) => p.latitude), [3.1500, 3.15012], reason: 'its own 10 m filter, applied by the hub');

      // The map leaves: back to what the session tracker asked for.
      await mapSub.cancel();
      await _settle();
      expect(platform.opened, hasLength(3));
      expect(sameLocationSettings(platform.opened.last, session), isTrue);
      expect(platform.closed, [0, 1]);

      await sessionSub.cancel();
      await _settle();
      expect(platform.closed, [0, 1, 2]);
    });

    test('a listener that needs nothing more leaves the stream as it is', () async {
      final map = mapFollowLocationSettings(platform: TargetPlatform.iOS, web: false);
      final mapSub = hub.watch(map).listen((_) {});
      await _settle();
      // Asks for less than is already running, with nothing platform-specific of its own.
      final got = <Position>[];
      final headingSub = hub
          .watch(mapFollowLocationSettings(platform: TargetPlatform.iOS, web: false))
          .listen(got.add);
      await _settle();
      expect(platform.opened, hasLength(1), reason: 'the same need: not reopened');

      platform.live.add(_at(3.15, 101.71));
      await _settle();
      expect(got, hasLength(1));

      await headingSub.cancel();
      await _settle();
      expect(platform.opened, hasLength(1));
      expect(platform.closed, isEmpty);
      await mapSub.cancel();
    });

    test('listeners coming and going at once settle on what is left', () async {
      final a = hub.watch(session).listen((_) {});
      final map = mapFollowLocationSettings(platform: TargetPlatform.android, web: false);
      final b = hub.watch(map).listen((_) {});
      unawaited(a.cancel());
      await _settle();
      expect(hub.listeners, 1);
      expect(sameLocationSettings(hub.running!, map), isTrue);
      expect(sameLocationSettings(platform.opened.last, map), isTrue);
      await b.cancel();
      await _settle();
      expect(hub.running, isNull);
      expect(platform.closed, hasLength(platform.opened.length), reason: 'every stream opened was closed');
    });

    test('an error from the platform reaches every listener', () async {
      final errors = <Object>[];
      final a = hub.watch(session).listen((_) {}, onError: errors.add);
      final b = hub.watch(const LocationSettings(accuracy: LocationAccuracy.high)).listen((_) {}, onError: errors.add);
      await _settle();
      platform.live.addError(const LocationServiceDisabledException());
      await _settle();
      expect(errors, hasLength(2));
      await a.cancel();
      await b.cancel();
    });

    test('when the platform ends the stream, the listeners end too', () async {
      var done = false;
      hub.watch(session).listen((_) {}, onDone: () => done = true);
      await _settle();
      await platform.live.close();
      await _settle();
      expect(done, isTrue);
      expect(hub.listeners, 0);
      expect(hub.running, isNull);
    });
  });

  test('only the hub listens to the platform position stream', () {
    // The plugin keeps one stream and ignores the settings of every caller but
    // the first, so a second direct listener would again decide (or be denied)
    // the accuracy for the whole app.
    final direct = RegExp(r'\bgetPositionStream\s*\(');
    final offenders = <String>[];
    _libLines().forEach((path, lines) {
      if (path.endsWith('data/shared_location.dart')) return;
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (direct.hasMatch(lines[i])) offenders.add('$path:${i + 1}');
      }
    });
    expect(offenders, isEmpty, reason: 'use sharedPositionStream (lib/src/data/shared_location.dart)');
  });
}
