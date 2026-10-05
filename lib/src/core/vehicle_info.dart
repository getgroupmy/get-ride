// Vehicle Information: the read/write protocol layer behind the Vehicle
// Information screen, ported from the Expo app's `utils/canbus/vehicleInfo.ts`.
//
// Where obd.dart covers the handful of mode-01 PIDs the live telemetry loop
// polls, this module covers everything *else* an ELM327 can be asked for once:
// which PIDs the car actually implements (mode 01 support bitmasks), its
// identity (mode 09: VIN, calibration IDs, ECU name), its fault state (mode
// 03/07 diagnostic trouble codes and the mode 01 PID 01 readiness monitors),
// and the small set of things that can legitimately be *written* back (mode 04
// clear-codes, adapter configuration, raw commands).
//
// Everything here is pure string/number crunching (no transport, no widgets),
// so the whole surface is unit-tested in test/vehicle_info_test.dart.
import 'obd.dart';

/* ------------------------------------------------------------------ *
 * Frame extraction
 * ------------------------------------------------------------------ */

/// Non-data replies that must never be parsed as hex.
const _noiseTokens = ['SEARCHING', 'BUSINIT', 'BUS INIT', 'NODATA', 'STOPPED', 'ERROR', 'UNABLETOCONNECT', 'OK', '?'];

bool _isNoiseLine(String line) => _noiseTokens.any((t) => line == t || line.startsWith(t));

final _indexedFrameRe = RegExp(r'^([0-9A-F]):([0-9A-F]*)$');
final _lengthHeaderRe = RegExp(r'^[0-9A-F]{3}$');
final _hexLineRe = RegExp(r'^[0-9A-F]+$');
final _octetRe = RegExp(r'^[0-9A-F]{2}$');

/// Split a raw adapter response into candidate payload hex strings.
///
/// A short answer is one line per responding ECU. A long one (mode 09, a big
/// DTC list) arrives as an ISO-TP multi-frame block, which the ELM327 prints
/// as a three-digit total-length header followed by `N:` indexed continuation
/// lines:
///
///     014
///     0:490201314A
///     1:4D3448...
///
/// The indexed lines are re-joined into one payload; every other line is a
/// candidate in its own right.
List<String> elmPayloads(String raw) {
  final indexed = <String>[];
  final plain = <String>[];
  for (final line in cleanElmResponse(raw)) {
    if (_isNoiseLine(line)) continue;
    final framed = _indexedFrameRe.firstMatch(line);
    if (framed != null) {
      indexed.add(framed.group(2)!);
      continue;
    }
    // A bare three-hex-digit line is the multi-frame length header. Real data
    // frames always carry an even number of hex characters, so this can never
    // discard a payload.
    if (_lengthHeaderRe.hasMatch(line)) continue;
    if (!_hexLineRe.hasMatch(line)) continue;
    plain.add(line);
  }
  final payloads = [...plain];
  if (indexed.isNotEmpty) payloads.add(indexed.join());
  return payloads;
}

/// Convert an even-length hex string to bytes, or null if it is malformed.
List<int>? hexToBytes(String hex) {
  if (hex.isEmpty || hex.length % 2 != 0) return null;
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    final octet = hex.substring(i, i + 2);
    if (!_octetRe.hasMatch(octet)) return null;
    bytes.add(int.parse(octet, radix: 16));
  }
  return bytes;
}

/// Pull the data bytes that follow a response header out of a raw reply.
///
/// [header] is the positive-response header including the mode, e.g. "4100"
/// for mode 01 PID 00 or "4902" for mode 09 PID 02. With [byteCount] omitted
/// every remaining byte is returned; with it set the frame must carry at least
/// that many and exactly that many are returned.
List<int>? extractFrameBytes(String raw, String header, [int? byteCount]) {
  if (isElmError(raw)) return null;
  final wanted = header.toUpperCase();
  for (final payload in elmPayloads(raw)) {
    final idx = payload.indexOf(wanted);
    if (idx == -1) continue;
    var dataHex = payload.substring(idx + wanted.length);
    if (byteCount != null) {
      if (dataHex.length < byteCount * 2) continue;
      dataHex = dataHex.substring(0, byteCount * 2);
    } else if (dataHex.length % 2 != 0) {
      // Trailing half byte: the frame is truncated, drop it.
      dataHex = dataHex.substring(0, dataHex.length - 1);
    }
    final bytes = hexToBytes(dataHex);
    if (bytes != null) return bytes;
  }
  return null;
}

