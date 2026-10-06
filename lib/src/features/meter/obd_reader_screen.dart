import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../core/obd.dart';
import '../../core/obd_adapters.dart';
import '../../core/obd_ble.dart';
import '../../core/fuel_range.dart' show odometerAbsentReads, odometerRefreshMs, readOdometerKm;
import '../../core/obd_mfi.dart';
import '../../data/ble.dart';
import '../../data/obd/obd_mfi_transport.dart';
import '../../data/obd/obd_session.dart';
import 'ble_scan_sheet.dart';

/// The MFi accessories paired with this iPhone. Overridden in tests.
final mfiAccessoriesProvider = Provider<Future<List<MfiAccessory>> Function()>((_) => listMfiAccessories);

/// Reads the odometer off the live reader (mode 01 PID A6), retrying as the
/// meter does; null when the car does not answer. Overridden in tests.
final readerOdometerProvider = Provider<Future<double?> Function()>((ref) => () {
  final session = ref.read(obdSessionProvider.notifier);
  return readOdometerKm((command) async => await session.request(command) ?? (throw StateError('offline')));
});

/// The telemetry shown on the status card, in this order.
const _liveKeys = ['speed', 'rpm', 'coolantTemp', 'moduleVoltage', 'engineLoad', 'fuelLevel'];

/// OBD-II reader settings (Expo `app/obd2-reader.tsx`): the driver's saved
/// readers, which one the meter connects to, and the live link. Readers
/// connect over Wi-Fi or Bluetooth LE (found with an in-app scan: a BLE
/// dongle never appears in the phone's own Bluetooth list).
class ObdReaderScreen extends ConsumerStatefulWidget {
  const ObdReaderScreen({super.key});

  @override
  ConsumerState<ObdReaderScreen> createState() => _ObdReaderScreenState();
}

class _ObdReaderScreenState extends ConsumerState<ObdReaderScreen> {
  List<SavedObdAdapter> _adapters = const [];
  String? _selectedId;
  bool _loaded = false;

  // The odometer, read on demand (it is not in the 1 Hz sweep): on link-up,
  // then every [odometerRefreshMs] while the page is open.
  double? _odometerKm;
  int _odometerMisses = 0;
  bool _readingOdometer = false;
  Timer? _odometerTimer;

