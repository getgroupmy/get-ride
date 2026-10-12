// The driver's saved receipt printers, ported from the Expo app's
// `utils/printerStore.ts` (the pure half). Kept on the device: a printer is
// paired to the phone in the car, not to the account.
//
// Printers are reached over Wi-Fi (a raw TCP socket to the ESC/POS port),
// Bluetooth LE (a writable characteristic) or, on Android, classic Bluetooth
// (an RFCOMM serial port to a printer paired in the phone's settings).

import 'escpos.dart';
import 'obd_ble.dart' show BleServiceInfo, normalizeBleUuid, sameBleUuid;
import 'obd_adapters.dart';

/// The raw ESC/POS port virtually every network printer listens on.
const printerWifiPort = 9100;

const printerTransportLabels = {'wifi': 'Wi-Fi', 'bluetooth': 'Bluetooth LE', 'bluetooth-classic': 'Bluetooth (classic)'};

class SavedPrinter {
  const SavedPrinter({
    required this.id,
    required this.name,
    required this.transport,
    this.host,
    this.port,
    this.address,
    this.paper = PaperWidth.mm58,
    required this.createdAt,
    this.lastPrintedAt,
  });

  final String id;
  final String name;
  final String transport;
  final String? host;
  final int? port;

  /// Bluetooth printers: the paired name or address.
  final String? address;
  final PaperWidth paper;
  final String createdAt;
  final int? lastPrintedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'transport': transport,
        if (host != null) 'host': host,
        if (port != null) 'port': port,
        if (address != null) 'address': address,
        'paperWidth': paper.label,
        'createdAt': createdAt,
        'lastConnectedAt': lastPrintedAt,
      };

  static SavedPrinter? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], name = raw['name'], transport = raw['transport'];
    if (id is! String || transport is! String) return null;
    return SavedPrinter(
      id: id,
      name: name is String ? name : 'Printer',
      transport: transport,
      host: raw['host'] is String ? raw['host'] as String : null,
      port: raw['port'] is num ? (raw['port'] as num).toInt() : null,
      address: raw['address'] is String ? raw['address'] as String : null,
      paper: PaperWidth.parse(raw['paperWidth']),
      createdAt: raw['createdAt'] is String ? raw['createdAt'] as String : '',
      lastPrintedAt: raw['lastConnectedAt'] is num ? (raw['lastConnectedAt'] as num).toInt() : null,
    );
  }

  SavedPrinter copyWith({String? id, String? createdAt, int? lastPrintedAt}) => SavedPrinter(
        id: id ?? this.id,
        name: name,
        transport: transport,
        host: host,
        port: port,
        address: address,
        paper: paper,
        createdAt: createdAt ?? this.createdAt,
        lastPrintedAt: lastPrintedAt ?? this.lastPrintedAt,
      );
}

final _hostname = RegExp(r'^[A-Za-z0-9._-]+$');

/// Validates the add-printer form (Expo `normalizePrinterDraft`, Wi-Fi). A
/// network printer has no well-known address, so the IP is required; the
/// port defaults to 9100.
({String? error, SavedPrinter? value}) normalizeWifiPrinter({
  required String id,
  required String createdAt,
  String name = '',
  String host = '',
  String port = '',
  PaperWidth paper = PaperWidth.mm58,
}) {
  final n = name.trim();
  if (n.length > 60) return (error: 'Name must be 60 characters or fewer.', value: null);
  final h = host.trim();
  if (h.isEmpty) return (error: "Enter the printer's IP address.", value: null);
  if (!_hostname.hasMatch(h)) return (error: 'Enter a valid IP address or hostname.', value: null);
  final p = port.trim().isEmpty ? printerWifiPort : int.tryParse(port.trim());
  if (p == null || p < 1 || p > 65535) {
    return (error: 'Port must be a whole number between 1 and 65535.', value: null);
  }
  return (
    error: null,
    value: SavedPrinter(
      id: id,
      name: n.isEmpty ? 'Wi-Fi printer' : n,
      transport: 'wifi',
      host: h,
      port: p,
      paper: paper,
      createdAt: createdAt,
    ),
  );
}

