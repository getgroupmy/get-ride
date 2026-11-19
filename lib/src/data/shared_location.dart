// One position stream for the whole app.
//
// The geolocator plugin keeps a single platform position stream. While anything
// is listening to it, a later `Geolocator.getPositionStream(settings)` hands
// back that same stream and ignores its settings (geolocator_apple and
// geolocator_android both start with `if (_positionStream != null) return it`).
// So whoever listened first decided the accuracy for everybody. That was the
// session tracker, which starts at sign-in and asks for 100 m accuracy and a
// fix every 10 m: the driver's map, the trip screen and the taxi meter all
// asked for far better, and none of them ever got it — nor the background
// flags they asked for, so their streams stopped when the app left the screen.
//
// Everything that wants positions asks here instead. The hub is the plugin
// stream's only listener: it runs it at the strongest of what is being asked
// for (finest accuracy, smallest distance filter, the background flags when
// someone needs them), reopens it when that changes, and gives each listener
// no more fixes than its own distance filter asks for.
//
// Reopening means stopping the platform's updates and starting them again,
// and neither platform lets an app start them from the background: iOS gives
// nothing to an app that starts location while it is not in use, and stops the
// app with it; Android 12 and later refuse to put the location service back in
// the foreground. So while the app is away from the screen, a stream that is
// keeping it alive there is left exactly as it is, and what the listeners need
// is applied when the app is back in front (see [SharedLocation.appCameToFront]).
//
// `test/shared_location_test.dart` fails when anything else in lib/ calls
// `getPositionStream`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';

/// How demanding an accuracy is, coarsest first. ([LocationAccuracy.reduced]
/// comes last in the enum but is the coarsest there is.)
int accuracyRank(LocationAccuracy accuracy) => switch (accuracy) {
  LocationAccuracy.reduced => 0,
  LocationAccuracy.lowest => 1,
  LocationAccuracy.low => 2,
  LocationAccuracy.medium => 3,
  LocationAccuracy.high => 4,
  LocationAccuracy.best => 5,
  LocationAccuracy.bestForNavigation => 6,
};

/// How much an iOS activity type asks of the location manager, least first:
/// the hub tells iOS the most specific one any listener gave.
int _activityRank(ActivityType type) => switch (type) {
  ActivityType.other => 0,
  ActivityType.airborne => 1,
  ActivityType.fitness => 2,
  ActivityType.otherNavigation => 3,
  ActivityType.automotiveNavigation => 4,
};

/// The interval Android is asked for when a request names none (the plugin's
/// own default: `LocationOptions.java`).
const androidDefaultInterval = Duration(seconds: 5);

/// The one set of settings that satisfies every request in [wants]: the finest
/// accuracy and the smallest distance filter among them, and, where any of
/// them is platform-specific, that platform's settings with whatever any of
/// them needs — background updates and their indicator on iOS, the foreground
/// notification and the shortest interval on Android. A single request is
/// passed through untouched. Pure; see test/shared_location_test.dart.
///
/// The requests are in the order their listeners arrived, so the Android
/// notification is the most recent listener's: the screen on top says what is
/// sharing the location.
LocationSettings mergeLocationSettings(List<LocationSettings> wants) {
  assert(wants.isNotEmpty, 'nothing to merge');
  if (wants.length == 1) return wants.single;
  var accuracy = wants.first.accuracy;
  var filter = wants.first.distanceFilter;
  for (final want in wants.skip(1)) {
    if (accuracyRank(want.accuracy) > accuracyRank(accuracy)) accuracy = want.accuracy;
    filter = math.min(filter, want.distanceFilter);
  }
  final apple = wants.whereType<AppleSettings>().toList();
  if (apple.isNotEmpty) {
    return AppleSettings(
      accuracy: accuracy,
      distanceFilter: filter,
      // iOS may pause the updates only when every listener is content with
      // that; a plain request never is (the plugin leaves pausing off for it).
      pauseLocationUpdatesAutomatically:
          apple.length == wants.length && apple.every((a) => a.pauseLocationUpdatesAutomatically),
      activityType: apple
          .map((a) => a.activityType)
          .reduce((a, b) => _activityRank(b) > _activityRank(a) ? b : a),
      showBackgroundLocationIndicator: apple.any((a) => a.showBackgroundLocationIndicator),
      allowBackgroundLocationUpdates: apple.any((a) => a.allowBackgroundLocationUpdates),
    );
  }
  final android = wants.whereType<AndroidSettings>().toList();
  if (android.isNotEmpty) {
    var interval = androidDefaultInterval;
    for (final want in wants) {
      final asked = want is AndroidSettings ? want.intervalDuration ?? androidDefaultInterval : androidDefaultInterval;
      if (asked < interval) interval = asked;
    }
    ForegroundNotificationConfig? notice;
    for (final a in android) {
      notice = a.foregroundNotificationConfig ?? notice;
    }
    return AndroidSettings(
      accuracy: accuracy,
      distanceFilter: filter,
      forceLocationManager: android.any((a) => a.forceLocationManager),
      intervalDuration: interval,
      foregroundNotificationConfig: notice,
      useMSLAltitude: android.any((a) => a.useMSLAltitude),
    );
  }
  return LocationSettings(accuracy: accuracy, distanceFilter: filter);
}