String _hex2(int value) => value.toRadixString(16).toUpperCase().padLeft(2, '0');

/* ------------------------------------------------------------------ *
 * Supported-PID discovery (mode 01, PIDs 00/20/40/…)
 * ------------------------------------------------------------------ */

/// The mode-01 "which PIDs are supported" probes, in order. Each one answers
/// with a 32-bit mask covering the next 32 PIDs; the last bit of each mask says
/// whether it is worth asking the next probe at all.
const supportRangePids = ['00', '20', '40', '60', '80', 'A0', 'C0', 'E0'];

class SupportedRange {
  const SupportedRange({required this.base, required this.pids, required this.nextRangeSupported});

  /// The probe PID this mask answered, e.g. "20".
  final String base;

  /// Supported PIDs in this range, as two-digit upper-case hex.
  final List<String> pids;

  /// True when the mask's last bit says the next range is also supported.
  final bool nextRangeSupported;
}

/// Decode a support bitmask response.
///
/// The four data bytes are a big-endian bit field: the most significant bit of
/// the first byte is `base + 1`, the least significant bit of the last byte is
/// `base + 32` (which doubles as the "next range supported" flag).
SupportedRange? parseSupportedPids(String raw, String base, [String responseMode = '41']) {
  final key = base.toUpperCase();
  final bytes = extractFrameBytes(raw, responseMode.toUpperCase() + key, 4);
  if (bytes == null) return null;
  final start = int.tryParse(key, radix: 16);
  if (start == null) return null;
  final pids = <String>[];
  for (var bit = 0; bit < 32; bit++) {
    final byte = bytes[bit >> 3];
    final isSet = (byte & (0x80 >> (bit & 7))) != 0;
    if (!isSet) continue;
    pids.add(_hex2(start + bit + 1));
  }
  final nextBase = _hex2(start + 0x20);
  return SupportedRange(base: key, pids: pids, nextRangeSupported: pids.contains(nextBase));
}

/// Which probe PID to ask next after [base], or null when the mask said the
/// following range is unsupported (or we ran off the end of the table).
String? nextSupportRange(String base, SupportedRange? range) {
  if (range == null || !range.nextRangeSupported) return null;
  final idx = supportRangePids.indexOf(base.toUpperCase());
  if (idx == -1 || idx + 1 >= supportRangePids.length) return null;
  return supportRangePids[idx + 1];
}

/* ------------------------------------------------------------------ *
 * Mode 09: vehicle identity
 * ------------------------------------------------------------------ */

enum Mode09Key { vin, calibrationId, cvn, ecuName }

class Mode09Item {
  const Mode09Item({required this.pid, required this.key, required this.label, required this.ascii});
  final String pid;
  final Mode09Key key;
  final String label;
  final bool ascii;
}

/// Mode-09 requests the screen makes, in display order.
const mode09Items = [
  Mode09Item(pid: '02', key: Mode09Key.vin, label: 'VIN', ascii: true),
  Mode09Item(pid: '04', key: Mode09Key.calibrationId, label: 'Calibration ID', ascii: true),
  Mode09Item(pid: '06', key: Mode09Key.cvn, label: 'Calibration verification number', ascii: false),
  Mode09Item(pid: '0A', key: Mode09Key.ecuName, label: 'ECU name', ascii: true),
];