/// A Bluetooth LE printer picked from the in-app scan; [address] keeps the
/// peripheral id (a MAC address on Android, a per-phone UUID on iOS and
/// macOS). The name defaults to the one the printer advertises.
({String? error, SavedPrinter? value}) normalizeBlePrinter({
  required String id,
  required String createdAt,
  required String deviceId,
  String? advertisedName,
  String name = '',
  PaperWidth paper = PaperWidth.mm58,
}) {
  final n = name.trim();
  if (n.length > 60) return (error: 'Name must be 60 characters or fewer.', value: null);
  final device = deviceId.trim();
  if (device.isEmpty) return (error: 'Pick the printer from the scan.', value: null);
  final advertised = (advertisedName ?? '').trim();
  return (
    error: null,
    value: SavedPrinter(
      id: id,
      name: n.isNotEmpty ? n : (advertised.isNotEmpty ? advertised : 'Bluetooth printer'),
      transport: 'bluetooth',
      address: device,
      paper: paper,
      createdAt: createdAt,
    ),
  );
}

/// Whether [deviceId] is a saved OBD-II reader. The printer scan can list
/// every Bluetooth device nearby, the reader included; a "printer" that is
/// really the reader would be sent receipts, and closing it after each job
/// would drop the reader's link mid-hire.
bool isObdReaderDevice(String? deviceId, Iterable<SavedObdAdapter> readers) {
  final id = (deviceId ?? '').trim().toLowerCase();
  return id.isNotEmpty && readers.any((r) => (r.deviceId ?? '').trim().toLowerCase() == id);
}

/// Whether [printer] is one of the saved OBD-II readers.
bool printerIsObdReader(SavedPrinter printer, Iterable<SavedObdAdapter> readers) =>
    (printer.transport == 'bluetooth' || printer.transport == classicPrinterTransport) &&
    isObdReaderDevice(printer.address, readers);

const printerIsReaderMessage = 'That device is your OBD-II reader, not a printer. Pick the printer instead.';

/// The print services mini thermal printers expose, most common first: a
/// (service, write characteristic) pair each.
const blePrinterProfiles = <({String service, String write})>[
  (service: '000018f0-0000-1000-8000-00805f9b34fb', write: '00002af1-0000-1000-8000-00805f9b34fb'),
  (service: 'e7810a71-73ae-499d-8c15-faa9aef0c3f2', write: 'bef8d6c9-9c21-4c9e-b632-bd58c1009f9f'),
  (service: '49535343-fe7d-4ae5-8fa9-9fafd205e455', write: '49535343-8841-43f4-a8d4-ecbe34729bb3'),
  (service: '0000ff00-0000-1000-8000-00805f9b34fb', write: '0000ff02-0000-1000-8000-00805f9b34fb'),
  (service: '0000ffe0-0000-1000-8000-00805f9b34fb', write: '0000ffe1-0000-1000-8000-00805f9b34fb'),
];

/// Generic Access / Generic Attribute / Device Information: a writable
/// characteristic there (the device name, on some modules) is not a printer.
final _notPrintServices = ['1800', '1801', '180a'].map(normalizeBleUuid).toSet();

/// Where to send ESC/POS on a Bluetooth printer (Expo
/// `resolveWriteCharacteristic`): a known print service first, else the first
/// writable characteristic outside the standard services. Write-without-
/// response is preferred, since a receipt is a bulk stream.
({String service, String write, bool withResponse})? resolveBlePrinterWrite(List<BleServiceInfo> services) {
  for (final p in blePrinterProfiles) {
    final s = services.where((s) => sameBleUuid(s.uuid, p.service)).firstOrNull;
    final c = s?.characteristics.where((c) => sameBleUuid(c.uuid, p.write) && c.writable).firstOrNull;
    if (s != null && c != null) return (service: s.uuid, write: c.uuid, withResponse: !c.writeWithoutResponse);
  }
  for (final s in services) {
    if (_notPrintServices.contains(normalizeBleUuid(s.uuid))) continue;
    final fast = s.characteristics.where((c) => c.writeWithoutResponse).firstOrNull;
    final any = fast ?? s.characteristics.where((c) => c.writable).firstOrNull;
    if (any != null) return (service: s.uuid, write: any.uuid, withResponse: fast == null);
  }
  return null;
}