/// Whether [a] and [b] ask the platform for the same thing, so the stream can
/// stay as it is. Pure.
bool sameLocationSettings(LocationSettings a, LocationSettings b) => jsonEncode(a.toJson()) == jsonEncode(b.toJson());

/// Whether a stream with [settings] goes on while the app is away from the
/// screen: iOS background updates, or Android's foreground service (which is
/// what its notification is for). Pure.
bool runsInBackground(LocationSettings settings) =>
    (settings is AppleSettings && settings.allowBackgroundLocationUpdates) ||
    (settings is AndroidSettings && settings.foregroundNotificationConfig != null);

/// Whether the app is in front in lifecycle [state]: on the screen, or behind
/// something that only covers it for a moment (a permission prompt, the
/// notification shade). Unknown counts as in front: an app that has just
/// started. Pure.
bool lifecycleInFront(AppLifecycleState? state) =>
    state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

/// Metres between two coordinates (haversine). Pure.
double metresBetweenCoordinates(double lat1, double lng1, double lat2, double lng2) {
  double rad(double degrees) => degrees * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
  final h =
      math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * 6371000 * math.asin(math.min(1, math.sqrt(h)));
}

/// Opens the platform's position stream. A seam for tests.
typedef PositionOpener = Stream<Position> Function(LocationSettings settings);

/// One listener of the hub: what it asked for, and where its fixes go.
class _Listener {
  _Listener(this.settings);

  final LocationSettings settings;
  late final StreamController<Position> out;
  Position? _last;

  /// Whether [fix] is far enough from the last one this listener was given:
  /// its own distance filter, applied here because the platform stream runs
  /// at the smallest filter anyone asked for.
  bool takes(Position fix) {
    final gap = settings.distanceFilter;
    final last = _last;
    if (gap > 0 &&
        last != null &&
        metresBetweenCoordinates(last.latitude, last.longitude, fix.latitude, fix.longitude) < gap) {
      return false;
    }
    _last = fix;
    return true;
  }
}

/// Tells the hub when the app comes back to the screen.
class _FrontWatcher with WidgetsBindingObserver {
  _FrontWatcher(this.hub);

  final SharedLocation hub;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Fully back, not on its way in: the platform counts the app as in use.
    if (state == AppLifecycleState.resumed) hub.appCameToFront();
  }
}

/// The app's single listener of the platform position stream (see the top of
/// this file). Use [sharedPositionStream].
class SharedLocation {
  /// [open] and [inFront] are seams for tests: the platform stream, and whether
  /// the app is on the screen.
  SharedLocation({PositionOpener? open, bool Function()? inFront})
    : _open = open ?? _platformStream,
      _inFront = inFront ?? _appInFront;

  static Stream<Position> _platformStream(LocationSettings settings) =>
      Geolocator.getPositionStream(locationSettings: settings);

  static bool _appInFront() {
    try {
      return lifecycleInFront(WidgetsBinding.instance.lifecycleState);
    } catch (_) {
      return true; // no app around it (a plain test): nothing to wait for
    }
  }

  /// The app's hub, told when the app comes back to the screen.
  static final SharedLocation instance = _forApp();

  static SharedLocation _forApp() {
    final hub = SharedLocation();
    try {
      WidgetsBinding.instance.addObserver(_FrontWatcher(hub));
    } catch (_) {}
    return hub;
  }

