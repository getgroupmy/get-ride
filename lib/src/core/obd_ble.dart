// Bluetooth LE for ELM327 OBD-II readers, the pure half: ported from the
// Expo app's `utils/canbus/ble.ts` and the profile list in `config.ts`.
//
// An ELM327 over BLE is a serial link: one characteristic to write commands
// to and one (sometimes the same one) that notifies the replies. The clones
// disagree on the UUIDs, so the known profiles are tried in order and a clone
// using UUIDs nobody has catalogued still connects through a generic
// fallback. Nothing here touches the radio, so it is tested directly.

/// One BLE serial profile: the service and its write / notify
/// characteristics.
typedef BleSerialProfile = ({String label, String service, String write, String notify});

/// The known ELM327-over-BLE profiles, most common first.
const bleElmProfiles = <BleSerialProfile>[
  (
    label: 'ELM327 (FFF0)',
    service: '0000fff0-0000-1000-8000-00805f9b34fb',
    write: '0000fff2-0000-1000-8000-00805f9b34fb',
    notify: '0000fff1-0000-1000-8000-00805f9b34fb',
  ),
  (
    label: 'HM-10 serial (FFE0)',
    service: '0000ffe0-0000-1000-8000-00805f9b34fb',
    write: '0000ffe1-0000-1000-8000-00805f9b34fb',
    notify: '0000ffe1-0000-1000-8000-00805f9b34fb',
  ),
  (
    label: 'Nordic UART',
    service: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
    write: '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
    notify: '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
  ),
];

/// Name fragments the dongles advertise under.
const bleElmNameHints = ['OBD', 'ELM', 'VLINK', 'VGATE', 'ICAR'];

const _baseSuffix = '-0000-1000-8000-00805f9b34fb';

/// Generic Access / Generic Attribute / Device Information never carry the
/// serial stream, so the fallback never latches onto them.
final _ignoredServices = ['1800', '1801', '180a'].map(normalizeBleUuid).toSet();

/// Lowercases a UUID and expands the 16- and 32-bit short forms the
/// platforms hand back inconsistently ("FFF0", "0000fff0", the full form),
/// so two spellings of the same UUID compare equal.
String normalizeBleUuid(String? uuid) {
  final raw = (uuid ?? '').trim().toLowerCase();
  if (raw.length == 4) return '0000$raw$_baseSuffix';
  if (raw.length == 8) return '$raw$_baseSuffix';
  return raw;
}

bool sameBleUuid(String? a, String? b) {
  final left = normalizeBleUuid(a);
  return left.isNotEmpty && left == normalizeBleUuid(b);
}

/// Whether an advertised name looks like an ELM327 dongle.
bool isLikelyElmName(String? name) {
  final upper = (name ?? '').trim().toUpperCase();
  return upper.isNotEmpty && bleElmNameHints.any(upper.contains);
}

/// The scan filter: a known dongle name, or one of the serial services the
/// dongles advertise. A car park is full of nameless peripherals advertising
/// nothing useful, and those are not offered.
bool matchesElmAdvertisement({String? name, List<String> services = const []}) {
  if (isLikelyElmName(name)) return true;
  final advertised = services.map(normalizeBleUuid).toSet();
  return bleElmProfiles.any((p) => advertised.contains(normalizeBleUuid(p.service)));
}

/// What the profile picker needs to know about a characteristic.
class BleCharacteristicInfo {
  const BleCharacteristicInfo(
    this.uuid, {
    this.write = false,
    this.writeWithoutResponse = false,
    this.notify = false,
    this.indicate = false,
  });

  final String uuid;
  final bool write;
  final bool writeWithoutResponse;
  final bool notify;
  final bool indicate;

  bool get writable => write || writeWithoutResponse;
  bool get subscribable => notify || indicate;
}

typedef BleServiceInfo = ({String uuid, List<BleCharacteristicInfo> characteristics});

/// The serial link found on a reader.
typedef ResolvedBleProfile = ({
  String label,
  String service,
  String write,
  String notify,

  /// False when the write characteristic only takes write-without-response.
  bool writeWithResponse,

  /// True when the replies arrive as indications rather than notifications.
  bool indicate,
});

/// Picks the write / notify pair to talk ELM327 over: the known profiles in
/// order, then the first non-standard service with a writable and a
/// subscribable characteristic (the same one on HM-10 style modules).
ResolvedBleProfile? resolveBleProfile(List<BleServiceInfo> services) {
  ResolvedBleProfile make(String label, BleServiceInfo s, BleCharacteristicInfo w, BleCharacteristicInfo n) => (
        label: label,
        service: s.uuid,
        write: w.uuid,
        notify: n.uuid,
        writeWithResponse: w.write,
        indicate: !n.notify,
      );

  for (final p in bleElmProfiles) {
    final s = services.where((s) => sameBleUuid(s.uuid, p.service)).firstOrNull;
    if (s == null) continue;
    final w = s.characteristics.where((c) => sameBleUuid(c.uuid, p.write) && c.writable).firstOrNull;
    final n = s.characteristics.where((c) => sameBleUuid(c.uuid, p.notify) && c.subscribable).firstOrNull;
    if (w != null && n != null) return make(p.label, s, w, n);
  }
  for (final s in services) {
    if (_ignoredServices.contains(normalizeBleUuid(s.uuid))) continue;
    final w = s.characteristics.where((c) => c.writable).firstOrNull;
    final n = s.characteristics.where((c) => c.subscribable).firstOrNull;
    if (w != null && n != null) return make('Generic serial', s, w, n);
  }
  return null;
}

/// Splits a command into packets no longer than one BLE write carries (20
/// bytes before an MTU exchange). ELM327 commands are short, but a reader
/// that sees a truncated command answers "?" rather than the right thing.
List<List<int>> chunkBleWrite(List<int> bytes, {int size = 20}) => [
      for (var i = 0; i < bytes.length; i += size) bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size),
    ];
