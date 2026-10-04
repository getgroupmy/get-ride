// The driver's saved receipt printers, ported from the Expo app's
// `utils/printerStore.ts` (the pure half). Kept on the device: a printer is
// paired to the phone in the car, not to the account.
//
// This slice prints over Wi-Fi only (a raw TCP socket to the ESC/POS port);
// the transport field is kept so Bluetooth printers added later fit the same
// list.

import 'escpos.dart';

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
