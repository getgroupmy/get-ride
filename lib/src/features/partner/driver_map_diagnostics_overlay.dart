// Debug-only diagnostic overlay + local export for the driver home map.
//
// Spec: "GET RIDE — iOS + Android Driver Map Diagnostic Build". This is the
// visible, non-blocking overlay and the user-initiated local export (JSONL/CSV
// to the OS share sheet). It is mounted only when [driverMapDiagnosticsEnabled]
// is true, so it never appears in a release build.
//
// Deliberately web-safe: no `dart:io` / `path_provider` import (those break the
// web/dart2js build). Export hands share_plus a data-backed XFile, which it
// writes to a temp file itself on mobile and offers as a download on web.
// Nothing is ever sent to a server or Supabase.
import 'dart:convert';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import 'driver_map_diagnostics.dart';

/// The single in-memory event log, created on first use. Export reads from it.
DriverMapEventLog? _log;
DriverMapEventLog get driverMapLog => _log ??= DriverMapEventLog();

/// Whether the tester has explicitly consented to including exact coordinates
/// in the overlay and in exports. Off by default (spec: coordinates hidden
/// unless separately consented).
final ValueNotifier<bool> driverMapExactConsent = ValueNotifier<bool>(false);

/// The most recent raw fix, kept in memory only for the debug reference marker
/// and the (consented) coordinate readout. Never written to the ring buffer.
({double lat, double lng})? _lastRawFix;

/// Record the latest raw fix for the reference marker / coordinate readout.
/// A no-op unless diagnostics are enabled.
void driverMapNoteRawFix(double lat, double lng) {
  if (!driverMapDiagnosticsEnabled) return;
  _lastRawFix = (lat: lat, lng: lng);
}

/// A fixed geographic reference marker the tester can drop at the current fix,
/// to tell GPS wander apart from projection drift (it stays on the same
/// geographic point while the live dot may move).
class DriverMapReference {
  const DriverMapReference({required this.lat, required this.lng, required this.lockedElapsedMs});
  final double lat;
  final double lng;
  final int lockedElapsedMs;
}

final ValueNotifier<DriverMapReference?> driverMapReference = ValueNotifier<DriverMapReference?>(null);

void lockDriverMapReferenceFromLastFix() {
  final f = _lastRawFix;
  if (f == null) return;
  driverMapReference.value = DriverMapReference(lat: f.lat, lng: f.lng, lockedElapsedMs: driverMapLog.elapsedMs);
  driverMapLog.record(DriverMapEvent(
    kind: DriverMapEventKind.lifecycle,
    elapsedMs: driverMapLog.elapsedMs,
    timestampUtc: DateTime.now().toUtc(),
    notes: 'reference_locked',
  ));
}

void clearDriverMapReference() => driverMapReference.value = null;

/// The live fields the overlay shows, kept as a mutable singleton the wiring
/// updates in place and then [touch]es so the overlay repaints. Not exported —
/// the ring buffer is the export source.
class DriverMapLiveState {
  DriverMapProvider? provider;
  bool satellite = false;
  bool mapReady = false;
  bool follow = false;
  bool gesture = false;
  bool animationActive = false;
  int? gpsAgeMs;
  double? gpsAccuracyM;
  double? speedMps;
  double? courseDeg;
  double? headingDeg;
  double? cameraZoom;
  double? cameraRotationDeg;
  double? sheetInsetPx;
  DotRenderer dotRenderer = DotRenderer.none;
  bool duplicateDotWarning = false;
  double? errorPx;

  final ValueNotifier<int> rev = ValueNotifier<int>(0);
  void touch() => rev.value++;
}

final DriverMapLiveState driverMapLive = DriverMapLiveState();

bool _metaReady = false;

