// The driver's saved OBD-II readers, ported from the Expo app's
// `utils/canbusAdapterStore.ts` (the pure half). Kept on the device: a reader
// belongs to the phone in the car, not to the account.
//
// This slice of the port connects over Wi-Fi only; the transport field is
// kept so readers added by later slices (Bluetooth LE, MFi, USB) fit the same
// list.

const wifiAdapterHost = '192.168.0.10';
const wifiAdapterPort = 35000;

const obdTransportLabels = {'wifi': 'Wi-Fi', 'bluetooth': 'Bluetooth LE', 'mfi': 'Bluetooth MFi', 'usb': 'USB'};

class SavedObdAdapter {
  const SavedObdAdapter({
    required this.id,
    required this.name,
    required this.transport,
    this.host,
    this.port,
    required this.createdAt,
    this.lastConnectedAt,
  });

  final String id;
  final String name;
  final String transport;
  final String? host;
  final int? port;
  final String createdAt;
  final int? lastConnectedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'transport': transport,
        if (host != null) 'host': host,
        if (port != null) 'port': port,
        'createdAt': createdAt,
        'lastConnectedAt': lastConnectedAt,
      };

  static SavedObdAdapter? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], name = raw['name'], transport = raw['transport'];
    if (id is! String || name is! String || transport is! String) return null;
    return SavedObdAdapter(
      id: id,
      name: name,
      transport: transport,
      host: raw['host'] is String ? raw['host'] as String : null,
      port: raw['port'] is num ? (raw['port'] as num).toInt() : null,
      createdAt: raw['createdAt'] is String ? raw['createdAt'] as String : '',
      lastConnectedAt: raw['lastConnectedAt'] is num ? (raw['lastConnectedAt'] as num).toInt() : null,
    );
  }

  SavedObdAdapter copyWith({String? id, String? createdAt, int? lastConnectedAt}) => SavedObdAdapter(
        id: id ?? this.id,
        name: name,
        transport: transport,
        host: host,
        port: port,
        createdAt: createdAt ?? this.createdAt,
        lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      );
}

final _hostname = RegExp(r'^[A-Za-z0-9._-]+$');

/// Validates the add-reader form (Expo `normalizeAdapterDraft`, Wi-Fi):
/// blank host and port mean the usual ELM327 soft-AP address.
({String? error, SavedObdAdapter? value}) normalizeWifiAdapter({
  required String id,
  required String createdAt,
  String name = '',
  String host = '',
  String port = '',
}) {
  final n = name.trim();
  if (n.length > 60) return (error: 'Name must be 60 characters or fewer.', value: null);
  final h = host.trim().isEmpty ? wifiAdapterHost : host.trim();
  if (!_hostname.hasMatch(h)) return (error: 'Enter a valid IP address or hostname.', value: null);
  final p = port.trim().isEmpty ? wifiAdapterPort : int.tryParse(port.trim());
  if (p == null || p < 1 || p > 65535) {
    return (error: 'Port must be a whole number between 1 and 65535.', value: null);
  }
  return (
    error: null,
    value: SavedObdAdapter(
      id: id,
      name: n.isEmpty ? 'Wi-Fi OBD-II reader' : n,
      transport: 'wifi',
      host: h,
      port: p,
      createdAt: createdAt,
    ),
  );
}

String describeAdapter(SavedObdAdapter a) {
  final label = obdTransportLabels[a.transport] ?? a.transport;
  if (a.transport == 'wifi' && a.host != null) return '$label · ${a.host}:${a.port ?? wifiAdapterPort}';
  return label;
}

bool _sameDevice(SavedObdAdapter a, SavedObdAdapter b) {
  if (a.id == b.id) return true;
  if (a.transport != b.transport) return false;
  if (b.transport == 'wifi') return a.host == b.host && a.port == b.port;
  return true;
}

/// Adds [adapter], or replaces the saved reader for the same device (same
/// host and port), keeping its id.
List<SavedObdAdapter> upsertAdapter(List<SavedObdAdapter> list, SavedObdAdapter adapter) {
  final existing = list.where((a) => _sameDevice(a, adapter)).firstOrNull;
  if (existing == null) return [...list, adapter];
  return [
    for (final a in list)
      a.id == existing.id ? adapter.copyWith(id: existing.id, createdAt: existing.createdAt) : a,
  ];
}

List<SavedObdAdapter> removeAdapter(List<SavedObdAdapter> list, String id) => list.where((a) => a.id != id).toList();

/// The reader to connect to: the selected one, else the most recently
/// connected, else the first.
SavedObdAdapter? pickDefaultAdapter(List<SavedObdAdapter> list, String? selectedId) {
  if (list.isEmpty) return null;
  final selected = list.where((a) => a.id == selectedId).firstOrNull;
  if (selected != null) return selected;
  final connected = list.where((a) => a.lastConnectedAt != null).toList()
    ..sort((a, b) => b.lastConnectedAt!.compareTo(a.lastConnectedAt!));
  return connected.firstOrNull ?? list.first;
}
