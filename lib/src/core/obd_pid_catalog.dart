// Extended OBD-II mode-01 parameter catalogue, ported from the Expo app's
// `utils/canbus/pidCatalog.ts`.
//
// `obdPids` (obd.dart) is deliberately small: it is the set the 1 Hz telemetry
// poll sweeps on every tick, so adding to it slows the taxi meter and the
// System Status panel down. This catalogue is the *other* half: every mode-01
// parameter the Vehicle Information screen knows how to decode, read once on
// demand rather than continuously.
//
// A vehicle only answers the PIDs it actually implements, and which ones those
// are is discovered at runtime from the support bitmasks (`parseSupportedPids`
// in vehicle_info.dart). Anything a car reports as supported but that is
// missing from this catalogue is still shown by the screen, as raw bytes: the
// catalogue decides what gets a *label and a unit*, not what gets read.

/// Sections the Vehicle Information screen groups readings under.
enum PidGroup {
  engine,
  fuel,
  air,
  emissions,
  electrical,
  vehicle,
  hybrid,

  /// Supported by the car, but not in this catalogue: shown as raw bytes so
  /// the screen still reports everything the reader can actually read.
  other;

  String get label => pidGroupLabel[this]!;
}

const pidGroupLabel = <PidGroup, String>{
  PidGroup.engine: 'Engine',
  PidGroup.fuel: 'Fuel system',
  PidGroup.air: 'Air & intake',
  PidGroup.emissions: 'Emissions',
  PidGroup.electrical: 'Electrical',
  PidGroup.vehicle: 'Vehicle',
  PidGroup.hybrid: 'Hybrid / EV',
  PidGroup.other: 'Other parameters',
};

/// Order the groups render in.
const pidGroupOrder = <PidGroup>[
  PidGroup.engine,
  PidGroup.vehicle,
  PidGroup.fuel,
  PidGroup.air,
  PidGroup.emissions,
  PidGroup.electrical,
  PidGroup.hybrid,
  PidGroup.other,
];

/// One decodable mode-01 parameter.
///
/// Exactly one of [decode] (engineering number) and [decodeText] (enumerated
/// or bit-field value that has no meaningful number) is set.
class CatalogPid {
  const CatalogPid({
    required this.pid,
    required this.label,
    required this.unit,
    required this.bytes,
    required this.group,
    this.precision,
    this.decode,
    this.decodeText,
  });

  /// Two-hex-digit PID within mode 01, e.g. "0C". Always upper case.
  final String pid;
  final String label;

  /// Display unit, or "" for enumerated/text parameters.
  final String unit;

  /// Number of data bytes expected after the `41 <pid>` header.
  final int bytes;
  final PidGroup group;

  /// Decimal places to render for a numeric value.
  final int? precision;
  final double Function(List<int> data)? decode;
  final String Function(List<int> data)? decodeText;
}

/// Signed percentage used by the fuel-trim PIDs: -100 % … +99.2 %.
double _trimPercent(List<int> d) => (d[0] - 128) * (100 / 128);

/// Unsigned percentage used by throttle/load/level PIDs: 0 % … 100 %.
double _bytePercent(List<int> d) => (d[0] * 100) / 255;

/// Temperature PIDs share a -40 °C offset.
double _tempC(List<int> d) => (d[0] - 40).toDouble();

int _word(int a, int b) => a * 256 + b;

const _fuelSystemStatus = <int, String>{
  0: 'Off',
  1: 'Open loop — engine not warm',
  2: 'Closed loop — using O2 sensor feedback',
  4: 'Open loop — load or deceleration',
  8: 'Open loop — system fault',
  16: 'Closed loop — one O2 sensor faulty',
};

const _secondaryAirStatus = <int, String>{
  1: 'Upstream',
  2: 'Downstream of catalyst',
  4: 'From outside atmosphere / off',
  8: 'Pump commanded on for diagnostics',
};