/// Gather device/build facts once and stamp them onto the log. Best-effort and
/// web-safe; leaves the fields as "unknown" on any failure.
Future<void> ensureDriverMapMeta() async {
  if (_metaReady || !driverMapDiagnosticsEnabled) return;
  _metaReady = true;
  final platform = kIsWeb
      ? 'web'
      : switch (defaultTargetPlatform) {
          TargetPlatform.iOS => 'ios',
          TargetPlatform.android => 'android',
          final p => p.name,
        };
  var osVersion = 'unknown';
  var deviceModel = 'unknown';
  try {
    final info = DeviceInfoPlugin();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      final ios = await info.iosInfo;
      osVersion = 'iOS ${ios.systemVersion}';
      deviceModel = ios.utsname.machine;
    } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final a = await info.androidInfo;
      osVersion = 'Android ${a.version.release} (SDK ${a.version.sdkInt})';
      deviceModel = '${a.manufacturer} ${a.model}';
    }
  } catch (_) {}
  var appSha = const String.fromEnvironment('APP_SHA');
  if (appSha.isEmpty) {
    try {
      final p = await PackageInfo.fromPlatform();
      appSha = '${p.version}+${p.buildNumber}';
    } catch (_) {
      appSha = 'unknown';
    }
  }
  driverMapLog.meta = DriverMapDiagnosticsMeta(
    platform: platform,
    osVersion: osVersion,
    deviceModel: deviceModel,
    appSha: appSha,
  );
  driverMapLive.touch();
}

/// Build the log body and hand it to the OS share sheet. Local only.
Future<void> exportDriverMapLog({required bool csv}) async {
  final exact = driverMapExactConsent.value;
  final body = csv ? driverMapLog.toCsv(exact: exact) : driverMapLog.toJsonl(exact: exact);
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
  final name = 'driver-map-diag-$stamp.${csv ? 'csv' : 'jsonl'}';
  final file = XFile.fromData(
    Uint8List.fromList(utf8.encode(body)),
    name: name,
    mimeType: csv ? 'text/csv' : 'application/x-ndjson',
  );
  driverMapLog.record(DriverMapEvent(
    kind: DriverMapEventKind.export,
    elapsedMs: driverMapLog.elapsedMs,
    timestampUtc: DateTime.now().toUtc(),
    notes: 'export ${csv ? 'csv' : 'jsonl'} exact=$exact events=${driverMapLog.count}',
  ));
  await SharePlus.instance.share(ShareParams(files: [file], subject: 'Driver map diagnostics ($name)'));
}

/// The overlay itself. Place it directly in the host's [Stack] (it returns a
/// [Positioned]); it occupies only its own corner box, so it never swallows
/// the map's pan/zoom gestures elsewhere.
class DriverMapDiagnosticsOverlay extends StatefulWidget {
  const DriverMapDiagnosticsOverlay({super.key});

  @override
  State<DriverMapDiagnosticsOverlay> createState() => _DriverMapDiagnosticsOverlayState();
}

