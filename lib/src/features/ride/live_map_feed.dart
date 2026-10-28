// Rider live map (migration 0322): keeps the home map's overlays and cars
// fresh while they are on, each at the admin's update interval (the server
// answers no faster anyway), and drops what is turned off at once.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../../core/rider_live_map.dart';
import '../../data/rider_live_map_repository.dart';

/// How far around the rider the honeycomb reaches, in degrees of latitude
/// (about 5 km each way).
const busyBoxHalf = 0.045;

/// The box the honeycomb is asked for around [c].
({double south, double west, double north, double east}) busyBoxAround(LatLng c) {
  final dLng = busyBoxHalf / math.max(math.cos(c.latitude * math.pi / 180), 0.05);
  return (south: c.latitude - busyBoxHalf, west: c.longitude - dLng, north: c.latitude + busyBoxHalf, east: c.longitude + dLng);
}

class LiveMapFeed extends ChangeNotifier {
  LiveMapFeed(this._repo, {this.tick = const Duration(seconds: 2)});

  final RiderLiveMapRepository Function() _repo;

  /// How often the feed checks what is due.
  final Duration tick;

  LiveMapConfig _config = LiveMapConfig.off;
  Set<LiveOverlay> _overlays = const {};
  bool _cars = false;
  LatLng? _centre;
  LivePlace _place = const {};

  BusyAreas busy = BusyAreas.none;
  LivePeople people = LivePeople.none;
  LivePeople team = LivePeople.none;
  LiveCars cars = LiveCars.none;

  final _last = <String, DateTime>{};
  final _busy = <String>{};
  Timer? _timer;
  bool _disposed = false;

  bool get running => _timer != null;

  /// What should be on now. Called from the home screen's build: it never
  /// notifies here; answers arriving later do.
  void update({
    required LiveMapConfig config,
    required Set<LiveOverlay> overlays,
    required bool cars,
    required LatLng? centre,
    required LivePlace place,
  }) {
    _config = config;
    _centre = centre;
    _place = place;
    final on = activeOverlays(overlays, config);
    for (final o in LiveOverlay.values) {
      if (!on.contains(o) && _overlays.contains(o)) {
        _last.remove(o.key);
        switch (o) {
          case LiveOverlay.busy:
            busy = BusyAreas.none;
          case LiveOverlay.people:
            people = LivePeople.none;
          case LiveOverlay.team:
            team = LivePeople.none;
        }
      }
    }
    if (!cars && _cars) {
      _last.remove('cars');
      this.cars = LiveCars.none;
    }
    _overlays = on;
    _cars = cars && centre != null;
    final want = _overlays.isNotEmpty || _cars;
    if (want && _timer == null) {
      _timer = Timer.periodic(tick, (_) => _poll());
      scheduleMicrotask(_poll);
    } else if (!want && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  bool _due(String key, int everyS) {
    final last = _last[key];
    return !_busy.contains(key) && (last == null || DateTime.now().difference(last).inSeconds >= everyS);
  }

  Future<void> _fetch(String key, Future<void> Function() f) async {
    _busy.add(key);
    _last[key] = DateTime.now();
    try {
      await f();
      if (!_disposed) notifyListeners();
    } catch (_) {
      // Kept as it was; the next interval tries again.
    } finally {
      _busy.remove(key);
    }
  }

  void _poll() {
    if (_disposed) return;
    final repo = _repo();
    final c = _centre;
    if (_cars && c != null && _due('cars', _config.carsEvery)) {
      unawaited(_fetch('cars', () async {
        final got = await repo.cars(c.latitude, c.longitude, _place);
        if (_cars) cars = got;
      }));
    }
    if (_overlays.contains(LiveOverlay.busy) && c != null && _due('busy', _config.busyEvery)) {
      final box = busyBoxAround(c);
      unawaited(_fetch('busy', () async {
        final got = await repo.busy(south: box.south, west: box.west, north: box.north, east: box.east, place: _place);
        if (_overlays.contains(LiveOverlay.busy)) busy = got;
      }));
    }
    if (_overlays.contains(LiveOverlay.people) && _due('people', _config.peopleEvery)) {
      unawaited(_fetch('people', () async {
        final got = await repo.people(_place);
        if (_overlays.contains(LiveOverlay.people)) people = got;
      }));
    }
    if (_overlays.contains(LiveOverlay.team) && _due('team', _config.teamEvery)) {
      unawaited(_fetch('team', () async {
        final got = await repo.team(_place);
        if (_overlays.contains(LiveOverlay.team)) team = got;
      }));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