/// Decode a mode-09 ASCII payload (VIN, calibration ID, ECU name).
///
/// The bytes after the `49 <pid>` header start with a message-count byte on
/// CAN vehicles and go straight into ASCII on the older protocols. Printable
/// ASCII starts at 0x20, so a leading byte below that can only be the count and
/// is dropped. NUL and 0xFF padding is stripped; other non-printable bytes are
/// dropped.
String? parseMode09Ascii(String raw, String pid) {
  final bytes = extractFrameBytes(raw, '49${pid.toUpperCase()}');
  if (bytes == null || bytes.isEmpty) return null;
  final body = bytes[0] < 0x20 ? bytes.sublist(1) : bytes;
  final text = body
      .where((b) => b != 0x00 && b != 0xff)
      .map((b) => b >= 0x20 && b <= 0x7e ? String.fromCharCode(b) : '')
      .join()
      .trim();
  return text.isNotEmpty ? text : null;
}

/// Decode a mode-09 payload that is binary rather than text (the CVN).
String? parseMode09Hex(String raw, String pid) {
  final bytes = extractFrameBytes(raw, '49${pid.toUpperCase()}');
  if (bytes == null || bytes.isEmpty) return null;
  final body = bytes[0] <= 0x04 && bytes.length > 4 ? bytes.sublist(1) : bytes;
  final hex = body.map(_hex2).join(' ').trim();
  return hex.isNotEmpty ? hex : null;
}

/// ISO 3779 VIN charset: I, O and Q are excluded to avoid 1/0 confusion.
final _vinRe = RegExp(r'^[A-HJ-NPR-Z0-9]{17}$');

bool isLikelyVin(String? value) => value != null && value.isNotEmpty && _vinRe.hasMatch(value.toUpperCase());

/// World Manufacturer Identifier lookup for the makes GET.ride fleets actually
/// run. Best-effort only: an unknown WMI simply yields null rather than a
/// guess, and nothing downstream depends on it.
const _wmiRegions = <(String, String)>[
  ('PM', 'Malaysia'),
  ('PN', 'Malaysia'),
  ('PL', 'Malaysia'),
  ('MH', 'Indonesia'),
  ('MM', 'Thailand'),
  ('MR', 'Thailand'),
  ('JH', 'Japan'),
  ('JM', 'Japan'),
  ('JN', 'Japan'),
  ('JT', 'Japan'),
  ('KM', 'South Korea'),
  ('KN', 'South Korea'),
  ('LB', 'China'),
  ('LS', 'China'),
  ('LV', 'China'),
  ('WA', 'Germany'),
  ('WB', 'Germany'),
  ('WD', 'Germany'),
  ('WV', 'Germany'),
  ('SA', 'United Kingdom'),
  ('SB', 'United Kingdom'),
  ('VF', 'France'),
  ('ZF', 'Italy'),
  ('1F', 'United States'),
  ('1G', 'United States'),
  ('5Y', 'United States'),
];

/// Model-year code from VIN position 10, per ISO 3779.
const _vinYearCodes = 'ABCDEFGHJKLMNPRSTVWXY123456789';

class VinDetails {
  const VinDetails({
    required this.vin,
    required this.wmi,
    required this.region,
    required this.vds,
    required this.vis,
    required this.modelYears,
    required this.plantCode,
    required this.serial,
  });

  final String vin;

  /// Positions 1-3: who built it.
  final String wmi;

  /// Best-effort assembly region for the WMI, or null when unrecognised.
  final String? region;

  /// Positions 4-9.
  final String vds;

  /// Positions 10-17.
  final String vis;

  /// Model year decoded from position 10. The code repeats every 30 years, so
  /// every candidate up to next year is returned oldest-first and the caller
  /// shows the newer one unless it is in the future.
  final List<int> modelYears;

  /// Position 11: the assembly plant code.
  final String plantCode;

  /// Positions 12-17: the serial number.
  final String serial;
}

