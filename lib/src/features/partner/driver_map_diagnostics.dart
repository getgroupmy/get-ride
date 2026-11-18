// Debug-only driver-home-map diagnostics.
//
// Spec: "GET RIDE — iOS + Android Driver Map Diagnostic Build". This is the
// pure core — the event schema, the bounded ring buffer, redaction, the
// JSONL/CSV serialisers, and the small pure rules the overlay reads (which dot
// renderer should be active, a duplicate-dot check, pixel error). It holds no
// Flutter widgets and no platform calls, so it is unit-testable and carries no
// production behaviour.
//
// EVERYTHING here is gated at the call sites by [driverMapDiagnosticsEnabled]:
// a release build evaluates that to a compile-time `false`, so the overlay and
// the logger are never mounted and nothing below runs in production. Diagnostics
// are also off in a debug build unless it was started with
// `--dart-define=DRIVER_MAP_DIAGNOSTICS=true`.
import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

/// Set at build time with `--dart-define=DRIVER_MAP_DIAGNOSTICS=true`.
const bool _diagDefine = bool.fromEnvironment('DRIVER_MAP_DIAGNOSTICS', defaultValue: false);

/// Whether the driver-map diagnostics may run at all: only in a debug build
/// (never release) and only when the define above is set. Every diagnostic UI
/// and logging path is guarded by this.
bool get driverMapDiagnosticsEnabled => kDebugMode && _diagDefine;

/// Bumped if the event shape ever changes, so an exported log names the schema
/// it was written with.
const int driverMapDiagSchemaVersion = 1;

/// The base map actually drawn under the driver's dot.
enum DriverMapProvider { appleNative, googleNative, flutterTiles, other }

/// What is drawing the driver's location dot right now.
enum DotRenderer { native, flutterMarker, customPuck, none }

/// The discrete things worth recording. Transitions are logged in full; camera
/// movement is sampled (see [shouldSampleCamera]) rather than logged per frame.
enum DriverMapEventKind {
  gpsFix,
  heading,
  gestureStart,
  gestureEnd,
  cameraSample,
  cameraMoveRequested,
  recenterTap,
  followChanged,
  providerChanged,
  mapReady,
  lifecycle,
  export,
}

/// Snake-case wire name for the export schema's `provider` field.
String driverMapProviderWire(DriverMapProvider p) => switch (p) {
  DriverMapProvider.appleNative => 'apple_native',
  DriverMapProvider.googleNative => 'google_native',
  DriverMapProvider.flutterTiles => 'flutter_tiles',
  DriverMapProvider.other => 'other',
};

/// Snake-case wire name for the export schema's `event` field.
String driverMapEventWire(DriverMapEventKind k) => switch (k) {
  DriverMapEventKind.gpsFix => 'gps_fix',
  DriverMapEventKind.heading => 'heading',
  DriverMapEventKind.gestureStart => 'gesture_start',
  DriverMapEventKind.gestureEnd => 'gesture_end',
  DriverMapEventKind.cameraSample => 'camera_sample',
  DriverMapEventKind.cameraMoveRequested => 'camera_move_requested',
  DriverMapEventKind.recenterTap => 'recenter_tap',
  DriverMapEventKind.followChanged => 'follow_changed',
  DriverMapEventKind.providerChanged => 'provider_changed',
  DriverMapEventKind.mapReady => 'map_ready',
  DriverMapEventKind.lifecycle => 'lifecycle',
  DriverMapEventKind.export => 'export',
};

/// Snake-case wire name for the export schema's `dot_renderer` field.
String dotRendererWire(DotRenderer r) => switch (r) {
  DotRenderer.native => 'native',
  DotRenderer.flutterMarker => 'flutter_marker',
  DotRenderer.customPuck => 'custom_puck',
  DotRenderer.none => 'none',
};

/// Whether [p] is a native base map (Apple/Google), whose SDK draws its own
/// device-location dot (and whose on-screen dot position the plugin does not
/// expose to us — so pixel error is N/A there).
bool nativeBaseProvider(DriverMapProvider p) =>
    p == DriverMapProvider.appleNative || p == DriverMapProvider.googleNative;

