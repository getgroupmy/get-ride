// Full vehicle interrogation, ported from the Expo app's
// `utils/canbus/vehicleScan.ts`.
//
// Walks everything a connected ELM327 can tell us about the car in one pass:
// the adapter's own identity, which mode-01 PIDs the vehicle implements and
// their current values, the emissions readiness monitors, the mode-09 identity
// block (VIN, calibration IDs, ECU name) and all three DTC stores.
//
// The scan takes a `send` function rather than a transport, so it is driven by
// the live OBD session in the app and by a plain stub in the tests: no
// hardware, no widgets. See test/vehicle_scan_test.dart.
import 'obd_pid_catalog.dart';
import 'vehicle_info.dart';

/// One decoded parameter as the screen renders it.
class VehicleReading {
  const VehicleReading({
    required this.pid,
    required this.label,
    required this.value,
    required this.group,
    required this.known,
    this.numeric,
  });

  /// Mode-01 PID, two hex digits.
  final String pid;
  final String label;

  /// Formatted for display, e.g. "13.842 V": never a bare number.
  final String value;
  final PidGroup group;

  /// False when the PID is supported by the car but absent from the catalogue.
  final bool known;

  /// The engineering value behind [value], for the panels that do arithmetic
  /// on a reading rather than print it (fuel range). Null for enumerated
  /// parameters and for raw fallbacks, which have no number.
  final double? numeric;
}

class LabelledValue {
  const LabelledValue({required this.key, required this.label, required this.value});
  final String key;
  final String label;
  final String value;
}

class VehicleScanReport {
  const VehicleScanReport({
    required this.supportedPids,
    required this.readings,
    required this.unreadablePids,
    required this.monitor,
    required this.identity,
    required this.vin,
    required this.dtcs,
    required this.adapter,
    required this.supportedMode09,
    required this.finishedAt,
  });

  /// Every mode-01 PID the vehicle reported as implemented.
  final List<String> supportedPids;

  /// PIDs that answered, decoded and formatted.
  final List<VehicleReading> readings;

  /// PIDs the car claims to support but that did not answer this pass.
  final List<String> unreadablePids;
  final MonitorStatus? monitor;
  final List<LabelledValue> identity;

  /// Raw VIN string, if the vehicle returned one.
  final String? vin;

  /// Codes per DTC store; a store that could not be read is absent.
  final Map<DtcStoreKey, List<String>> dtcs;
  final List<LabelledValue> adapter;

  /// Which mode-09 PIDs the vehicle said it implements.
  final List<String> supportedMode09;

  /// Milliseconds since the epoch.
  final int finishedAt;
}

class ScanProgress {
  const ScanProgress({required this.done, required this.total, required this.label});

  /// Commands issued so far.
  final int done;

  /// Best estimate of the total: it grows once the support masks come back.
  final int total;

  /// What is being read right now, e.g. "Engine coolant temperature".
  final String label;
}

typedef ScanProgressCallback = void Function(ScanProgress progress);

class ScanOptions {
  const ScanOptions({this.onProgress, this.shouldContinue});
  final ScanProgressCallback? onProgress;

  /// Return false to abandon the scan at the next step (screen disposed).
  final bool Function()? shouldContinue;
}

typedef SendCommand = Future<String> Function(String command);

/// PIDs that describe the *structure* of the response set rather than a
/// reading: the support bitmasks and the two monitor-status frames, both of
/// which are decoded into their own sections.
final _structuralPids = <String>{...supportRangePids, '01', '41'};