/// Break a VIN into its ISO 3779 fields. Returns null for anything that is not
/// a well-formed 17-character VIN: a partial read is never dressed up as one.
VinDetails? decodeVin(String? vin, [DateTime? now]) {
  if (vin == null || !isLikelyVin(vin)) return null;
  final value = vin.toUpperCase();
  final wmi = value.substring(0, 3);
  final yearIndex = _vinYearCodes.indexOf(value[9]);
  final modelYears = <int>[];
  if (yearIndex != -1) {
    // JS `getFullYear` is local time.
    final thisYear = (now ?? DateTime.now()).toLocal().year;
    for (var year = 1980 + yearIndex; year <= thisYear + 1; year += 30) {
      modelYears.add(year);
    }
  }
  String? region;
  for (final (prefix, label) in _wmiRegions) {
    if (wmi.startsWith(prefix)) {
      region = label;
      break;
    }
  }
  return VinDetails(
    vin: value,
    wmi: wmi,
    region: region,
    vds: value.substring(3, 9),
    vis: value.substring(9),
    modelYears: modelYears,
    plantCode: value[10],
    serial: value.substring(11),
  );
}

/* ------------------------------------------------------------------ *
 * Diagnostic trouble codes (modes 03, 07 and 0A)
 * ------------------------------------------------------------------ */

enum DtcStoreKey { stored, pending, permanent }

class DtcMode {
  const DtcMode({required this.mode, required this.header, required this.key, required this.label, required this.hint});
  final String mode;
  final String header;
  final DtcStoreKey key;
  final String label;
  final String hint;
}

/// The three DTC stores, with the mode that reads each.
const dtcModes = [
  DtcMode(
    mode: '03',
    header: '43',
    key: DtcStoreKey.stored,
    label: 'Stored codes',
    hint: 'Confirmed faults — these are what turn the check-engine light on.',
  ),
  DtcMode(
    mode: '07',
    header: '47',
    key: DtcStoreKey.pending,
    label: 'Pending codes',
    hint: 'Seen once and not yet confirmed. They clear themselves if the fault does not repeat.',
  ),
  DtcMode(
    mode: '0A',
    header: '4A',
    key: DtcStoreKey.permanent,
    label: 'Permanent codes',
    hint: 'Cannot be cleared by a scan tool — the vehicle erases them itself once the repair is verified.',
  ),
];

const _dtcSystemLetters = ['P', 'C', 'B', 'U'];

/// Decode one two-byte DTC into its SAE J2012 code, e.g. [0x01, 0x33] →
/// "P0133". A pair of zero bytes is padding, not a code, and yields null.
String? decodeDtc(int a, int b) {
  if (a == 0 && b == 0) return null;
  final system = _dtcSystemLetters[(a >> 6) & 0x03];
  String h(int v) => v.toRadixString(16).toUpperCase();
  return system + h((a >> 4) & 0x03) + h(a & 0x0f) + h((b >> 4) & 0x0f) + h(b & 0x0f);
}

final _noDataRe = RegExp(r'NO\s*DATA', caseSensitive: false);

/// Parse a DTC list out of a mode 03/07/0A response.
///
/// CAN vehicles prefix the code pairs with a count byte and older protocols do
/// not, which is unambiguous from the length: count + 2n bytes is odd, 2n bytes
/// alone is even. Returns an empty list when the vehicle reports no codes, and
/// null only when the response could not be parsed at all.
List<String>? parseDtcResponse(String raw, String header) {
  final bytes = extractFrameBytes(raw, header.toUpperCase());
  if (bytes == null) {
    // "NO DATA" is a legitimate answer meaning "nothing stored", not a failure.
    return isElmError(raw) && _noDataRe.hasMatch(raw) ? <String>[] : null;
  }
  final body = bytes.length % 2 == 1 ? bytes.sublist(1) : bytes;
  final codes = <String>[];
  for (var i = 0; i + 1 < body.length; i += 2) {
    final code = decodeDtc(body[i], body[i + 1]);
    if (code != null && !codes.contains(code)) codes.add(code);
  }
  return codes;
}

/// Which vehicle system a code's letter refers to.
const _dtcSystemNames = {'P': 'Powertrain', 'C': 'Chassis', 'B': 'Body', 'U': 'Network'};

/// Fault area for the powertrain code families (the "P0xyz" second digit).
const _powertrainAreas = {
  '0': 'Fuel and air metering, auxiliary emission controls',
  '1': 'Fuel and air metering',
  '2': 'Fuel and air metering — injector circuit',
  '3': 'Ignition system or misfire',
  '4': 'Auxiliary emission controls',
  '5': 'Vehicle speed, idle control, auxiliary inputs',
  '6': 'Computer output circuit',
  '7': 'Transmission',
  '8': 'Transmission',
  '9': 'Transmission / control module',
};