/// The single location-dot renderer that *should* be active, mirroring
/// `ride_map.dart`: a native base draws its own dot when `nativeMe` is on; a
/// Flutter tile base draws the flutter_map marker; nothing without a fix.
/// The overlay compares this against what it actually observes.
DotRenderer expectedDotRenderer({
  required DriverMapProvider provider,
  required bool nativeMe,
  required bool hasFix,
}) {
  if (!hasFix) return DotRenderer.none;
  if (nativeMe && nativeBaseProvider(provider)) return DotRenderer.native;
  return DotRenderer.flutterMarker;
}

/// Exactly one dot must show. True only when a native dot and a Flutter dot are
/// both visible at once — a parity bug ([RideMap] should suppress one). The
/// overlay raises its duplicate-dot warning on this.
bool duplicateDot({required bool nativeDotVisible, required bool flutterDotVisible}) =>
    nativeDotVisible && flutterDotVisible;

/// Pixel distance between where a fix projects on screen and where the dot is
/// actually drawn, in logical pixels; null when either is unknown (e.g. a
/// native base whose system dot position is not exposed).
double? pixelError(Offset? expected, Offset? measured) =>
    (expected == null || measured == null) ? null : (expected - measured).distance;

/// Whether to record another camera sample now: caps sampling at [hz] (default
/// 10 Hz) so a 60 fps glide does not flood the ring buffer. The first sample
/// (no previous time) always passes.
bool shouldSampleCamera(int? lastSampleMs, int nowMs, {double hz = 10}) {
  if (lastSampleMs == null) return true;
  return nowMs - lastSampleMs >= 1000 / hz;
}

/// Device/build facts stamped onto every row. Gathered once by the host (see
/// the overlay file); [unknown] until then, and in unit tests.
@immutable
class DriverMapDiagnosticsMeta {
  const DriverMapDiagnosticsMeta({
    required this.platform,
    required this.osVersion,
    required this.deviceModel,
    required this.appSha,
  });

  /// 'ios', 'android', or another platform name.
  final String platform;
  final String osVersion;
  final String deviceModel;
  final String appSha;

  static const unknown = DriverMapDiagnosticsMeta(
    platform: 'unknown',
    osVersion: 'unknown',
    deviceModel: 'unknown',
    appSha: 'unknown',
  );
}

/// One recorded moment. Immutable. Raw coordinates are redacted to null unless
/// the exporter is told the tester explicitly consented to exact coordinates;
/// pixel offsets/errors are not locations and are always kept.
@immutable
class DriverMapEvent {
  const DriverMapEvent({
    required this.kind,
    required this.elapsedMs,
    required this.timestampUtc,
    this.follow,
    this.gesture,
    this.animationActive,
    this.gpsAgeMs,
    this.gpsAccuracyM,
    this.speedMps,
    this.gpsLat,
    this.gpsLng,
    this.cameraLat,
    this.cameraLng,
    this.zoom,
    this.rotationDeg,
    this.headingDeg,
    this.sheetInsetPx,
    this.provider,
    this.dotRenderer,
    this.expectedDotPx,
    this.measuredDotPx,
    this.errorPx,
    this.notes,
  });

  final DriverMapEventKind kind;
  final int elapsedMs;
  final DateTime timestampUtc;
  final bool? follow;
  final bool? gesture;
  final bool? animationActive;
  final int? gpsAgeMs;
  final double? gpsAccuracyM;
  final double? speedMps;
  final double? gpsLat;
  final double? gpsLng;
  final double? cameraLat;
  final double? cameraLng;
  final double? zoom;
  final double? rotationDeg;
  final double? headingDeg;
  final double? sheetInsetPx;
  final DriverMapProvider? provider;
  final DotRenderer? dotRenderer;
  final Offset? expectedDotPx;
  final Offset? measuredDotPx;
  final double? errorPx;

  /// Free-text, caller-supplied. Callers must not place addresses, identifiers
  /// or credentials here — only diagnostic notes.
  final String? notes;

