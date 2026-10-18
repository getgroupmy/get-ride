import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/obd_adapters.dart';
import '../../core/printers.dart';
import '../../data/printer/classic_bluetooth.dart';

/// Lists the devices paired with this phone and returns the one the driver
/// taps, for a classic Bluetooth (SPP) receipt printer. A classic printer is
/// paired in Android's own Bluetooth settings, never by a scan here, so the
/// sheet says so and offers a way there; it re-reads the list when the driver
/// comes back.
class ClassicPairedSheet extends ConsumerStatefulWidget {
  const ClassicPairedSheet({super.key, this.readers = const []});

  /// The saved OBD-II readers, left out of the list.
  final List<SavedObdAdapter> readers;

  @override
  ConsumerState<ClassicPairedSheet> createState() => _ClassicPairedSheetState();
}

/// What a failed listing tells the driver.
String describePairedListError(Object e) {
  if (e is UnsupportedError) return e.message ?? 'Classic Bluetooth printers are not supported here.';
  if (e is ClassicBluetoothException) {
    return switch (e.code) {
      'bluetooth_off' || 'permission' || 'no_bluetooth' => describeClassicPrinterError(e.code, 'the printer'),
      _ => 'Could not read the paired devices${e.message == null ? '' : ': ${e.message}'}.',
    };
  }
  return 'Could not read the paired devices.';
}

class _ClassicPairedSheetState extends ConsumerState<ClassicPairedSheet> {
  List<BondedBluetoothDevice>? _devices;
  String? _error;
  bool _loading = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Back from Android's Bluetooth settings: a printer may just have paired.
    _lifecycle = AppLifecycleListener(onResume: _load);
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ref.read(classicBluetoothProvider).bondedDevices();
      if (!mounted) return;
      setState(() => _devices = rankBondedPrinters(list, readers: widget.readers));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = describePairedListError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openSettings() async {
    final opened = await ref.read(classicBluetoothProvider).openSettings();
    if (opened || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Open Settings → Bluetooth on this phone to pair the printer.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final devices = _devices ?? const <BondedBluetoothDevice>[];
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.55,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: const Text('Paired Bluetooth printers'),
              subtitle: Text(_loading ? 'Reading paired devices…' : 'Devices paired with this phone'),
              trailing: _loading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton(onPressed: _load, child: const Text('Refresh')),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                margin: EdgeInsets.zero,
                color: scheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Pair the printer in Android Bluetooth settings first (its PIN is usually 0000 or 1234), '
                        'then come back and pick it here.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.settings_bluetooth),
                        label: const Text('Open Bluetooth settings'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_error != null)
              ListTile(
                leading: Icon(Icons.error_outline, color: scheme.error),
                title: Text(_error!),
              ),
            Expanded(
              child: devices.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _devices == null
                              ? ''
                              : 'No paired devices. Switch the printer on and pair it in Android Bluetooth '
                                    'settings.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final d in devices)
                          ListTile(
                            leading: Icon(
                              d.majorClass == bluetoothMajorImaging ? Icons.print_outlined : Icons.bluetooth,
                            ),
                            title: Text((d.name ?? '').trim().isEmpty ? 'Unnamed device' : d.name!),
                            subtitle: Text(d.address),
                            onTap: () => Navigator.pop(context, d),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
