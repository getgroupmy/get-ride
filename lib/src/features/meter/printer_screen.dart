import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/escpos.dart';
import '../../core/printers.dart';
import '../../data/printer/printer_service.dart';
import 'meter_providers.dart';

/// Receipt printer settings (Expo `app/meter-printer.tsx`): the driver's
/// saved mini thermal printers, which one receipts go to, a test print and a
/// reprint of the last receipt. This slice adds Wi-Fi (ESC/POS over TCP)
/// printers; Bluetooth comes later.
class PrinterScreen extends ConsumerStatefulWidget {
  const PrinterScreen({super.key});

  @override
  ConsumerState<PrinterScreen> createState() => _PrinterScreenState();
}

class _PrinterScreenState extends ConsumerState<PrinterScreen> {
  List<SavedPrinter> _printers = const [];
  String? _selectedId;
  bool _loaded = false;

  /// The printer a job is running on, so its buttons show progress.
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final store = ref.read(printerStoreProvider);
    final list = await store.load();
    final selected = pickDefaultPrinter(list, await store.selectedId())?.id;
    if (!mounted) return;
    setState(() {
      _printers = list;
      _selectedId = selected;
      _loaded = true;
    });
  }

  Future<void> _select(SavedPrinter p) async {
    await ref.read(printerStoreProvider).select(p.id);
    await _reload();
  }

  Future<void> _print(SavedPrinter p, String payload, String done) async {
    setState(() => _busyId = p.id);
    final error = await ref.read(printerServiceProvider).send(p, payload);
    if (!mounted) return;
    setState(() => _busyId = null);
    _say(error ?? done);
    await _reload();
  }

  void _say(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  Future<void> _test(SavedPrinter p) => _print(p, buildTestPrintEscpos(paper: p.paper), 'Test page sent to ${p.name}.');

  Future<void> _printLast(SavedPrinter p) async {
    final trips = await ref.read(meterTripsStoreProvider).load();
    if (!mounted) return;
    if (trips.isEmpty) return _say('No hires on this device yet.');
    await _print(p, buildMeterReceiptEscpos(trips.first, paper: p.paper), 'Last receipt sent to ${p.name}.');
  }

  Future<void> _delete(SavedPrinter p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove printer?'),
        content: Text('${p.name} will be removed from this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    final store = ref.read(printerStoreProvider);
    await store.save(removePrinter(await store.load(), p.id));
    if (_selectedId == p.id) await store.select(null);
    await _reload();
  }

  Future<void> _add() async {
    final added = await showDialog<SavedPrinter>(context: context, builder: (_) => const _AddWifiPrinterDialog());
    if (added == null) return;
    final store = ref.read(printerStoreProvider);
    final list = upsertPrinter(await store.load(), added);
    await store.save(list);
    // The same host and port keeps the saved printer's id.
    final saved = list.firstWhere((p) => p.host == added.host && p.port == added.port);
    await store.select(saved.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receipt printer')),
      floatingActionButton: kIsWeb
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('Add Wi-Fi printer'),
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          if (kIsWeb)
            const Card(
              child: ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('Use the phone app'),
                subtitle: Text('A browser cannot print to a receipt printer. Open GET.ride on the phone in the car.'),
              ),
            ),
          const Text(
            'Receipts print straight to the selected mini thermal (ESC/POS) printer, with no print dialog. '
            'The printer and this phone must be on the same Wi-Fi.',
          ),
          const SizedBox(height: 8),
          if (_loaded && _printers.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.print_outlined),
                title: Text('No printer yet'),
                subtitle: Text("Print the printer's self-test page (usually by holding the feed button as it powers on) "
                    'to find its IP address, then add it here.'),
              ),
            ),
          for (final p in _printers) _printerCard(p),
        ],
      ),
    );
  }

  Widget _printerCard(SavedPrinter p) {
    final selected = p.id == _selectedId;
    final busy = _busyId == p.id;
    final idle = _busyId == null && !kIsWeb;
    return Card(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
            leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
            title: Text(p.name),
            subtitle: Text(selected ? '${describePrinter(p)}\nReceipts print here' : describePrinter(p)),
            isThreeLine: selected,
            onTap: () => _select(p),
            trailing: IconButton(
              tooltip: 'Remove ${p.name}',
              icon: const Icon(Icons.delete_outline),
              onPressed: busy ? null : () => _delete(p),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                onPressed: idle ? () => _test(p) : null,
                icon: busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.print_outlined),
                label: const Text('Test print'),
              ),
              OutlinedButton.icon(
                onPressed: idle ? () => _printLast(p) : null,
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('Print last receipt'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _AddWifiPrinterDialog extends StatefulWidget {
  const _AddWifiPrinterDialog();

  @override
  State<_AddWifiPrinterDialog> createState() => _AddWifiPrinterDialogState();
}

class _AddWifiPrinterDialogState extends State<_AddWifiPrinterDialog> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  PaperWidth _paper = PaperWidth.mm58;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _save() {
    final r = normalizeWifiPrinter(
      id: const Uuid().v4(),
      createdAt: DateTime.now().toUtc().toIso8601String(),
      name: _name.text,
      host: _host.text,
      port: _port.text,
      paper: _paper,
    );
    if (r.error != null) return setState(() => _error = r.error);
    Navigator.pop(context, r.value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Wi-Fi printer'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name (optional)')),
          TextField(
            controller: _host,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'IP address', hintText: '192.168.0.50'),
          ),
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Port', hintText: '$printerWifiPort'),
          ),
          const SizedBox(height: 16),
          const Text('Paper width'),
          const SizedBox(height: 8),
          SegmentedButton<PaperWidth>(
            segments: [for (final w in PaperWidth.values) ButtonSegment(value: w, label: Text(w.label))],
            selected: {_paper},
            onSelectionChanged: (s) => setState(() => _paper = s.first),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