/// The character at [i], or null past the end (JS `s[i]` is undefined there).
String? _charAt(String s, int i) => i < s.length ? s[i] : null;

/// A short, honest description of what a code covers.
///
/// Full fault text is manufacturer-specific and runs to thousands of entries,
/// so this deliberately describes the *family* the code belongs to rather than
/// inventing a specific diagnosis.
String describeDtc(String code) {
  final value = code.trim().toUpperCase();
  final letter = _charAt(value, 0);
  final system = _dtcSystemNames[letter] ?? 'Unknown system';
  final second = _charAt(value, 1);
  final generic = second == '0' || second == '2';
  final scope = generic ? 'generic (SAE)' : 'manufacturer-specific';
  if (letter == 'P') {
    final area = _powertrainAreas[_charAt(value, 2)];
    return area != null ? '$system — $area · $scope' : '$system · $scope';
  }
  return '$system · $scope';
}

/* ------------------------------------------------------------------ *
 * Readiness monitors (mode 01, PID 01)
 * ------------------------------------------------------------------ */

class ReadinessMonitor {
  const ReadinessMonitor({required this.key, required this.label, required this.supported, required this.complete});
  final String key;
  final String label;

  /// The vehicle implements this monitor.
  final bool supported;

  /// The monitor has finished its self-test since the last code clear.
  final bool complete;
}

class MonitorStatus {
  const MonitorStatus({
    required this.milOn,
    required this.dtcCount,
    required this.compressionIgnition,
    required this.monitors,
  });

  /// Malfunction indicator lamp: the check-engine light.
  final bool milOn;

  /// Number of confirmed emission-related faults stored.
  final int dtcCount;

  /// True for a diesel (compression ignition) engine.
  final bool compressionIgnition;
  final List<ReadinessMonitor> monitors;
}

typedef _MonitorDef = ({String key, String label, int bit});

const List<_MonitorDef> _continuousMonitors = [
  (key: 'misfire', label: 'Misfire', bit: 0),
  (key: 'fuelSystem', label: 'Fuel system', bit: 1),
  (key: 'components', label: 'Components', bit: 2),
];

const List<_MonitorDef> _sparkMonitors = [
  (key: 'catalyst', label: 'Catalyst', bit: 0),
  (key: 'heatedCatalyst', label: 'Heated catalyst', bit: 1),
  (key: 'evap', label: 'Evaporative system', bit: 2),
  (key: 'secondaryAir', label: 'Secondary air system', bit: 3),
  (key: 'acRefrigerant', label: 'A/C refrigerant', bit: 4),
  (key: 'oxygenSensor', label: 'Oxygen sensor', bit: 5),
  (key: 'oxygenSensorHeater', label: 'Oxygen sensor heater', bit: 6),
  (key: 'egr', label: 'EGR system', bit: 7),
];

const List<_MonitorDef> _dieselMonitors = [
  (key: 'nmhcCatalyst', label: 'NMHC catalyst', bit: 0),
  (key: 'noxAftertreatment', label: 'NOx / SCR aftertreatment', bit: 1),
  (key: 'boostPressure', label: 'Boost pressure', bit: 3),
  (key: 'exhaustGasSensor', label: 'Exhaust gas sensor', bit: 5),
  (key: 'pmFilter', label: 'Particulate filter', bit: 6),
  (key: 'egrVvt', label: 'EGR and VVT', bit: 7),
];