/// How much of a receipt one Bluetooth write carries: what the negotiated
/// MTU allows (less its 3-byte header), capped where cheap printers start
/// dropping data, and never below the 20 bytes every link carries.
int blePrinterPacketSize(int? mtu) {
  if (mtu == null || mtu <= 23) return 20;
  final usable = mtu - 3;
  return usable > 180 ? 180 : usable;
}

/// The pause between packets written without response, so a cheap
/// printer's buffer keeps up.
const blePrinterPacketGap = Duration(milliseconds: 15);

/// The transport value saved for a classic Bluetooth (SPP) printer.
const classicPrinterTransport = 'bluetooth-classic';

/// The Serial Port Profile service every classic Bluetooth thermal printer
/// answers on (RFCOMM).
const classicSppUuid = '00001101-0000-1000-8000-00805F9B34FB';

/// How much of a receipt one classic Bluetooth write carries. RFCOMM has no
/// packet limit of its own, but a cheap printer's buffer is small, so a long
/// receipt goes in pieces with a short pause between them.
const classicPrinterChunkSize = 512;

/// The pause between classic Bluetooth chunks.
const classicPrinterChunkGap = Duration(milliseconds: 20);

/// A device paired with the phone, as Android lists it.
typedef BondedBluetoothDevice = ({String address, String? name, int? majorClass});

/// Android's `BluetoothClass.Device.Major.IMAGING`: printers, scanners and
/// cameras. Most thermal printers report it; some report "uncategorised".
const bluetoothMajorImaging = 0x0600;

/// Android's `BluetoothClass.Device.Major.AUDIO_VIDEO` and `PHONE`: the
/// headsets, car kits and phones a paired list is mostly made of.
const _unlikelyPrinterClasses = {0x0400, 0x0200};

/// The paired devices to offer as printers, likeliest first: anything
/// reporting the imaging class, then the rest, then headsets, car kits and
/// phones; by name within each. A saved OBD-II reader is left out.
List<BondedBluetoothDevice> rankBondedPrinters(
  Iterable<BondedBluetoothDevice> devices, {
  Iterable<SavedObdAdapter> readers = const [],
}) {
  int rank(BondedBluetoothDevice d) => d.majorClass == bluetoothMajorImaging
      ? 0
      : _unlikelyPrinterClasses.contains(d.majorClass)
          ? 2
          : 1;
  final seen = <String>{};
  final list = [
    for (final d in devices)
      if (d.address.trim().isNotEmpty && !isObdReaderDevice(d.address, readers) && seen.add(d.address.toUpperCase()))
        d,
  ];
  list.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    if (r != 0) return r;
    return (a.name ?? '').toLowerCase().compareTo((b.name ?? '').toLowerCase());
  });
  return list;
}