/// Interrogate the vehicle through [send].
///
/// The TS options bag is accepted as [options]; [onProgress] and
/// [shouldContinue] may also be passed directly and win over it.
Future<VehicleScanReport> scanVehicle(
  SendCommand send, {
  ScanOptions? options,
  ScanProgressCallback? onProgress,
  bool Function()? shouldContinue,
}) async {
  final progress = onProgress ?? options?.onProgress;
  final keepGoing = shouldContinue ?? options?.shouldContinue;
  bool alive() => keepGoing == null || keepGoing();

  // A fresh, empty report: new collections every scan.
  final supportedPids = <String>[];
  final readings = <VehicleReading>[];
  final unreadablePids = <String>[];
  MonitorStatus? monitor;
  final identity = <LabelledValue>[];
  String? vin;
  final dtcs = <DtcStoreKey, List<String>>{};
  final adapter = <LabelledValue>[];
  var supportedMode09 = <String>[];

  VehicleScanReport finish() => VehicleScanReport(
    supportedPids: supportedPids,
    readings: readings,
    unreadablePids: unreadablePids,
    monitor: monitor,
    identity: identity,
    vin: vin,
    dtcs: dtcs,
    adapter: adapter,
    supportedMode09: supportedMode09,
    finishedAt: DateTime.now().millisecondsSinceEpoch,
  );

  var done = 0;
  // A first guess: adapter probes, a couple of support masks, the monitor
  // frame, the mode-09 block and the three DTC stores. It is revised upward
  // once the support masks say how many parameters there actually are, and
  // clamped so a vehicle with more support ranges than guessed never reports
  // more steps done than exist.
  var total = adapterProbes.length + 2 + 1 + mode09Items.length + 1 + dtcModes.length;
  void step(String label) {
    done += 1;
    if (done > total) total = done;
    progress?.call(ScanProgress(done: done, total: total, label: label));
  }

  /// Send and swallow: one dead PID must never abort the whole scan.
  Future<String?> ask(String command) async {
    try {
      return await send(command);
    } catch (_) {
      return null;
    }
  }

  bool answered(String? raw) => raw != null && raw.isNotEmpty;

  // --- 1. The adapter itself -----------------------------------------------
  for (final probe in adapterProbes) {
    if (!alive()) return finish();
    step(probe.label);
    final raw = await ask(probe.command);
    final text = answered(raw) ? parseAtText(raw!) : null;
    if (text != null) {
      adapter.add(LabelledValue(key: probe.key, label: probe.label, value: text));
    }
  }

  // --- 2. Which mode-01 PIDs the vehicle implements ------------------------
  String? base = supportRangePids[0];
  while (base != null && alive()) {
    step('Supported parameters $base');
    final raw = await ask('01$base');
    final range = answered(raw) ? parseSupportedPids(raw!, base) : null;
    if (range == null) break;
    for (final pid in range.pids) {
      if (!supportedPids.contains(pid)) supportedPids.add(pid);
    }
    base = nextSupportRange(base, range);
  }

  // Now that the supported set is known, the estimate can be honest.
  final readablePids = supportedPids.where((pid) => !_structuralPids.contains(pid)).toList();
  total += readablePids.length;
  progress?.call(ScanProgress(done: done, total: total, label: 'Reading parameters'));

  // --- 3. Readiness monitors (mode 01 PID 01) ------------------------------
  if (alive()) {
    step('Readiness monitors');
    final raw = await ask('0101');
    monitor = answered(raw) ? parseMonitorStatusResponse(raw!) : null;
  }

  // --- 4. Every supported parameter ----------------------------------------
  for (final pid in readablePids) {
    if (!alive()) return finish();
    final known = catalogPid(pid);
    step(known?.label ?? 'PID 01$pid');
    final raw = await ask('01$pid');
    if (!answered(raw)) {
      unreadablePids.add(pid);
      continue;
    }
    final reading = decodeReading(pid, raw!);
    if (reading != null) {
      readings.add(reading);
    } else {
      unreadablePids.add(pid);
    }
  }

  // --- 5. Mode 09 identity --------------------------------------------------
  if (alive()) {
    step('Vehicle identity');
    final raw = await ask('0900');
    final range = answered(raw) ? parseSupportedPids(raw!, '00', '49') : null;
    supportedMode09 = range?.pids ?? <String>[];
  }

  for (final item in mode09Items) {
    if (!alive()) return finish();
    // An empty support list means the probe failed, not that nothing is
    // supported: ask anyway rather than silently skipping the VIN.
    final skip = supportedMode09.isNotEmpty && !supportedMode09.contains(item.pid);
    if (skip) {
      done += 1;
      continue;
    }
    step(item.label);
    final raw = await ask('09${item.pid}');
    if (!answered(raw)) continue;
    final value = item.ascii ? parseMode09Ascii(raw!, item.pid) : parseMode09Hex(raw!, item.pid);
    if (value == null) continue;
    identity.add(LabelledValue(key: item.key.name, label: item.label, value: value));
    if (item.key == Mode09Key.vin) vin = value;
  }

  // --- 6. Fault codes -------------------------------------------------------
  for (final store in dtcModes) {
    if (!alive()) return finish();
    step(store.label);
    final raw = await ask(store.mode);
    if (!answered(raw)) continue;
    final codes = parseDtcResponse(raw!, store.header);
    if (codes != null) dtcs[store.key] = codes;
  }

  return finish();
}

/// Decode one mode-01 reply into a display row.
///
/// A PID the catalogue knows gets its label, unit and engineering value; one it
/// does not gets its raw bytes, because "supported but undocumented here" is
/// still information the reader can genuinely read.
VehicleReading? decodeReading(String pid, String raw) {
  final key = pid.toUpperCase();
  final known = pidCatalog[key];
  if (known != null) {
    final bytes = extractFrameBytes(raw, '41$key', known.bytes);
    if (bytes != null) {
      final value = formatCatalogValue(known, bytes);
      if (value != null) {
        final numeric = known.decode?.call(bytes);
        return VehicleReading(
          pid: key,
          label: known.label,
          value: value,
          group: known.group,
          known: true,
          numeric: numeric != null && numeric.isFinite ? numeric : null,
        );
      }
    }
    // The catalogue expected more bytes than the ECU sent: fall through to the
    // raw rendering rather than dropping the parameter entirely.
  }
  final bytes = extractFrameBytes(raw, '41$key');
  if (bytes == null || bytes.isEmpty) return null;
  return VehicleReading(
    pid: key,
    label: known?.label ?? 'PID 01$key',
    value: formatRawBytes(bytes),
    group: known?.group ?? PidGroup.other,
    known: false,
  );
}

/// Group readings for rendering, dropping groups with nothing in them.
List<({PidGroup group, List<VehicleReading> readings})> groupReadings(
  List<VehicleReading> readings,
  List<PidGroup> order,
) => [
  for (final group in order)
    if (readings.where((r) => r.group == group).toList() case final inGroup when inGroup.isNotEmpty)
      (group: group, readings: inGroup),
];
