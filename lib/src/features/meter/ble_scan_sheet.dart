import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ble.dart';

/// Scans for Bluetooth LE devices and returns the one the driver taps (the
/// add-reader and add-printer sheets). A BLE dongle or mini printer never
/// shows in the phone's own Bluetooth list, so this in-app scan is the only
/// way to find one.
class BleScanSheet extends ConsumerStatefulWidget {
  const BleScanSheet({
    super.key,
    required this.title,
    this.filter,
    required this.showAllHint,
    required this.looking,
    required this.nothingFound,
  });

  final String title;

  /// Which sightings are offered until "show all" is on; null offers all.
  final bool Function(BleSighting d)? filter;
  final String showAllHint;
  final String looking;
  final String nothingFound;

  @override
  ConsumerState<BleScanSheet> createState() => _BleScanSheetState();
}

class _BleScanSheetState extends ConsumerState<BleScanSheet> {
  final _seen = <String, BleSighting>{};
  StreamSubscription<BleSighting>? _sub;
  bool _scanning = false;
  bool _showAll = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _scan() {
    _sub?.cancel();
    setState(() {
      _scanning = true;
      _error = null;
    });
    _sub = ref.read(bleScannerProvider).scan().listen(
      (d) {
        if (!mounted) return;
        // A reader can advertise its name in a later packet than its id.
        final before = _seen[d.deviceId];
        setState(() => _seen[d.deviceId] = (
              deviceId: d.deviceId,
              name: (d.name ?? '').isNotEmpty ? d.name : before?.name,
              services: d.services.isNotEmpty ? d.services : (before?.services ?? const []),
              rssi: d.rssi,
            ));
      },
      // An error ends the scan (there is no done event after it).
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _scanning = false;
          _error = '$e'.replaceFirst(RegExp(r'^(Bad state|Unsupported operation): '), '');
        });
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
      cancelOnError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final filter = widget.filter;
    final readers = _seen.values.where((d) => _showAll || filter == null || filter(d)).toList()
      ..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999));
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ListTile(
            title: Text(widget.title),
            subtitle: Text(_scanning ? 'Scanning…' : 'Scan finished'),
            trailing: _scanning
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : TextButton(onPressed: _scan, child: const Text('Scan again')),
          ),
          SwitchListTile(
            title: const Text('Show all Bluetooth devices'),
            subtitle: Text(widget.showAllHint),
            value: _showAll,
            onChanged: (v) => setState(() => _showAll = v),
          ),
          if (_error != null)
            ListTile(
              leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
              title: Text(_error!),
            ),
          Expanded(
            child: readers.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _scanning ? widget.looking : widget.nothingFound,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView(children: [
                    for (final d in readers)
                      ListTile(
                        leading: const Icon(Icons.bluetooth),
                        title: Text((d.name ?? '').isEmpty ? 'Unnamed device' : d.name!),
                        subtitle: Text(d.deviceId),
                        trailing: d.rssi == null ? null : Text('${d.rssi} dBm'),
                        onTap: () => Navigator.pop(context, d),
                      ),
                  ]),
          ),
        ]),
      ),
    );
  }
}