/// Decode the mode-01 PID 01 monitor-status frame.
///
/// Byte A carries the MIL flag and the stored-fault count; byte B the three
/// continuously-monitored systems plus the spark/compression engine flag;
/// bytes C and D the non-continuous monitors, C saying which exist and D which
/// have *not* finished yet (so "complete" is the inverted bit).
MonitorStatus? parseMonitorStatus(List<int> bytes) {
  if (bytes.length < 4) return null;
  final [a, b, c, d, ...] = bytes;
  final compressionIgnition = (b & 0x08) != 0;
  final monitors = [
    for (final m in _continuousMonitors)
      ReadinessMonitor(
        key: m.key,
        label: m.label,
        supported: (b & (1 << m.bit)) != 0,
        // The "incomplete" flags for the continuous monitors sit in the high
        // nibble of the same byte, four bits above their support flag.
        complete: (b & (1 << (m.bit + 4))) == 0,
      ),
    for (final m in compressionIgnition ? _dieselMonitors : _sparkMonitors)
      ReadinessMonitor(
        key: m.key,
        label: m.label,
        supported: (c & (1 << m.bit)) != 0,
        complete: (d & (1 << m.bit)) == 0,
      ),
  ];
  return MonitorStatus(
    milOn: (a & 0x80) != 0,
    dtcCount: a & 0x7f,
    compressionIgnition: compressionIgnition,
    monitors: monitors,
  );
}

/// Read the monitor-status frame straight out of a raw "0101" response.
MonitorStatus? parseMonitorStatusResponse(String raw) {
  final bytes = extractFrameBytes(raw, '4101', 4);
  return bytes != null ? parseMonitorStatus(bytes) : null;
}

/* ------------------------------------------------------------------ *
 * Adapter identity (AT commands)
 * ------------------------------------------------------------------ */

class AdapterProbe {
  const AdapterProbe({required this.command, required this.key, required this.label});
  final String command;
  final String key;
  final String label;
}

/// Adapter-level probes shown under "Reader".
const adapterProbes = [
  AdapterProbe(command: 'ATI', key: 'firmware', label: 'Adapter firmware'),
  AdapterProbe(command: 'AT@1', key: 'deviceDescription', label: 'Device description'),
  AdapterProbe(command: 'ATRV', key: 'batteryVoltage', label: 'Battery voltage (adapter)'),
  AdapterProbe(command: 'ATDP', key: 'protocol', label: 'Protocol'),
];

/// Take the first meaningful line out of an AT-command reply.
///
/// An adapter that does not implement a probe answers with an error token
/// rather than staying silent, so those are rejected: "NO DATA" is not a
/// device description.
String? parseAtText(String raw) {
  if (isElmError(raw)) return null;
  final lines = cleanElmResponse(raw).where((line) => line.isNotEmpty && line != 'OK' && line != '?').toList();
  if (lines.isEmpty) return null;
  // cleanElmResponse upper-cases and strips spaces, which mangles version
  // strings, so re-derive the display text from the original.
  final original = raw
      .replaceAll('>', '')
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && line != 'OK' && line != '?')
      .toList();
  return original.isNotEmpty ? original.first : lines.first;
}

/* ------------------------------------------------------------------ *
 * Writes
 * ------------------------------------------------------------------ */

enum VehicleWriteId {
  clearDtc('clear-dtc'),
  resetAdapter('reset-adapter'),
  setProtocol('set-protocol'),
  rawCommand('raw-command');

  const VehicleWriteId(this.id);

  /// The TS string id, e.g. "clear-dtc".
  final String id;
}

/// Whether a command reaches the car's ECUs or stops at the dongle.
enum WriteTarget { vehicle, adapter }

class VehicleWriteAction {
  const VehicleWriteAction({
    required this.id,
    required this.label,
    required this.description,
    required this.target,
    required this.destructive,
    required this.warningTitle,
    required this.warningBody,
    required this.confirmLabel,
  });

  final VehicleWriteId id;
  final String label;
  final String description;

  /// Whether the command reaches the car's ECUs or stops at the dongle. Only
  /// `vehicle` writes can change how the car behaves, and they are the ones
  /// gated on the vehicle being stationary.
  final WriteTarget target;

  /// Shown in red and confirmed with a destructive-styled button.
  final bool destructive;
  final String warningTitle;
  final String warningBody;
  final String confirmLabel;
}