const _obdStandards = <int, String>{
  1: 'OBD-II (California ARB)',
  2: 'OBD (Federal EPA)',
  3: 'OBD and OBD-II',
  4: 'OBD-I',
  5: 'Not OBD compliant',
  6: 'EOBD (Europe)',
  7: 'EOBD and OBD-II',
  8: 'EOBD and OBD',
  9: 'EOBD, OBD and OBD-II',
  10: 'JOBD (Japan)',
  11: 'JOBD and OBD-II',
  12: 'JOBD and EOBD',
  13: 'JOBD, EOBD and OBD-II',
  17: 'Engine Manufacturer Diagnostics (EMD)',
  18: 'EMD Enhanced (EMD+)',
  19: 'Heavy Duty OBD (child/partial) (HD OBD-C)',
  20: 'Heavy Duty OBD (HD OBD)',
  21: 'World Wide Harmonised OBD (WWH OBD)',
  23: 'Heavy Duty EOBD stage I without NOx control',
  24: 'Heavy Duty EOBD stage I with NOx control',
  25: 'Heavy Duty EOBD stage II without NOx control',
  26: 'Heavy Duty EOBD stage II with NOx control',
  28: 'Brazil OBD phase 1 (OBDBr-1)',
  29: 'Brazil OBD phase 2 (OBDBr-2)',
  30: 'Korean OBD (KOBD)',
  31: 'India OBD I (IOBD I)',
  32: 'India OBD II (IOBD II)',
  33: 'Heavy Duty EOBD stage VI',
};

const _fuelTypes = <int, String>{
  0: 'Not available',
  1: 'Petrol',
  2: 'Methanol',
  3: 'Ethanol',
  4: 'Diesel',
  5: 'LPG',
  6: 'CNG',
  7: 'Propane',
  8: 'Electric',
  9: 'Bifuel — petrol',
  10: 'Bifuel — methanol',
  11: 'Bifuel — ethanol',
  12: 'Bifuel — LPG',
  13: 'Bifuel — CNG',
  14: 'Bifuel — propane',
  15: 'Bifuel — electric',
  16: 'Bifuel — electric and combustion',
  17: 'Hybrid petrol',
  18: 'Hybrid ethanol',
  19: 'Hybrid diesel',
  20: 'Hybrid electric',
  21: 'Hybrid — electric and combustion',
  22: 'Hybrid regenerative',
  23: 'Bifuel — diesel',
};

String _enumLabel(Map<int, String> table, int value) =>
    table[value] ?? 'Unknown (0x${value.toRadixString(16).toUpperCase()})';

/// One O2 sensor voltage entry: PIDs 14…1B share a decode.
CatalogPid _o2Sensor(String pid, int index) => CatalogPid(
  pid: pid,
  label: 'O2 sensor $index voltage',
  unit: 'V',
  bytes: 2,
  group: PidGroup.emissions,
  precision: 3,
  decode: (d) => d[0] / 200,
);

/// One catalyst temperature entry: PIDs 3C…3F share a decode.
CatalogPid _catalystTemp(String pid, String label) => CatalogPid(
  pid: pid,
  label: label,
  unit: '°C',
  bytes: 2,
  group: PidGroup.emissions,
  precision: 1,
  decode: (d) => _word(d[0], d[1]) / 10 - 40,
);