  final PositionOpener _open;
  final bool Function() _inFront;
  final List<_Listener> _listeners = [];
  StreamSubscription<Position>? _source;
  LocationSettings? _running;
  bool _applying = false;
  bool _stale = false;

  /// A change of settings was held back while the app was away.
  bool _held = false;

  /// The stream was opened while the app was away, where the platform may not
  /// have let it start: opened afresh once the app is in front ([_afresh]).
  bool _openedAway = false;
  bool _afresh = false;

  /// What the platform stream is running with now; null while it is closed.
  LocationSettings? get running => _running;

  /// How many are listening.
  int get listeners => _listeners.length;

  /// Positions for [settings]: at least that accurate, and no closer together
  /// than its distance filter. The platform stream opens with the first
  /// listener, closes with the last, and is reopened whenever what the
  /// listeners need between them changes.
  ///
  /// A `timeLimit` is not supported: it would end the stream for everyone.
  Stream<Position> watch(LocationSettings settings) {
    assert(settings.timeLimit == null, 'a time limit would end the shared stream for every listener');
    final listener = _Listener(settings);
    listener.out = StreamController<Position>(
      onListen: () {
        _listeners.add(listener);
        _changed();
      },
      onCancel: () {
        _listeners.remove(listener);
        _changed();
      },
    );
    return listener.out.stream;
  }

  /// The app is back on the screen: apply what was held back while it was
  /// away, and open afresh a stream that was started there.
  void appCameToFront() {
    if (!_held && !_openedAway) return;
    if (_openedAway) _afresh = true;
    _held = false;
    _openedAway = false;
    _changed();
  }

  void _changed() {
    _stale = true;
    if (_applying) return;
    _applying = true;
    unawaited(_apply());
  }

  /// Brings the platform stream in line with the listeners. One at a time:
  /// listeners coming and going while it works are picked up on its next turn.
  Future<void> _apply() async {
    try {
      while (_stale) {
        _stale = false;
        if (_listeners.isEmpty) {
          await _close();
          continue;
        }
        final want = mergeLocationSettings([for (final l in _listeners) l.settings]);
        final running = _running;
        if (_source != null && running != null) {
          if (!_afresh && sameLocationSettings(want, running)) continue;
          // Away from the screen, the running stream is what keeps the app
          // alive, and it could not be started again from there (see the top
          // of this file): it stays as it is until the app is back in front.
          // When nothing needs the background any more it is let go at once,
          // so the location indicator does not outstay what asked for it.
          if (!_inFront() && runsInBackground(running) && runsInBackground(want)) {
            _held = true;
            continue;
          }
        }
        _afresh = false;
        // The plugin lets go of its stream only when its last listener leaves,
        // and the platform refuses a second listen while the first is open, so
        // close first and wait for it.
        await _close();
        if (_stale) continue; // someone came or went meanwhile: work it out afresh
        _running = want;
        _openedAway = !_inFront();
        try {
          _source = _open(want).listen(_onFix, onError: _onError, onDone: _onDone);
        } catch (error, stack) {
          _running = null;
          _onError(error, stack);
        }
      }
    } finally {
      _applying = false;
    }
  }

  Future<void> _close() async {
    final source = _source;
    _source = null;
    _running = null;
    if (source == null) return;
    try {
      await source.cancel();
    } catch (_) {}
  }

  void _onFix(Position fix) {
    for (final listener in List.of(_listeners)) {
      if (listener.out.isClosed || !listener.takes(fix)) continue;
      listener.out.add(fix);
    }
  }

  void _onError(Object error, StackTrace stack) {
    for (final listener in List.of(_listeners)) {
      if (!listener.out.isClosed) listener.out.addError(error, stack);
    }
  }

  /// The platform ended the stream: so do the listeners' (each then leaves).
  void _onDone() {
    _source = null;
    _running = null;
    for (final listener in List.of(_listeners)) {
      unawaited(listener.out.close());
    }
  }
}

/// The device's position as it changes, for [settings]: the app's one shared
/// platform stream (see the top of this file). Use this, never
/// `Geolocator.getPositionStream`, so that what one part of the app asks for
/// is not silently replaced by what another asked for first.
Stream<Position> sharedPositionStream(LocationSettings settings) => SharedLocation.instance.watch(settings);
