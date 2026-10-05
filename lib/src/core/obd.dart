// The ELM327 / OBD-II protocol, ported from the Expo app's
// `utils/canbus/obd.ts`. Pure: the session client (data/obd/obd_client.dart)
// sends the commands and feeds the replies through these parsers.
//
// An ELM327 adapter speaks ASCII hex over any link (Wi-Fi socket, Bluetooth,
// USB serial): a command ends with a carriage return, and the reply ends with
// the `>` prompt.

const elmCr = '\r';
const elmPrompt = '>';

/// Reset, echo off, linefeeds off, spaces off, headers off, auto protocol.
const elmInitCommands = ['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0'];

/// "Describe protocol by number": what the auto search settled on.
const elmDescribeProtocol = 'ATDPN';

const _protocolNames = {
  '0': 'Auto',
  '1': 'SAE J1850 PWM',
  '2': 'SAE J1850 VPW',
  '3': 'ISO 9141-2',
  '4': 'ISO 14230-4 (KWP 5-baud)',
  '5': 'ISO 14230-4 (KWP fast)',
  '6': 'ISO 15765-4 CAN (11-bit, 500 kbps)',
  '7': 'ISO 15765-4 CAN (29-bit, 500 kbps)',
  '8': 'ISO 15765-4 CAN (11-bit, 250 kbps)',
  '9': 'ISO 15765-4 CAN (29-bit, 250 kbps)',
  'A': 'SAE J1939 CAN (29-bit, 250 kbps)',
};

/// ELM327 protocol codes (ATSPn) and their names, for picking one by hand.
const elmProtocolNames = _protocolNames;

const _protocolBitrate = {'6': 500, '7': 500, '8': 250, '9': 250, 'A': 250};

/// The protocol name and bit rate for an `ATDPN` answer ("6", or "A6" when
/// it was found by auto search).
({String name, int? bitrateKbps}) describeProtocol(String? number) {
  if (number == null || number.isEmpty) return (name: 'Unknown', bitrateKbps: null);
  final key = number.replaceFirst(RegExp(r'^A(?=.)', caseSensitive: false), '').toUpperCase();
  return (name: _protocolNames[key] ?? 'Protocol $number', bitrateKbps: _protocolBitrate[key]);
}

/// One mode-01 parameter: its PID, how many data bytes it answers with, and
/// how those bytes become a value.
class ObdPid {
  const ObdPid(this.pid, this.key, this.label, this.unit, this.bytes, this.decode);
  final String pid;
  final String key;
  final String label;
  final String unit;
  final int bytes;
  final double Function(List<int> b) decode;

  /// The command that asks for it: mode 01 + PID.
  String get command => '01${pid.toUpperCase()}';
}

/// The 1 Hz sweep. Kept short on purpose: the adapter answers one command at
/// a time, so every PID here delays the next speed reading.
final obdPids = <String, ObdPid>{
  'rpm': ObdPid('0C', 'rpm', 'Engine RPM', 'rpm', 2, (b) => (b[0] * 256 + b[1]) / 4),
  'speed': ObdPid('0D', 'speed', 'Vehicle speed', 'km/h', 1, (b) => b[0].toDouble()),
  'coolantTemp': ObdPid('05', 'coolantTemp', 'Coolant temp', '°C', 1, (b) => b[0] - 40.0),
  'engineLoad': ObdPid('04', 'engineLoad', 'Engine load', '%', 1, (b) => b[0] * 100 / 255),
  'throttle': ObdPid('11', 'throttle', 'Throttle', '%', 1, (b) => b[0] * 100 / 255),
  'fuelLevel': ObdPid('2F', 'fuelLevel', 'Fuel level', '%', 1, (b) => b[0] * 100 / 255),
  'moduleVoltage': ObdPid('42', 'moduleVoltage', 'Battery / ECU voltage', 'V', 2, (b) => (b[0] * 256 + b[1]) / 1000),
  'intakeTemp': ObdPid('0F', 'intakeTemp', 'Intake air temp', '°C', 1, (b) => b[0] - 40.0),
};

/// The odometer (PID A6, 4 bytes, tenths of a km). Not in the sweep: it is
/// read on demand, at the two ends of a hire.
final odometerPid = ObdPid('A6', 'odometer', 'Odometer', 'km', 4,
    (b) => ((b[0] << 24) + (b[1] << 16) + (b[2] << 8) + b[3]) / 10);

const _errorTokens = [
  'NODATA',
  'STOPPED',
  'ERROR',
  'UNABLETOCONNECT',
  'BUSINIT',
  'BUSERROR',
  'CANERROR',
  'BUFFERFULL',
  '?',
];

const _transientTokens = ['SEARCHING', 'BUS INIT', 'BUSINIT'];

/// The reply as lines of upper-case hex/text, prompt and spacing removed.
List<String> cleanElmResponse(String raw) => raw
    .replaceAll(elmPrompt, '')
    .split(RegExp(r'[\r\n]+'))
    .map((l) => l.replaceAll(RegExp(r'\s+'), '').toUpperCase())
    .where((l) => l.isNotEmpty)
    .toList();

bool isElmError(String raw) => cleanElmResponse(raw).any(_errorTokens.contains);

/// "SEARCHING..." / "BUS INIT": the adapter is still working, not answering.
bool isElmSearching(String raw) {
  final upper = raw.toUpperCase();
  return _transientTokens.any(upper.contains);
}

/// The data bytes of a mode-01 reply for [pid], or null when it did not
/// answer. Tolerates echo, headers and multi-ECU replies by searching each
/// line for `41` + PID.
List<int>? parsePidBytes(String raw, ObdPid pid) {
  if (isElmError(raw)) return null;
  final header = '41${pid.pid.toUpperCase()}';
  for (final line in cleanElmResponse(raw)) {
    if (_errorTokens.contains(line) || _transientTokens.contains(line)) continue;
    final i = line.indexOf(header);
    if (i == -1) continue;
    final data = line.substring(i + header.length);
    if (data.length < pid.bytes * 2) continue;
    final bytes = <int>[];
    for (var b = 0; b < pid.bytes; b++) {
      final octet = data.substring(b * 2, b * 2 + 2);
      if (!RegExp(r'^[0-9A-F]{2}$').hasMatch(octet)) break;
      bytes.add(int.parse(octet, radix: 16));
    }
    if (bytes.length == pid.bytes) return bytes;
  }
  return null;
}

/// The decoded value, or null.
double? decodePid(String raw, ObdPid pid) {
  final bytes = parsePidBytes(raw, pid);
  if (bytes == null) return null;
  final v = pid.decode(bytes);
  return v.isFinite ? v : null;
}

/// Latest reading per [obdPids] key.
typedef Telemetry = Map<String, double>;

String formatTelemetryValue(String key, double value) {
  final pid = obdPids[key];
  if (pid == null) return value.toStringAsFixed(1);
  return '${pid.unit == 'V' ? value.toStringAsFixed(1) : value.round()} ${pid.unit}';
}