/// Every mode-01 PID this app can decode, keyed by PID.
///
/// PID 00/20/40/… (the support bitmasks) and PID 01/41 (monitor status) are
/// handled separately in vehicle_info.dart: they are structure, not readings.
final pidCatalog = <String, CatalogPid>{
  '03': CatalogPid(
    pid: '03',
    label: 'Fuel system status',
    unit: '',
    bytes: 2,
    group: PidGroup.fuel,
    decodeText: (d) => _enumLabel(_fuelSystemStatus, d[0]),
  ),
  '04': const CatalogPid(
    pid: '04',
    label: 'Calculated engine load',
    unit: '%',
    bytes: 1,
    group: PidGroup.engine,
    precision: 1,
    decode: _bytePercent,
  ),
  '05': const CatalogPid(
    pid: '05',
    label: 'Engine coolant temperature',
    unit: '°C',
    bytes: 1,
    group: PidGroup.engine,
    decode: _tempC,
  ),
  '06': const CatalogPid(
    pid: '06',
    label: 'Short term fuel trim — bank 1',
    unit: '%',
    bytes: 1,
    group: PidGroup.fuel,
    precision: 1,
    decode: _trimPercent,
  ),
  '07': const CatalogPid(
    pid: '07',
    label: 'Long term fuel trim — bank 1',
    unit: '%',
    bytes: 1,
    group: PidGroup.fuel,
    precision: 1,
    decode: _trimPercent,
  ),
  '08': const CatalogPid(
    pid: '08',
    label: 'Short term fuel trim — bank 2',
    unit: '%',
    bytes: 1,
    group: PidGroup.fuel,
    precision: 1,
    decode: _trimPercent,
  ),
  '09': const CatalogPid(
    pid: '09',
    label: 'Long term fuel trim — bank 2',
    unit: '%',
    bytes: 1,
    group: PidGroup.fuel,
    precision: 1,
    decode: _trimPercent,
  ),
  '0A': CatalogPid(
    pid: '0A',
    label: 'Fuel pressure',
    unit: 'kPa',
    bytes: 1,
    group: PidGroup.fuel,
    decode: (d) => (d[0] * 3).toDouble(),
  ),
  '0B': CatalogPid(
    pid: '0B',
    label: 'Intake manifold pressure',
    unit: 'kPa',
    bytes: 1,
    group: PidGroup.air,
    decode: (d) => d[0].toDouble(),
  ),
  '0C': CatalogPid(
    pid: '0C',
    label: 'Engine speed',
    unit: 'rpm',
    bytes: 2,
    group: PidGroup.engine,
    decode: (d) => _word(d[0], d[1]) / 4,
  ),
  '0D': CatalogPid(
    pid: '0D',
    label: 'Vehicle speed',
    unit: 'km/h',
    bytes: 1,
    group: PidGroup.vehicle,
    decode: (d) => d[0].toDouble(),
  ),
  '0E': CatalogPid(
    pid: '0E',
    label: 'Timing advance',
    unit: '° before TDC',
    bytes: 1,
    group: PidGroup.engine,
    precision: 1,
    decode: (d) => d[0] / 2 - 64,
  ),
  '0F': const CatalogPid(
    pid: '0F',
    label: 'Intake air temperature',
    unit: '°C',
    bytes: 1,
    group: PidGroup.air,
    decode: _tempC,
  ),
  '10': CatalogPid(
    pid: '10',
    label: 'Mass air flow rate',
    unit: 'g/s',
    bytes: 2,
    group: PidGroup.air,
    precision: 2,
    decode: (d) => _word(d[0], d[1]) / 100,
  ),
  '11': const CatalogPid(
    pid: '11',
    label: 'Throttle position',
    unit: '%',
    bytes: 1,
    group: PidGroup.engine,
    precision: 1,
    decode: _bytePercent,
  ),
  '12': CatalogPid(
    pid: '12',
    label: 'Commanded secondary air status',
    unit: '',
    bytes: 1,
    group: PidGroup.emissions,
    decodeText: (d) => _enumLabel(_secondaryAirStatus, d[0]),
  ),
  '14': _o2Sensor('14', 1),
  '15': _o2Sensor('15', 2),
  '16': _o2Sensor('16', 3),
  '17': _o2Sensor('17', 4),
  '18': _o2Sensor('18', 5),
  '19': _o2Sensor('19', 6),
  '1A': _o2Sensor('1A', 7),
  '1B': _o2Sensor('1B', 8),
  '1C': CatalogPid(
    pid: '1C',
    label: 'OBD standard',
    unit: '',
    bytes: 1,
    group: PidGroup.vehicle,
    decodeText: (d) => _enumLabel(_obdStandards, d[0]),
  ),
  '1E': CatalogPid(
    pid: '1E',
    label: 'Auxiliary input status',
    unit: '',
    bytes: 1,
    group: PidGroup.vehicle,
    decodeText: (d) => (d[0] & 0x01) == 1 ? 'Power take-off active' : 'Inactive',
  ),
  '1F': CatalogPid(
    pid: '1F',
    label: 'Run time since engine start',
    unit: 's',
    bytes: 2,
    group: PidGroup.engine,
    decode: (d) => _word(d[0], d[1]).toDouble(),
  ),
  '21': CatalogPid(
    pid: '21',
    label: 'Distance travelled with MIL on',
    unit: 'km',
    bytes: 2,
    group: PidGroup.emissions,
    decode: (d) => _word(d[0], d[1]).toDouble(),
  ),
  '22': CatalogPid(
    pid: '22',
    label: 'Fuel rail pressure (vs. manifold vacuum)',
    unit: 'kPa',
    bytes: 2,
    group: PidGroup.fuel,
    precision: 1,
    decode: (d) => _word(d[0], d[1]) * 0.079,
  ),
  '23': CatalogPid(
    pid: '23',
    label: 'Fuel rail gauge pressure',
    unit: 'kPa',
    bytes: 2,
    group: PidGroup.fuel,
    decode: (d) => (_word(d[0], d[1]) * 10).toDouble(),
  ),
  '2C': const CatalogPid(
    pid: '2C',
    label: 'Commanded EGR',
    unit: '%',
    bytes: 1,
    group: PidGroup.emissions,
    precision: 1,
    decode: _bytePercent,
  ),
  '2D': const CatalogPid(
    pid: '2D',
    label: 'EGR error',
    unit: '%',
    bytes: 1,
    group: PidGroup.emissions,
    precision: 1,
    decode: _trimPercent,
  ),
  '2E': const CatalogPid(
    pid: '2E',
    label: 'Commanded evaporative purge',
    unit: '%',
    bytes: 1,
    group: PidGroup.emissions,
    precision: 1,
    decode: _bytePercent,
  ),
  '2F': const CatalogPid(
    pid: '2F',
    label: 'Fuel tank level',
    unit: '%',
    bytes: 1,
    group: PidGroup.fuel,
    precision: 1,
    decode: _bytePercent,
  ),
  '30': CatalogPid(
    pid: '30',
    label: 'Warm-ups since codes cleared',
    unit: '',
    bytes: 1,
    group: PidGroup.emissions,
    decode: (d) => d[0].toDouble(),
  ),
  '31': CatalogPid(
    pid: '31',
    label: 'Distance since codes cleared',
    unit: 'km',
    bytes: 2,
    group: PidGroup.emissions,
    decode: (d) => _word(d[0], d[1]).toDouble(),
  ),
  '32': CatalogPid(
    pid: '32',
    label: 'Evap system vapour pressure',
    unit: 'Pa',
    bytes: 2,
    group: PidGroup.emissions,
    precision: 2,
    // Signed 16-bit, quarter-Pa resolution.
    decode: (d) {
      final raw = _word(d[0], d[1]);
      return (raw > 0x7fff ? raw - 0x10000 : raw) / 4;
    },
  ),
  '33': CatalogPid(
    pid: '33',
    label: 'Absolute barometric pressure',
    unit: 'kPa',
    bytes: 1,
    group: PidGroup.air,
    decode: (d) => d[0].toDouble(),
  ),
  '3C': _catalystTemp('3C', 'Catalyst temperature — bank 1, sensor 1'),
  '3D': _catalystTemp('3D', 'Catalyst temperature — bank 2, sensor 1'),
  '3E': _catalystTemp('3E', 'Catalyst temperature — bank 1, sensor 2'),
  '3F': _catalystTemp('3F', 'Catalyst temperature — bank 2, sensor 2'),
  '42': CatalogPid(
    pid: '42',
    label: 'Control module voltage',
    unit: 'V',
    bytes: 2,
    group: PidGroup.electrical,
    precision: 3,
    decode: (d) => _word(d[0], d[1]) / 1000,
  ),
  '43': CatalogPid(
    pid: '43',
    label: 'Absolute load value',
    unit: '%',
    bytes: 2,
    group: PidGroup.engine,
    precision: 1,
    decode: (d) => (_word(d[0], d[1]) * 100) / 255,
  ),
  '44': CatalogPid(
    pid: '44',
    label: 'Commanded air-fuel equivalence ratio (λ)',
    unit: '',
    bytes: 2,
    group: PidGroup.fuel,
    precision: 3,
    decode: (d) => (2 / 65536) * _word(d[0], d[1]),
  ),
  '45': const CatalogPid(
    pid: '45',
    label: 'Relative throttle position',
    unit: '%',
    bytes: 1,
    group: PidGroup.engine,
    precision: 1,
    decode: _bytePercent,
  ),
  '46': const CatalogPid(
    pid: '46',
    label: 'Ambient air temperature',
    unit: '°C',
    bytes: 1,
    group: PidGroup.air,
    decode: _tempC,
  ),
  '47': const CatalogPid(
    pid: '47',
    label: 'Absolute throttle position B',
    unit: '%',
    bytes: 1,
    group: PidGroup.engine,
    precision: 1,
    decode: _bytePercent,
  ),
  '48': const CatalogPid(
    pid: '48',
    label: 'Absolute throttle position C',
    unit: '%',
    bytes: 1,
    group: PidGroup.engine,
    precision: 1,
    decode: _bytePercent,
  ),
  '49': const CatalogPid(
    pid: '49',
    label: 'Accelerator pedal position D',
    unit: '%',
    bytes: 1,
    group: PidGroup.engine,
    precision: 1,
    decode: _bytePercent,
  ),
  '4A': const CatalogPid(
    pid: '4A',
    label: 'Accelerator pedal position E',
    unit: '%',
    bytes: 1,
    group: PidGroup.engine,
    precision: 1,
    decode: _bytePercent,
  ),
  '4B': const CatalogPid(
    pid: '4B',
    label: 'Accelerator pedal position F',
    unit: '%',
    bytes: 1,
    group: PidGroup.engine,
    precision: 1,
    decode: _bytePercent,
  ),
  '4C': const CatalogPid(
    pid: '4C',
    label: 'Commanded throttle actuator',
    unit: '%',
    bytes: 1,
    group: PidGroup.engine,
    precision: 1,
    decode: _bytePercent,
  ),
  '4D': CatalogPid(
    pid: '4D',
    label: 'Time run with MIL on',
    unit: 'min',
    bytes: 2,
    group: PidGroup.emissions,
    decode: (d) => _word(d[0], d[1]).toDouble(),
  ),
  '4E': CatalogPid(
    pid: '4E',
    label: 'Time since codes cleared',
    unit: 'min',
    bytes: 2,
    group: PidGroup.emissions,
    decode: (d) => _word(d[0], d[1]).toDouble(),
  ),
  '51': CatalogPid(
    pid: '51',
    label: 'Fuel type',
    unit: '',
    bytes: 1,
    group: PidGroup.fuel,
    decodeText: (d) => _enumLabel(_fuelTypes, d[0]),
  ),
  '52': const CatalogPid(
    pid: '52',
    label: 'Ethanol fuel content',
    unit: '%',
    bytes: 1,
    group: PidGroup.fuel,
    precision: 1,
    decode: _bytePercent,
  ),
  '53': CatalogPid(
    pid: '53',
    label: 'Absolute evap system vapour pressure',
    unit: 'kPa',
    bytes: 2,
    group: PidGroup.emissions,
    precision: 3,
    decode: (d) => _word(d[0], d[1]) / 200,
  ),
  '59': CatalogPid(
    pid: '59',
    label: 'Fuel rail absolute pressure',
    unit: 'kPa',
    bytes: 2,
    group: PidGroup.fuel,
    decode: (d) => (_word(d[0], d[1]) * 10).toDouble(),
  ),
  '5A': const CatalogPid(
    pid: '5A',
    label: 'Relative accelerator pedal position',
    unit: '%',
    bytes: 1,
    group: PidGroup.engine,
    precision: 1,
    decode: _bytePercent,
  ),
  '5B': const CatalogPid(
    pid: '5B',
    label: 'Hybrid battery pack remaining life',
    unit: '%',
    bytes: 1,
    group: PidGroup.hybrid,
    precision: 1,
    decode: _bytePercent,
  ),
  '5C': const CatalogPid(
    pid: '5C',
    label: 'Engine oil temperature',
    unit: '°C',
    bytes: 1,
    group: PidGroup.engine,
    decode: _tempC,
  ),
  '5D': CatalogPid(
    pid: '5D',
    label: 'Fuel injection timing',
    unit: '°',
    bytes: 2,
    group: PidGroup.fuel,
    precision: 2,
    decode: (d) => _word(d[0], d[1]) / 128 - 210,
  ),
  '5E': CatalogPid(
    pid: '5E',
    label: 'Engine fuel rate',
    unit: 'L/h',
    bytes: 2,
    group: PidGroup.fuel,
    precision: 2,
    decode: (d) => _word(d[0], d[1]) / 20,
  ),
  '61': CatalogPid(
    pid: '61',
    label: "Driver's demand engine torque",
    unit: '%',
    bytes: 1,
    group: PidGroup.engine,
    decode: (d) => (d[0] - 125).toDouble(),
  ),
  '62': CatalogPid(
    pid: '62',
    label: 'Actual engine torque',
    unit: '%',
    bytes: 1,
    group: PidGroup.engine,
    decode: (d) => (d[0] - 125).toDouble(),
  ),
  '63': CatalogPid(
    pid: '63',
    label: 'Engine reference torque',
    unit: 'N·m',
    bytes: 2,
    group: PidGroup.engine,
    decode: (d) => _word(d[0], d[1]).toDouble(),
  ),
  '9D': CatalogPid(
    pid: '9D',
    label: 'Engine fuel rate (mass)',
    unit: 'g/s',
    bytes: 4,
    group: PidGroup.fuel,
    precision: 2,
    decode: (d) => _word(d[0], d[1]) / 32,
  ),
  '9E': CatalogPid(
    pid: '9E',
    label: 'Engine exhaust flow rate',
    unit: 'kg/h',
    bytes: 2,
    group: PidGroup.air,
    precision: 1,
    decode: (d) => _word(d[0], d[1]) / 5,
  ),
  'A6': CatalogPid(
    pid: 'A6',
    label: 'Odometer',
    unit: 'km',
    bytes: 4,
    group: PidGroup.vehicle,
    precision: 1,
    decode: (d) => (d[0] * 16777216 + d[1] * 65536 + d[2] * 256 + d[3]) / 10,
  ),
};

/// Look a PID up in the catalogue, case-insensitively.
CatalogPid? catalogPid(String pid) => pidCatalog[pid.trim().toUpperCase()];

/// Render a decoded catalogue reading for display, e.g. `13.842 V`, `Petrol`.
/// Enumerated parameters carry no unit, so they render as the bare label.
String? formatCatalogValue(CatalogPid pid, List<int> data) {
  final decodeText = pid.decodeText;
  if (decodeText != null) {
    final text = decodeText(data);
    return text.isEmpty ? null : text;
  }
  final decode = pid.decode;
  if (decode == null) return null;
  final value = decode(data);
  if (!value.isFinite) return null;
  // JS `toFixed` prints -0 as "0"; Dart keeps the sign, so normalise it.
  final rendered = (value == 0 ? 0.0 : value).toStringAsFixed(pid.precision ?? 0);
  return pid.unit.isNotEmpty ? '$rendered ${pid.unit}' : rendered;
}

/// Raw fallback rendering for a PID the catalogue does not know, e.g. "1A F8".
String formatRawBytes(List<int> data) => data.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');
