// Bluetooth MFi (Apple External Accessory) OBD-II readers, the pure half:
// ported from the Expo app's `utils/canbus/mfi.ts`.
//
// MFi is not BLE. An MFi dongle (OBDLink MX+ &co.) is a classic-Bluetooth
// serial device carrying Apple's authentication chip; iOS exposes it only
// through the ExternalAccessory framework, only once the driver has paired
// it in the Settings app, and only for the protocol strings the app declares
// in Info.plist (`UISupportedExternalAccessoryProtocols`).
import 'obd_ble.dart' show bleElmNameHints;

/// The accessory protocols the app speaks (Expo `MFI_ACCESSORY_PROTOCOLS`);
/// must match `UISupportedExternalAccessoryProtocols` in ios/Runner/Info.plist.
const mfiAccessoryProtocols = ['com.obdlink'];

/// Name fragments that mark a paired accessory as an OBD-II reader: the BLE
/// hints, plus the MFi-only vendor names (Expo `MFI_NAME_HINTS`).
const mfiNameHints = [...bleElmNameHints, 'SCANTOOL', 'STN'];

/// A paired accessory as the native side reports it. [connectionId] changes
/// every time the accessory reconnects, so a saved reader is remembered by
/// [key] instead.
typedef MfiAccessory = ({String connectionId, String name, String serial, String protocol});

MfiAccessory? mfiAccessoryFromMap(Object? m) {
  if (m is! Map) return null;
  final id = '${m['id'] ?? ''}'.trim();
  if (id.isEmpty) return null;
  return (
    connectionId: id,
    name: '${m['name'] ?? ''}'.trim(),
    serial: '${m['serial'] ?? ''}'.trim(),
    protocol: '${m['protocol'] ?? ''}'.trim(),
  );
}

/// Case- and punctuation-blind, as drivers type names the way iOS Settings
/// shows them (Expo `normalizeAccessoryKey`).
String normalizeAccessoryKey(String? value) => (value ?? '').trim().toLowerCase().replaceAll(RegExp(r'[\s:_-]'), '');

/// What a saved reader is remembered by: the serial number when the
/// accessory reports one, else its name.
String mfiAccessoryKey(MfiAccessory a) => a.serial.isNotEmpty ? a.serial : a.name;

/// Whether a paired accessory's name looks like an OBD-II reader.
bool isLikelyMfiReader(MfiAccessory a) {
  final upper = a.name.toUpperCase();
  return upper.isNotEmpty && mfiNameHints.any(upper.contains);
}

/// The accessory to link with (Expo `pickMfiAccessory`). A saved reader
/// accepts only its own accessory — linking to another paired dongle would
/// stream another car's telemetry; with none saved, the first that looks
/// like a reader.
MfiAccessory? pickMfiAccessory(List<MfiAccessory> accessories, {String? preferred}) {
  final want = normalizeAccessoryKey(preferred);
  if (want.isNotEmpty) {
    for (final a in accessories) {
      if (normalizeAccessoryKey(a.serial) == want || normalizeAccessoryKey(a.name) == want) return a;
    }
    return null;
  }
  for (final a in accessories) {
    if (isLikelyMfiReader(a)) return a;
  }
  return null;
}