/// The writes this screen offers.
///
/// Deliberately short. Generic OBD-II defines exactly one universally
/// implemented write to the vehicle (mode 04, "clear diagnostic information")
/// and everything else a scan tool appears to "program" is manufacturer-
/// specific and outside what an ELM327 can safely be asked to do. The rest of
/// the list configures the *adapter*, which is harmless but still worth a
/// confirmation because it interrupts the live link.
const vehicleWriteActions = [
  VehicleWriteAction(
    id: VehicleWriteId.clearDtc,
    label: 'Clear trouble codes',
    description: 'Mode 04 — erases stored and pending fault codes, switches the check-engine light off and resets the readiness monitors.',
    target: WriteTarget.vehicle,
    destructive: true,
    warningTitle: 'Clear diagnostic trouble codes?',
    warningBody: 'This writes to your vehicle\'s ECU. It erases stored and pending fault codes, turns off the check-engine light and resets every readiness monitor to "not ready".\n\nThe underlying fault is not repaired — if it is still present the code comes back. Clearing also wipes the emissions readiness data, so the vehicle may fail an inspection until it has completed a full drive cycle.\n\nOnly do this with the engine off and the vehicle stationary.',
    confirmLabel: 'Clear codes',
  ),
  VehicleWriteAction(
    id: VehicleWriteId.setProtocol,
    label: 'Set CAN protocol',
    description: 'Pins the adapter to a specific OBD-II protocol instead of auto-detecting it. Useful when a vehicle negotiates the wrong one.',
    target: WriteTarget.adapter,
    destructive: false,
    warningTitle: 'Change the adapter protocol?',
    warningBody: 'This reconfigures the reader, not the vehicle. The live link drops while it re-negotiates, and picking a protocol your vehicle does not speak means no data at all until you set it back to automatic.',
    confirmLabel: 'Set protocol',
  ),
  VehicleWriteAction(
    id: VehicleWriteId.resetAdapter,
    label: 'Reset reader',
    description: 'Sends ATZ — a full adapter reset, as if it had been unplugged and plugged back in. Does not touch the vehicle.',
    target: WriteTarget.adapter,
    destructive: false,
    warningTitle: 'Reset the reader?',
    warningBody: 'The adapter restarts and the link drops. Nothing is written to the vehicle. The app reconnects afterwards, which takes a few seconds.',
    confirmLabel: 'Reset reader',
  ),
  VehicleWriteAction(
    id: VehicleWriteId.rawCommand,
    label: 'Send raw command',
    description: 'Sends a command straight to the adapter. For diagnosing an uncooperative reader, or for vehicle-specific commands you already know.',
    target: WriteTarget.vehicle,
    destructive: true,
    warningTitle: 'Send a raw command?',
    warningBody: 'Raw commands are passed to the adapter, and OBD-II service commands are passed on to your vehicle\'s ECUs, unchecked.\n\nA mistyped command is usually harmless — the adapter answers "?" — but the writing services (04, 08, 2F, 31, 3E and the manufacturer-specific ranges) can change how the vehicle runs, clear data you cannot restore, or leave a module in a diagnostic state until it is power-cycled.\n\nOnly send commands you understand, with the vehicle stationary.',
    confirmLabel: 'Send command',
  ),
];

VehicleWriteAction? findWriteAction(VehicleWriteId id) {
  for (final a in vehicleWriteActions) {
    if (a.id == id) return a;
  }
  return null;
}

class WriteContext {
  const WriteContext({required this.online, required this.simulated, this.speedKmh, this.supportsClearDtc});

  /// The session is up (phase "online").
  final bool online;

  /// The link is the built-in simulator rather than a real dongle.
  final bool simulated;

  /// Latest vehicle speed in km/h, or null when it is not being reported.
  final double? speedKmh;

  /// Whether the ECU listed mode 04 as available. null means "not probed yet"
  /// and is treated as allowed: mode 04 is mandatory on every OBD-II vehicle,
  /// so refusing on a missing probe would block a legitimate write.
  final bool? supportsClearDtc;
}

class WriteAvailability {
  const WriteAvailability({required this.allowed, this.reason});
  final bool allowed;

  /// Why the write is blocked: shown in place of the button's subtitle.
  final String? reason;
}