final _btAddress = RegExp(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$');

/// A classic Bluetooth printer picked from the phone's paired devices;
/// [address] is its MAC address. The name defaults to the paired name.
({String? error, SavedPrinter? value}) normalizeClassicPrinter({
  required String id,
  required String createdAt,
  required String address,
  String? pairedName,
  String name = '',
  PaperWidth paper = PaperWidth.mm58,
}) {
  final n = name.trim();
  if (n.length > 60) return (error: 'Name must be 60 characters or fewer.', value: null);
  final a = address.trim().toUpperCase();
  if (!_btAddress.hasMatch(a)) return (error: 'Pick the printer from the paired devices.', value: null);
  final paired = (pairedName ?? '').trim();
  return (
    error: null,
    value: SavedPrinter(
      id: id,
      name: n.isNotEmpty ? n : (paired.isNotEmpty ? paired : 'Bluetooth printer'),
      transport: classicPrinterTransport,
      address: a,
      paper: paper,
      createdAt: createdAt,
    ),
  );
}

/// Whether a printer transport can be used on this device, and if not, why
/// (Expo `printerTransportAvailability`).
typedef PrinterTransportAvailability = ({bool available, String? reason});

/// The platforms [printerTransportAvailability] tells apart.
enum PrinterPlatform { android, ios, web, desktop }

PrinterTransportAvailability printerTransportAvailability(String transport, PrinterPlatform platform) {
  const ok = (available: true, reason: null);
  if (platform == PrinterPlatform.web) {
    return (available: false, reason: 'A browser cannot print to a receipt printer. Use the phone app.');
  }
  switch (transport) {
    case 'wifi':
      return ok;
    case 'bluetooth':
      return ok;
    case classicPrinterTransport:
      return switch (platform) {
        PrinterPlatform.android => ok,
        PrinterPlatform.ios => (
            available: false,
            reason: 'An iPhone only talks to classic Bluetooth printers that are Apple MFi certified. '
                'Use a Bluetooth LE or Wi-Fi printer.',
          ),
        _ => (
            available: false,
            reason: 'Classic Bluetooth printers work from the Android phone app. Use a Bluetooth LE or Wi-Fi '
                'printer here.',
          ),
      };
    default:
      final label = printerTransportLabels[transport] ?? transport;
      return (available: false, reason: '$label printers are not supported.');
  }
}

/// What a classic Bluetooth failure (a platform error [code]) tells the
/// driver.
String describeClassicPrinterError(String? code, String printerName, {String? message}) => switch (code) {
      'not_bonded' => 'Pair the printer in Android Bluetooth settings first, then pick it again here.',
      'bluetooth_off' => 'Bluetooth is off. Turn it on to print.',
      'permission' => 'GET.ride is not allowed to use Bluetooth. Allow "Nearby devices" in the phone\'s settings '
          'for this app.',
      'no_bluetooth' => 'This phone has no Bluetooth.',
      'connect_failed' || 'timeout' => '$printerName is off or out of range. Switch it on, keep it close to this '
          'phone and make sure no other phone is connected to it.',
      'write_failed' => 'The connection to $printerName dropped while printing. Check the printer and try again.',
      _ => 'Could not print to $printerName${message == null || message.isEmpty ? '' : ': $message'}.',
    };

/// "Wi-Fi · 192.168.0.50:9100 · 58mm".
String describePrinter(SavedPrinter p) {
  final label = printerTransportLabels[p.transport] ?? p.transport;
  final paper = ' · ${p.paper.label}';
  if (p.transport == 'wifi' && p.host != null) return '$label · ${p.host}:${p.port ?? printerWifiPort}$paper';
  if (p.address != null) return '$label · ${p.address}$paper';
  return '$label$paper';
}

bool _sameDevice(SavedPrinter a, SavedPrinter b) {
  if (a.id == b.id) return true;
  if (a.transport != b.transport) return false;
  if (b.transport == 'wifi') return a.host == b.host && a.port == b.port;
  return (a.address ?? '').toLowerCase() == (b.address ?? '').toLowerCase();
}

/// Adds [printer], or replaces the saved entry for the same device, keeping
/// its id.
List<SavedPrinter> upsertPrinter(List<SavedPrinter> list, SavedPrinter printer) {
  final existing = list.where((p) => _sameDevice(p, printer)).firstOrNull;
  if (existing == null) return [...list, printer];
  return [
    for (final p in list) p.id == existing.id ? printer.copyWith(id: existing.id, createdAt: existing.createdAt) : p,
  ];
}

List<SavedPrinter> removePrinter(List<SavedPrinter> list, String id) => list.where((p) => p.id != id).toList();

/// The printer to use: the selected one, else the last used, else the first.
SavedPrinter? pickDefaultPrinter(List<SavedPrinter> list, String? selectedId) {
  if (list.isEmpty) return null;
  final selected = list.where((p) => p.id == selectedId).firstOrNull;
  if (selected != null) return selected;
  final used = list.where((p) => p.lastPrintedAt != null).toList()
    ..sort((a, b) => b.lastPrintedAt!.compareTo(a.lastPrintedAt!));
  return used.firstOrNull ?? list.first;
}
