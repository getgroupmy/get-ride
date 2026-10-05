import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/session_telemetry.dart';

/// Where session telemetry goes. [SupabaseSessionSink] in the app, a fake in
/// tests.
abstract class SessionSink {
  Future<IpInfo?> lookupIp();
  Future<void> insertSession(Map<String, dynamic> row);
  Future<void> insertLocation(Map<String, dynamic> row);
}

class SupabaseSessionSink implements SessionSink {
  SupabaseSessionSink(this._db);
  final SupabaseClient _db;

  @override
  Future<IpInfo?> lookupIp() async {
    final res = await _db.functions.invoke('ip-lookup', body: {}).timeout(const Duration(seconds: 8));
    return IpInfo.fromResponse(res.data);
  }

  /// Retries without any column the live database does not have yet, since
  /// one unknown column rejects the whole row (same as Expo).
  @override
  Future<void> insertSession(Map<String, dynamic> row) async {
    final r = Map<String, dynamic>.of(row);
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        await _db.from('user_sessions').insert(r);
        return;
      } on PostgrestException catch (e) {
        final missing = missingColumn(e.message);
        if (missing == null || missing == 'id' || !r.containsKey(missing)) rethrow;
        r.remove(missing);
      }
    }
  }

  @override
  Future<void> insertLocation(Map<String, dynamic> row) => _db.from('user_location_history').insert(row);
}

/// Location access for the tracker. [GeolocatorTelemetryLocation] in the app.
abstract class TelemetryLocation {
  /// Whether foreground location is granted, asking at most when [mayAsk].
  Future<bool> ensurePermission({required bool mayAsk});
  Future<TelemetryFix?> current();
  Stream<TelemetryFix> watch();
}

class GeolocatorTelemetryLocation implements TelemetryLocation {
  static TelemetryFix _fix(Position p) => TelemetryFix(
    latitude: p.latitude,
    longitude: p.longitude,
    accuracy: p.accuracy,
    altitude: p.altitude,
    heading: p.heading,
    speed: p.speed,
  );

  @override
  Future<bool> ensurePermission({required bool mayAsk}) async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied && mayAsk) perm = await Geolocator.requestPermission();
    return perm == LocationPermission.always || perm == LocationPermission.whileInUse;
  }

  @override
  Future<TelemetryFix?> current() async {
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      ).timeout(const Duration(seconds: 15));
      return _fix(p);
    } catch (_) {
      final last = kIsWeb ? null : await Geolocator.getLastKnownPosition();
      return last == null ? null : _fix(last);
    }
  }

  @override
  Stream<TelemetryFix> watch() => Geolocator.getPositionStream(
    locationSettings: LocationSettings(
      accuracy: LocationAccuracy.medium,
      distanceFilter: locationMoveMeters.round(),
    ),
  ).map(_fix);
}

/// This device and app, from the platform alone.
DeviceSnapshot currentDevice({String appVersion = '1.4.3'}) {
  if (kIsWeb) return DeviceSnapshot(osName: 'web', deviceType: 'browser', appVersion: appVersion);
  final os = defaultTargetPlatform.name.toLowerCase();
  final mobile = defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
  String? version;
  try {
    version = Platform.operatingSystemVersion;
  } catch (_) {}
  return DeviceSnapshot(
    osName: os,
    osVersion: version,
    deviceType: mobile ? 'phone' : 'desktop',
    appVersion: appVersion,
  );
}

/// Logs `user_sessions` rows (launch, sign-in, return to the app) and, while
/// signed in, `user_location_history` rows, for the admin Session History and
/// fraud screens (Expo `SessionTrackingContext`). Nothing it does can fail the
/// app: every write is best-effort.
class SessionTracker {
  SessionTracker({
    required this._sink,
    required this._location,
    required this._deviceId,
    required this._device,
    DateTime Function()? now,
    String Function()? newId,
  }) : _now = now ?? DateTime.now,
       _newId = newId ?? (() => const Uuid().v4());