class _DriverMapDiagnosticsOverlayState extends State<DriverMapDiagnosticsOverlay> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    ensureDriverMapMeta();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 8,
      top: MediaQuery.paddingOf(context).top + 8,
      child: Material(
        type: MaterialType.transparency,
        child: AnimatedBuilder(
          animation: Listenable.merge([
            driverMapLive.rev,
            driverMapLog.revision,
            driverMapExactConsent,
            driverMapReference,
          ]),
          builder: (context, _) => _expanded ? _panel(context) : _pill(context),
        ),
      ),
    );
  }

  Widget _pill(BuildContext context) {
    final s = driverMapLive;
    final provider = s.provider == null ? '—' : driverMapProviderWire(s.provider!);
    return GestureDetector(
      key: const ValueKey('driver-map-diag-pill'),
      onTap: () => setState(() => _expanded = true),
      child: _box(
        child: Text(
          'DIAG $provider ${s.follow ? '⟳' : '•'} #${driverMapLog.count}'
          '${s.duplicateDotWarning ? '  ‼' : ''}',
          style: _mono(s.duplicateDotWarning ? Colors.orangeAccent : Colors.white),
        ),
      ),
    );
  }

  Widget _panel(BuildContext context) {
    final s = driverMapLive;
    final size = MediaQuery.sizeOf(context);
    final exact = driverMapExactConsent.value;
    final ref = driverMapReference.value;
    final fix = _lastRawFix;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 260, maxHeight: size.height * 0.72),
      child: _box(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(child: Text('DRIVER MAP DIAG', style: _mono(Colors.white, bold: true))),
                  GestureDetector(
                    key: const ValueKey('driver-map-diag-collapse'),
                    onTap: () => setState(() => _expanded = false),
                    child: Text('▾', style: _mono(Colors.white)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (s.duplicateDotWarning)
                Text('‼ DUPLICATE DOT', style: _mono(Colors.orangeAccent, bold: true)),
              _row('platform', driverMapLog.meta.platform),
              _row('os', driverMapLog.meta.osVersion),
              _row('device', driverMapLog.meta.deviceModel),
              _row('build', driverMapLog.meta.appSha),
              _row('provider', '${s.provider == null ? '—' : driverMapProviderWire(s.provider!)}${s.satellite ? ' (sat)' : ''}'),
              _row('ready', '${s.mapReady}'),
              _row('follow', '${s.follow}'),
              _row('gesture', '${s.gesture}'),
              _row('anim', '${s.animationActive}'),
              _row('dot', dotRendererWire(s.dotRenderer)),
              _row('gps age', s.gpsAgeMs == null ? '—' : '${s.gpsAgeMs} ms'),
              _row('gps acc', s.gpsAccuracyM == null ? '—' : '${s.gpsAccuracyM!.toStringAsFixed(1)} m'),
              _row('speed', s.speedMps == null ? '—' : '${s.speedMps!.toStringAsFixed(1)} m/s'),
              _row('course', s.courseDeg == null ? '—' : '${s.courseDeg!.toStringAsFixed(0)}°'),
              _row('heading', s.headingDeg == null ? '—' : '${s.headingDeg!.toStringAsFixed(0)}°'),
              _row('zoom', s.cameraZoom == null ? '—' : s.cameraZoom!.toStringAsFixed(2)),
              _row('rotation', s.cameraRotationDeg == null ? '—' : '${s.cameraRotationDeg!.toStringAsFixed(1)}°'),
              _row('sheet', s.sheetInsetPx == null ? '—' : '${s.sheetInsetPx!.toStringAsFixed(0)} px'),
              _row('err px', s.errorPx == null ? 'N/A' : s.errorPx!.toStringAsFixed(1)),
              _row('ref', ref == null ? 'none' : 'locked @${ref.lockedElapsedMs}ms'),
              _row('events', '${driverMapLog.count}'),
              _row('last', driverMapLog.latest == null ? '—' : driverMapEventWire(driverMapLog.latest!.kind)),
              if (exact && fix != null)
                _row('coord', '${fix.lat.toStringAsFixed(5)}, ${fix.lng.toStringAsFixed(5)}'),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text('exact coords', style: _mono(Colors.white70)),
                  const Spacer(),
                  Switch(
                    key: const ValueKey('driver-map-diag-exact'),
                    value: exact,
                    onChanged: (v) {
                      driverMapExactConsent.value = v;
                      driverMapLog.record(DriverMapEvent(
                        kind: DriverMapEventKind.lifecycle,
                        elapsedMs: driverMapLog.elapsedMs,
                        timestampUtc: DateTime.now().toUtc(),
                        notes: 'exact_consent=$v',
                      ));
                    },
                  ),
                ],
              ),
              if (exact)
                Text('exposes precise locations', style: _mono(Colors.orangeAccent)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _btn('clear', const ValueKey('driver-map-diag-clear'), driverMapLog.clear),
                  _btn('JSONL', const ValueKey('driver-map-diag-jsonl'), () => exportDriverMapLog(csv: false)),
                  _btn('CSV', const ValueKey('driver-map-diag-csv'), () => exportDriverMapLog(csv: true)),
                  if (ref == null)
                    _btn('lock ref', const ValueKey('driver-map-diag-lockref'), lockDriverMapReferenceFromLastFix)
                  else
                    _btn('clear ref', const ValueKey('driver-map-diag-clearref'), clearDriverMapReference),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 68, child: Text(k, style: _mono(Colors.white54))),
        Expanded(child: Text(v, style: _mono(Colors.white))),
      ],
    ),
  );

  Widget _btn(String label, Key key, VoidCallback onTap) => GestureDetector(
    key: key,
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white24,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: _mono(Colors.white)),
    ),
  );

  Widget _box({required Widget child}) => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(8),
    ),
    child: child,
  );

  TextStyle _mono(Color color, {bool bold = false}) => TextStyle(
    color: color,
    fontSize: 11,
    height: 1.25,
    fontFamily: 'monospace',
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
  );
}