/// Decide whether a write may be attempted right now.
///
/// The rules, in the order a driver would hit them: there has to be a link, it
/// has to be a real one (simulated telemetry must never be presented as having
/// written to a car), and a write that reaches the ECUs is refused while the
/// vehicle is moving.
WriteAvailability evaluateWriteAvailability(VehicleWriteAction action, WriteContext ctx) {
  if (!ctx.online) {
    return const WriteAvailability(allowed: false, reason: 'Connect the OBD-II reader first.');
  }
  if (ctx.simulated) {
    return const WriteAvailability(
      allowed: false,
      reason: 'Demo Mode is virtual data — nothing can be written to a vehicle.',
    );
  }
  if (action.target == WriteTarget.vehicle && (ctx.speedKmh ?? 0) > 0) {
    return const WriteAvailability(allowed: false, reason: 'Stop the vehicle before writing to it.');
  }
  if (action.id == VehicleWriteId.clearDtc && ctx.supportsClearDtc == false) {
    return const WriteAvailability(
      allowed: false,
      reason: 'This vehicle did not report mode 04 (clear codes) as supported.',
    );
  }
  return const WriteAvailability(allowed: true);
}

/* ------------------------------------------------------------------ *
 * Raw command validation
 * ------------------------------------------------------------------ */

/// OBD-II services that write to, or command, the vehicle rather than just
/// reading from it. Used to escalate the warning on a raw command.
const _writeServices = ['04', '08', '2E', '2F', '31', '3E', '85', '87'];

class RawCommandCheck {
  const RawCommandCheck({required this.ok, this.command, this.target, this.write, this.error});
  final bool ok;

  /// Normalised command, ready to send (upper case, spaces stripped).
  final String? command;

  /// Whether it configures the adapter or is forwarded to the vehicle.
  final WriteTarget? target;

  /// True when the command is a vehicle service that can change state.
  final bool? write;
  final String? error;
}

final _whitespaceRe = RegExp(r'\s+');
final _commandCharsRe = RegExp(r'^[A-Z0-9@]+$');

/// Validate and normalise a hand-typed command.
///
/// ELM327 commands are ASCII alphanumerics (`ATSP6`, `0100`, `09 02`); anything
/// else is a typo, and sending it just makes the adapter answer "?". Length is
/// capped well under the ELM327's own line buffer.
RawCommandCheck validateRawCommand(String? input) {
  final command = (input ?? '').replaceAll(_whitespaceRe, '').toUpperCase();
  if (command.isEmpty) {
    return const RawCommandCheck(ok: false, error: 'Enter a command.');
  }
  if (command.length > 24) {
    return const RawCommandCheck(ok: false, error: 'Commands are at most 24 characters.');
  }
  if (!_commandCharsRe.hasMatch(command)) {
    return const RawCommandCheck(ok: false, error: 'Only letters, digits and @ are valid in an ELM327 command.');
  }
  if (command.startsWith('AT') || command.startsWith('ST')) {
    return RawCommandCheck(ok: true, command: command, target: WriteTarget.adapter, write: false);
  }
  if (command.length % 2 != 0) {
    return const RawCommandCheck(
      ok: false,
      error: 'An OBD-II request is whole bytes — use an even number of hex digits.',
    );
  }
  if (!_hexLineRe.hasMatch(command)) {
    return const RawCommandCheck(ok: false, error: 'An OBD-II request is hexadecimal. Adapter commands start with AT.');
  }
  return RawCommandCheck(
    ok: true,
    command: command,
    target: WriteTarget.vehicle,
    write: _writeServices.contains(command.substring(0, 2)),
  );
}

/// Did a write command actually succeed? ELM327 answers "OK" or a positive
/// response.
bool isWriteAcknowledged(String raw, [String? expectedHeader]) {
  if (isElmError(raw)) return false;
  final lines = cleanElmResponse(raw);
  if (lines.isEmpty) return false;
  if (lines.contains('OK')) return true;
  if (expectedHeader != null && expectedHeader.isNotEmpty) {
    final wanted = expectedHeader.toUpperCase();
    return lines.any((line) => line.contains(wanted));
  }
  return true;
}