  final SessionSink _sink;
  final TelemetryLocation _location;
  final Future<String> Function() _deviceId;
  final DeviceSnapshot _device;
  final DateTime Function() _now;
  final String Function() _newId;

  String? _userId;
  String? _phone;
  String? _loggedUserId;
  String? _sessionId;
  bool _launched = false;
  bool _askedPermission = false;
  int _generation = 0;
  DateTime? _lastWrite;
  TelemetryFix? _lastFix;
  Timer? _heartbeat;
  StreamSubscription<TelemetryFix>? _watch;

  /// The session row the location rows belong to.
  String? get sessionId => _sessionId;

  /// The cold start, logged once.
  Future<void> launched() async {
    if (_launched) return;
    _launched = true;
    await _log(SessionEvent.appLaunch);
  }

  /// The app came back to the foreground.
  Future<void> resumed() async {
    if (!_launched) return;
    await _log(SessionEvent.appRelaunch);
  }

  /// The signed-in account changed. A new account logs a `login` row and
  /// starts location tracking; signing out stops it.
  Future<void> userChanged(String? userId, {String? phone}) async {
    _phone = phone;
    if (userId == _userId) return;
    _userId = userId;
    _stopLocation();
    if (userId == null) {
      _loggedUserId = null;
      return;
    }
    if (_loggedUserId != userId) {
      _loggedUserId = userId;
      await _log(SessionEvent.login);
    }
    await _startLocation();
  }

  void dispose() {
    _generation++;
    _stopLocation();
  }

  Future<void> _log(SessionEvent event) async {
    final id = _newId();
    _sessionId = id;
    try {
      final results = await Future.wait<Object?>([
        _deviceId(),
        _sink.lookupIp().catchError((_) => null),
      ]);
      await _sink.insertSession(
        sessionRow(
          id: id,
          event: event,
          deviceId: results[0]! as String,
          device: _device,
          userId: _userId,
          phone: _phone,
          ip: results[1] as IpInfo?,
        ),
      );
    } catch (e) {
      debugPrint('[session] ${event.value} not logged: $e');
    }
  }

  Future<void> _startLocation() async {
    final gen = ++_generation;
    try {
      final mayAsk = !_askedPermission;
      _askedPermission = true;
      if (!await _location.ensurePermission(mayAsk: mayAsk)) return;
      if (gen != _generation) return;
      _heartbeat = Timer.periodic(locationPingInterval, (_) => _ping(gen));
      _watch = _location.watch().listen((fix) => _offer(fix, gen), onError: (_) {});
      await _ping(gen);
    } catch (e) {
      debugPrint('[session] location tracking unavailable: $e');
    }
  }

  void _stopLocation() {
    _generation++;
    _heartbeat?.cancel();
    _heartbeat = null;
    _watch?.cancel();
    _watch = null;
  }

  Future<void> _ping(int gen) async {
    if (gen != _generation) return;
    if (!locationRowDue(lastWrite: _lastWrite, now: _now())) return;
    try {
      final fix = await _location.current();
      if (fix != null) await _write(fix, gen);
    } catch (_) {}
  }

  Future<void> _offer(TelemetryFix fix, int gen) async {
    final last = _lastFix;
    final moved = last == null
        ? null
        : Geolocator.distanceBetween(last.latitude, last.longitude, fix.latitude, fix.longitude);
    if (!locationRowDue(lastWrite: _lastWrite, now: _now(), movedMeters: moved)) return;
    await _write(fix, gen);
  }

  Future<void> _write(TelemetryFix fix, int gen) async {
    if (gen != _generation) return;
    _lastWrite = _now();
    _lastFix = fix;
    try {
      await _sink.insertLocation(
        locationRow(
          latitude: fix.latitude,
          longitude: fix.longitude,
          deviceId: await _deviceId(),
          userId: _userId,
          phone: _phone,
          sessionId: _sessionId,
          accuracy: fix.accuracy,
          altitude: fix.altitude,
          heading: fix.heading,
          speed: fix.speed,
        ),
      );
    } catch (e) {
      _lastWrite = null;
      debugPrint('[session] location row not written: $e');
    }
  }
}
