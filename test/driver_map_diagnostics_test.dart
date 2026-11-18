import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/features/partner/driver_map_diagnostics.dart';

void main() {
  test('diagnostics are off by default (no --dart-define)', () {
    // In the test runner kDebugMode is true but the define is absent, so the
    // whole subsystem stays off — a release build has it off unconditionally.
    expect(driverMapDiagnosticsEnabled, isFalse);
  });

  group('expectedDotRenderer mirrors ride_map suppression', () {
    test('native base + nativeMe → the native dot', () {
      expect(
        expectedDotRenderer(provider: DriverMapProvider.appleNative, nativeMe: true, hasFix: true),
        DotRenderer.native,
      );
      expect(
        expectedDotRenderer(provider: DriverMapProvider.googleNative, nativeMe: true, hasFix: true),
        DotRenderer.native,
      );
    });
    test('flutter tiles → the flutter_map marker', () {
      expect(
        expectedDotRenderer(provider: DriverMapProvider.flutterTiles, nativeMe: true, hasFix: true),
        DotRenderer.flutterMarker,
      );
    });
    test('native base but nativeMe off → the flutter marker (no native dot)', () {
      expect(
        expectedDotRenderer(provider: DriverMapProvider.appleNative, nativeMe: false, hasFix: true),
        DotRenderer.flutterMarker,
      );
    });
    test('no fix → nothing', () {
      expect(
        expectedDotRenderer(provider: DriverMapProvider.appleNative, nativeMe: true, hasFix: false),
        DotRenderer.none,
      );
    });
  });

  group('duplicateDot', () {
    test('only when both a native and a flutter dot are visible', () {
      expect(duplicateDot(nativeDotVisible: true, flutterDotVisible: true), isTrue);
      expect(duplicateDot(nativeDotVisible: true, flutterDotVisible: false), isFalse);
      expect(duplicateDot(nativeDotVisible: false, flutterDotVisible: true), isFalse);
      expect(duplicateDot(nativeDotVisible: false, flutterDotVisible: false), isFalse);
    });
  });

  group('pixelError', () {
    test('euclidean distance, null when either side is unknown', () {
      expect(pixelError(const Offset(0, 0), const Offset(3, 4)), closeTo(5, 1e-9));
      expect(pixelError(null, const Offset(3, 4)), isNull, reason: 'native base: dot px not exposed');
      expect(pixelError(const Offset(3, 4), null), isNull);
    });
  });

  group('shouldSampleCamera caps at ~10 Hz', () {
    test('first sample passes, then one per ~100 ms', () {
      expect(shouldSampleCamera(null, 0), isTrue, reason: 'first sample always passes');
      expect(shouldSampleCamera(1000, 1050), isFalse, reason: '50 ms < 100 ms');
      expect(shouldSampleCamera(1000, 1100), isTrue, reason: '100 ms >= 100 ms');
      expect(shouldSampleCamera(1000, 1040, hz: 5), isFalse, reason: '40 ms < 200 ms at 5 Hz');
      expect(shouldSampleCamera(1000, 1200, hz: 5), isTrue);
    });
  });

  DriverMapEvent fix({double? lat = 3.1, double? lng = 101.7, DateTime? when}) => DriverMapEvent(
    kind: DriverMapEventKind.gpsFix,
    elapsedMs: 10,
    timestampUtc: when ?? DateTime.utc(2026, 1, 1),
    follow: true,
    gpsAccuracyM: 8.2,
    speedMps: 0,
    gpsLat: lat,
    gpsLng: lng,
    zoom: 17,
    provider: DriverMapProvider.googleNative,
    dotRenderer: DotRenderer.native,
    expectedDotPx: const Offset(12, 34),
    errorPx: null,
    notes: 'ok',
  );

  const meta = DriverMapDiagnosticsMeta(
    platform: 'ios',
    osVersion: '18.1',
    deviceModel: 'iPhone15,2',
    appSha: 'abc1234',
  );

  group('redaction', () {
    test('coordinates are null by default and present only with consent', () {
      final redacted = fix().toJson(meta);
      expect(redacted['gps_lat'], isNull);
      expect(redacted['gps_lng'], isNull);
      expect(redacted['camera_lat'], isNull);
      expect(redacted['camera_lng'], isNull);
      // Non-location telemetry is kept either way.
      expect(redacted['gps_accuracy_m'], 8.2);
      expect(redacted['zoom'], 17);
      expect(redacted['expected_dot_px'], [12.0, 34.0]);
      expect(redacted['provider'], 'google_native');
      expect(redacted['event'], 'gps_fix');
      expect(redacted['dot_renderer'], 'native');
      expect(redacted['schema_version'], driverMapDiagSchemaVersion);

      final exact = fix().toJson(meta, exact: true);
      expect(exact['gps_lat'], 3.1);
      expect(exact['gps_lng'], 101.7);
    });
  });

  group('DriverMapEventLog ring buffer', () {
    test('keeps at most maxEvents, dropping the oldest, latest/count track', () {
      final log = DriverMapEventLog(maxEvents: 3, meta: meta);
      expect(log.count, 0);
      for (var i = 0; i < 5; i++) {
        log.record(DriverMapEvent(
          kind: DriverMapEventKind.cameraSample,
          elapsedMs: i,
          timestampUtc: DateTime.utc(2026, 1, 1),
          notes: 'e$i',
        ));
      }
      expect(log.count, 3);
      expect(log.events.map((e) => e.notes), ['e2', 'e3', 'e4'], reason: 'oldest two dropped');
      expect(log.latest?.notes, 'e4');
      log.clear();
      expect(log.count, 0);
      log.dispose();
    });

    test('revision notifier bumps on record and clear', () {
      final log = DriverMapEventLog(meta: meta);
      final seen = <int>[];
      log.revision.addListener(() => seen.add(log.revision.value));
      log.record(fix());
      log.clear();
      expect(seen, [1, 2]);
      log.dispose();
    });
  });

  group('export', () {
    test('JSONL is one object per event and honours redaction', () {
      final log = DriverMapEventLog(meta: meta)
        ..record(fix())
        ..record(fix());
      final lines = log.toJsonl().split('\n');
      expect(lines.length, 2);
      final first = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(first['gps_lat'], isNull);
      expect((jsonDecode(log.toJsonl(exact: true).split('\n').first) as Map)['gps_lat'], 3.1);
      log.dispose();
    });

    test('CSV has the schema header and one row per event; offsets flatten', () {
      final log = DriverMapEventLog(meta: meta)..record(fix());
      final rows = log.toCsv().trim().split('\n');
      expect(rows.first, driverMapCsvColumns.join(','));
      expect(rows.length, 2, reason: 'header + one event');
      expect(rows[1], contains('12.0 34.0'), reason: 'expected_dot_px flattened to "x y"');
      expect(rows[1], contains('google_native'));
      log.dispose();
    });
  });

  test('wire names are snake_case for every enum value', () {
    for (final k in DriverMapEventKind.values) {
      expect(driverMapEventWire(k), matches(RegExp(r'^[a-z_]+$')));
    }
    for (final p in DriverMapProvider.values) {
      expect(driverMapProviderWire(p), matches(RegExp(r'^[a-z_]+$')));
    }
    for (final r in DotRenderer.values) {
      expect(dotRendererWire(r), matches(RegExp(r'^[a-z_]+$')));
    }
  });
}