  /// The schema row. When [exact] is false (default) the four raw coordinates
  /// are redacted to null; everything else, pixel offsets and errors included,
  /// is kept (they are not locations).
  Map<String, dynamic> toJson(DriverMapDiagnosticsMeta meta, {bool exact = false}) => {
    'schema_version': driverMapDiagSchemaVersion,
    'timestamp_utc': timestampUtc.toUtc().toIso8601String(),
    'elapsed_ms': elapsedMs,
    'platform': meta.platform,
    'os_version': meta.osVersion,
    'device_model': meta.deviceModel,
    'app_sha': meta.appSha,
    'provider': provider == null ? null : driverMapProviderWire(provider!),
    'event': driverMapEventWire(kind),
    'follow': follow,
    'gesture': gesture,
    'animation_active': animationActive,
    'gps_age_ms': gpsAgeMs,
    'gps_accuracy_m': gpsAccuracyM,
    'speed_mps': speedMps,
    'gps_lat': exact ? gpsLat : null,
    'gps_lng': exact ? gpsLng : null,
    'camera_lat': exact ? cameraLat : null,
    'camera_lng': exact ? cameraLng : null,
    'zoom': zoom,
    'rotation_deg': rotationDeg,
    'heading_deg': headingDeg,
    'sheet_inset_px': sheetInsetPx,
    'dot_renderer': dotRenderer == null ? null : dotRendererWire(dotRenderer!),
    'expected_dot_px': _px(expectedDotPx),
    'measured_dot_px': _px(measuredDotPx),
    'error_px': errorPx,
    'notes': notes,
  };

  static List<double>? _px(Offset? o) => o == null ? null : [o.dx, o.dy];
}

/// The export schema's columns, in order — the keys of [DriverMapEvent.toJson].
/// Used as the CSV header and to keep JSONL and CSV in step.
const List<String> driverMapCsvColumns = [
  'schema_version',
  'timestamp_utc',
  'elapsed_ms',
  'platform',
  'os_version',
  'device_model',
  'app_sha',
  'provider',
  'event',
  'follow',
  'gesture',
  'animation_active',
  'gps_age_ms',
  'gps_accuracy_m',
  'speed_mps',
  'gps_lat',
  'gps_lng',
  'camera_lat',
  'camera_lng',
  'zoom',
  'rotation_deg',
  'heading_deg',
  'sheet_inset_px',
  'dot_renderer',
  'expected_dot_px',
  'measured_dot_px',
  'error_px',
  'notes',
];

/// A bounded, in-memory ring buffer of [DriverMapEvent]s with a monotonic
/// clock and local-only JSONL/CSV export. Nothing here touches the network or
/// Supabase. Its [revision] notifier lets the overlay rebuild cheaply.
class DriverMapEventLog {
  DriverMapEventLog({this.maxEvents = 800, DriverMapDiagnosticsMeta? meta})
    : meta = meta ?? DriverMapDiagnosticsMeta.unknown;

  /// Cap on retained events (spec: 500–1000). Oldest are dropped past this.
  final int maxEvents;

  /// Device/build facts stamped onto exported rows; set once by the host.
  DriverMapDiagnosticsMeta meta;

  final List<DriverMapEvent> _events = [];
  final Stopwatch _clock = Stopwatch()..start();

  /// Bumped on every change (record/clear) so a listening overlay repaints.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Milliseconds since the log was created — the monotonic `elapsed_ms` that
  /// aligns a log with a screen recording.
  int get elapsedMs => _clock.elapsedMilliseconds;
  int get count => _events.length;
  DriverMapEvent? get latest => _events.isEmpty ? null : _events.last;
  List<DriverMapEvent> get events => List.unmodifiable(_events);

  void record(DriverMapEvent e) {
    _events.add(e);
    final over = _events.length - maxEvents;
    if (over > 0) _events.removeRange(0, over);
    revision.value++;
  }

  void clear() {
    _events.clear();
    revision.value++;
  }

  /// One JSON object per line. [exact] false redacts raw coordinates.
  String toJsonl({bool exact = false}) =>
      _events.map((e) => jsonEncode(e.toJson(meta, exact: exact))).join('\n');

  /// A CSV with [driverMapCsvColumns] as the header. Pixel offsets flatten to
  /// "x y"; cells with separators are quoted. [exact] false redacts coordinates.
  String toCsv({bool exact = false}) {
    final buf = StringBuffer(driverMapCsvColumns.join(','))..write('\n');
    for (final e in _events) {
      final row = e.toJson(meta, exact: exact);
      buf.writeln(driverMapCsvColumns.map((c) => _csvCell(row[c])).join(','));
    }
    return buf.toString();
  }

  void dispose() => revision.dispose();
}

String _csvCell(Object? v) {
  if (v == null) return '';
  final s = v is List ? v.join(' ') : '$v';
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}