  @override
  void initState() {
    super.initState();
    _reload();
    // Opening the page reconnects the selected reader, as Expo's useCanbus
    // does wherever it is mounted.
    if (!kIsWeb) Future.microtask(() => ref.read(obdSessionProvider.notifier).ensureConnected());
    ref.listenManual(obdSessionProvider.select((s) => s.linked), (_, linked) {
      _odometerTimer?.cancel();
      if (!linked) return;
      _odometerMisses = 0;
      unawaited(_readOdometer());
      _odometerTimer = Timer.periodic(const Duration(milliseconds: odometerRefreshMs), (_) => _readOdometer());
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _odometerTimer?.cancel();
    super.dispose();
  }

  Future<void> _readOdometer() async {
    if (_readingOdometer) return;
    _readingOdometer = true;
    try {
      final km = await ref.read(readerOdometerProvider)();
      if (!mounted) return;
      setState(() {
        if (km != null) {
          _odometerKm = km;
          _odometerMisses = 0;
        } else {
          _odometerMisses++;
        }
      });
    } finally {
      _readingOdometer = false;
    }
  }

  Future<void> _reload() async {
    final store = ref.read(obdAdapterStoreProvider);
    final list = await store.load();
    final selected = pickDefaultAdapter(list, await store.selectedId())?.id;
    if (!mounted) return;
    setState(() {
      _adapters = list;
      _selectedId = selected;
      _loaded = true;
    });
  }

  Future<void> _use(SavedObdAdapter a) async {
    await ref.read(obdAdapterStoreProvider).select(a.id);
    await _reload();
    await ref.read(obdSessionProvider.notifier).connect(a);
  }

  Future<void> _delete(SavedObdAdapter a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove reader?'),
        content: Text('${a.name} will be removed from this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    final session = ref.read(obdSessionProvider);
    if (session.adapter?.id == a.id) await ref.read(obdSessionProvider.notifier).disconnect();
    final store = ref.read(obdAdapterStoreProvider);
    await store.save(removeAdapter(await store.load(), a.id));
    if (_selectedId == a.id) await store.select(null);
    await _reload();
  }

  Future<void> _add() async {
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('How does the reader connect?')),
          ListTile(
            leading: const Icon(Icons.bluetooth),
            title: const Text('Bluetooth reader'),
            subtitle: const Text('Plugged in and powered by the car; found with a scan'),
            onTap: () => Navigator.pop(c, 'bluetooth'),
          ),
          if (mfiSupported)
            ListTile(
              key: const ValueKey('add-mfi-reader'),
              leading: const Icon(Icons.bluetooth_connected),
              title: const Text('Bluetooth MFi reader'),
              subtitle: const Text('Certified readers such as OBDLink MX+, paired in Settings → Bluetooth'),
              onTap: () => Navigator.pop(c, 'mfi'),
            ),
          ListTile(
            leading: const Icon(Icons.wifi),
            title: const Text('Wi-Fi reader'),
            subtitle: const Text("Join the reader's Wi-Fi network first"),
            onTap: () => Navigator.pop(c, 'wifi'),
          ),
        ]),
      ),
    );
    if (kind == null || !mounted) return;
    final added = switch (kind) {
      'wifi' => await showDialog<SavedObdAdapter>(context: context, builder: (_) => const _AddWifiReaderDialog()),
      'mfi' => await _pickMfiReader(),
      _ => await _pickBleReader(),
    };
    if (added == null) return;
    final store = ref.read(obdAdapterStoreProvider);
    final list = upsertAdapter(await store.load(), added);
    await store.save(list);
    // Re-adding the same reader keeps its saved entry (and its id).
    final saved = list.firstWhere((a) => a.transport == added.transport &&
        (added.transport == 'wifi' ? a.host == added.host && a.port == added.port : a.deviceId == added.deviceId));
    await store.select(saved.id);
    await _reload();
    await ref.read(obdSessionProvider.notifier).connect(saved);
  }

  /// The MFi accessories paired with this iPhone (Expo's MFi picker): they
  /// are paired in the Settings app, not found by a scan, so the list is
  /// what iOS already knows. Readers by name come first.
  Future<SavedObdAdapter?> _pickMfiReader() async {
    List<MfiAccessory> paired;
    try {
      paired = await ref.read(mfiAccessoriesProvider)();
    } catch (_) {
      paired = const [];
    }
    if (!mounted) return null;
    final ordered = [...paired.where(isLikelyMfiReader), ...paired.where((a) => !isLikelyMfiReader(a))];
    final picked = await showModalBottomSheet<MfiAccessory>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          key: const ValueKey('mfi-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ListTile(title: Text('Paired MFi readers')),
            if (ordered.isEmpty)
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('No MFi reader is connected'),
                subtitle: Text(
                  'Pair the reader in Settings → Bluetooth with the ignition on, then come back here. '
                  'Readers that are not MFi-certified are added as Bluetooth readers instead.',
                ),
              ),
            for (final a in ordered)
              ListTile(
                leading: const Icon(Icons.settings_input_component),
                title: Text(a.name.isEmpty ? 'MFi accessory' : a.name),
                subtitle: a.serial.isEmpty ? null : Text('Serial ${a.serial}'),
                onTap: () => Navigator.pop(c, a),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return null;
    return normalizeMfiAdapter(
      id: const Uuid().v4(),
      createdAt: DateTime.now().toUtc().toIso8601String(),
      key: mfiAccessoryKey(picked),
      accessoryName: picked.name,
    ).value;
  }

  Future<SavedObdAdapter?> _pickBleReader() async {
    final d = await showModalBottomSheet<BleSighting>(
      context: context,
      isScrollControlled: true,
      builder: (_) => BleScanSheet(
        title: 'Bluetooth readers nearby',
        filter: (d) => matchesElmAdvertisement(name: d.name, services: d.services),
        showAllHint: 'For a reader that does not advertise an OBD-II name',
        looking: 'Looking for readers… Keep the phone near the car with the ignition on.',
        nothingFound: 'No reader found. Check it is plugged in with the ignition on, then scan again.',
      ),
    );
    if (d == null) return null;
    return normalizeBleAdapter(
      id: const Uuid().v4(),
      createdAt: DateTime.now().toUtc().toIso8601String(),
      deviceId: d.deviceId,
      advertisedName: d.name,
    ).value;
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(obdSessionProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('OBD-II reader')),
      floatingActionButton: kIsWeb
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('Add reader'),
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          if (kIsWeb)
            const Card(
              child: ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('Use the phone app'),
                subtitle: Text('A browser cannot talk to an OBD-II reader. Open GET.ride on the phone in the car.'),
              ),
            ),
          _StatusCard(
            session: session,
            odometerKm: _odometerKm,
            odometerAbsent: _odometerKm == null && _odometerMisses >= odometerAbsentReads,
          ),
          const SizedBox(height: 16),
          Text('Saved readers', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'The meter connects to the selected reader when it opens and bills on the vehicle speed while it '
            'answers, falling back to GPS where the rate card allows it.',
          ),
          const SizedBox(height: 8),
          if (_loaded && _adapters.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.settings_input_component),
                title: Text('No reader yet'),
                subtitle: Text('Plug the reader into the OBD-II port with the ignition on, then add it here.'),
              ),
            ),
          for (final a in _adapters) _adapterTile(a, session),
        ],
      ),
    );
  }

  Widget _adapterTile(SavedObdAdapter a, ObdSessionState session) {
    final selected = a.id == _selectedId;
    final current = session.adapter?.id == a.id && session.phase != ObdPhase.idle;
    final busy = current && (session.phase == ObdPhase.connecting || session.phase == ObdPhase.handshaking);
    return Card(
      child: ListTile(
        leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
        title: Text(a.name),
        subtitle: Text(describeAdapter(a)),
        onTap: kIsWeb ? null : () => _use(a),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (current && session.phase != ObdPhase.error)
              TextButton(
                onPressed: busy ? null : () => ref.read(obdSessionProvider.notifier).disconnect(),
                child: Text(busy ? 'Connecting…' : 'Disconnect'),
              )
            else if (!kIsWeb)
              TextButton(onPressed: () => _use(a), child: const Text('Connect')),
            IconButton(
              tooltip: 'Remove ${a.name}',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(a),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.session, this.odometerKm, this.odometerAbsent = false});

  final ObdSessionState session;

  /// The last odometer the car answered with.
  final double? odometerKm;

  /// The car has not answered PID A6 over repeated reads: it does not publish
  /// its odometer on the diagnostic bus.
  final bool odometerAbsent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (session.phase) {
      ObdPhase.idle => ('Not connected', scheme.outline),
      ObdPhase.connecting => ('Connecting…', scheme.tertiary),
      ObdPhase.handshaking => ('Talking to the reader…', scheme.tertiary),
      ObdPhase.online => ('Connected', Colors.green),
      ObdPhase.error => ('Not reachable', scheme.error),
    };
    final values = [
      for (final k in _liveKeys)
        if (session.telemetry[k] != null) (obdPids[k]!.label, formatTelemetryValue(k, session.telemetry[k]!)),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 12, color: color),
                const SizedBox(width: 8),
                Text(label, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            if (session.adapter != null) ...[const SizedBox(height: 4), Text(session.adapter!.name)],
            if (session.device != null) Text('Device ${session.device}'),
            if (session.protocol != null) Text('Protocol ${session.protocol}'),
            if (session.phase == ObdPhase.error && session.error != null) ...[
              const SizedBox(height: 4),
              Text(session.error!, style: TextStyle(color: scheme.error)),
              const Text(
                'Retrying every few seconds. Check the ignition is on and the phone is on the reader\'s Wi-Fi.',
              ),
            ],
            if (session.linked) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('open-vehicle-info'),
                icon: const Icon(Icons.directions_car_outlined),
                label: const Text('Vehicle information'),
                onPressed: () => context.push('/meter/vehicle'),
              ),
            ],
            if (session.linked && (odometerKm != null || odometerAbsent)) ...[
              const SizedBox(height: 12),
              Row(
                key: const ValueKey('reader-odometer'),
                children: [
                  const Icon(Icons.speed, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      odometerKm != null
                          ? 'Odometer ${NumberFormat('#,##0.0').format(odometerKm)} km'
                          : 'This vehicle does not publish its odometer (PID A6).',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
            ],
            if (session.linked && values.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 24,
                runSpacing: 8,
                children: [
                  for (final (name, value) in values)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: Theme.of(context).textTheme.labelSmall),
                        Text(value, style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AddWifiReaderDialog extends StatefulWidget {
  const _AddWifiReaderDialog();

  @override
  State<_AddWifiReaderDialog> createState() => _AddWifiReaderDialogState();
}

class _AddWifiReaderDialogState extends State<_AddWifiReaderDialog> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _save() {
    final r = normalizeWifiAdapter(
      id: const Uuid().v4(),
      createdAt: DateTime.now().toUtc().toIso8601String(),
      name: _name.text,
      host: _host.text,
      port: _port.text,
    );
    if (r.error != null) return setState(() => _error = r.error);
    Navigator.pop(context, r.value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Wi-Fi reader'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Join the reader\'s Wi-Fi network (often "OBDII" or "WiFi_OBDII") in the phone\'s settings first. '
              'Leave the address blank for the usual 192.168.0.10:35000.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name (optional)'),
            ),
            TextField(
              controller: _host,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'IP address', hintText: wifiAdapterHost),
            ),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Port', hintText: '$wifiAdapterPort'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save & connect')),
      ],
    );
  }
}
