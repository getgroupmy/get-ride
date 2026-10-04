import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import '../../core/obd_ble.dart' show BleCharacteristicInfo, chunkBleWrite;
import '../../core/printers.dart';
import '../ble.dart';

/// The saved printers, on this device (Expo `printerStore`).
class PrinterStore {
  static const listKey = 'meter_printers_v1';
  static const selectedKey = 'meter_selected_printer_v1';

  Future<List<SavedPrinter>> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(listKey);
      if (raw == null) return const [];
      final list = jsonDecode(raw);
      return list is List ? list.map(SavedPrinter.fromJson).whereType<SavedPrinter>().toList() : const [];
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<SavedPrinter> list) async =>
      (await SharedPreferences.getInstance()).setString(listKey, jsonEncode([for (final p in list) p.toJson()]));

  Future<String?> selectedId() async => (await SharedPreferences.getInstance()).getString(selectedKey);

  Future<void> select(String? id) async {
    final p = await SharedPreferences.getInstance();
    id == null ? await p.remove(selectedKey) : await p.setString(selectedKey, id);
  }

  /// The printer receipts go to, if any.
  Future<SavedPrinter?> current() async => pickDefaultPrinter(await load(), await selectedId());

  Future<void> markPrinted(String id, int at) async =>
      save([for (final p in await load()) p.id == id ? p.copyWith(lastPrintedAt: at) : p]);
}

/// A one-shot ESC/POS link: a printer is written to and closed, with no read
/// side and no session kept open between jobs.
abstract class PrinterSink {
  Future<void> connect();

  /// Writes an ESC/POS document (every character ≤ 0x7F).
  Future<void> write(String payload);
  Future<void> close();
}

/// A network printer: a raw TCP socket to its ESC/POS port. Dart's own
/// sockets, so there is no native module to be missing; a browser cannot open
/// one at all.
class WifiPrinterSink implements PrinterSink {
  WifiPrinterSink(this.host, this.port, {this.connectTimeout = const Duration(seconds: 10)});

  final String host;
  final int port;
  final Duration connectTimeout;
  Socket? _socket;

  @override
  Future<void> connect() async {
    if (kIsWeb) throw UnsupportedError('A browser cannot print to a Wi-Fi printer. Use the phone app.');
    _socket = await Socket.connect(host, port, timeout: connectTimeout);
  }

  @override
  Future<void> write(String payload) async {
    final s = _socket;
    if (s == null) throw StateError('not connected');
    s.add(latin1.encode(payload));
    await s.flush();
  }

  @override
  Future<void> close() async {
    final s = _socket;
    _socket = null;
    try {
      await s?.close();
    } catch (_) {}
    s?.destroy();
  }
}

/// A Bluetooth LE mini printer (Expo `BlePrinterTransport`): connects to the
/// peripheral picked from the scan, finds where to write and streams the
/// document in packets the link can carry.
class BlePrinterSink implements PrinterSink {
  BlePrinterSink(this.deviceId, {this.connectTimeout = const Duration(seconds: 20), this.packetGap});

  final String deviceId;
  final Duration connectTimeout;

  /// The pause between packets written without response, so a cheap
  /// printer's buffer is not overrun. Defaults to [blePrinterPacketGap].
  final Duration? packetGap;

  ({String service, String write, bool withResponse})? _target;
  int _packet = 20;

  @override
  Future<void> connect() async {
    await ensureBluetoothReady();
    try {
      await _open();
    } catch (_) {
      try {
        await UniversalBle.disconnect(deviceId);
      } catch (_) {}
      await findBlePeripheral(deviceId,
          notFound: 'Could not find the printer. Check it is switched on and close to this phone.');
      await _open();
    }
  }

  Future<void> _open() async {
    await UniversalBle.connect(deviceId, timeout: connectTimeout);
    final services = await UniversalBle.discoverServices(deviceId);
    final target = resolveBlePrinterWrite([
      for (final s in services)
        (
          uuid: s.uuid,
          characteristics: [
            for (final c in s.characteristics)
              BleCharacteristicInfo(
                c.uuid,
                write: c.properties.contains(CharacteristicProperty.write),
                writeWithoutResponse: c.properties.contains(CharacteristicProperty.writeWithoutResponse),
              ),
          ],
        ),
    ]);
    if (target == null) throw StateError('Connected, but this device has nowhere to print to. Is it a printer?');
    _target = target;
    _packet = blePrinterPacketSize(await _mtu());
  }

  Future<int?> _mtu() async {
    try {
      return await UniversalBle.requestMtu(deviceId, 247);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String payload) async {
    final t = _target;
    if (t == null) throw StateError('not connected');
    final gap = packetGap ?? blePrinterPacketGap;
    for (final packet in chunkBleWrite(latin1.encode(payload), size: _packet)) {
      await UniversalBle.write(deviceId, t.service, t.write, Uint8List.fromList(packet),
          withoutResponse: !t.withResponse);
      if (!t.withResponse && gap > Duration.zero) await Future<void>.delayed(gap);
    }
  }

  @override
  Future<void> close() async {
    _target = null;
    try {
      await UniversalBle.disconnect(deviceId);
    } catch (_) {}
  }
}

/// Builds the link for a saved printer. A seam so tests can capture output.
final printerSinkFactoryProvider = Provider<PrinterSink Function(SavedPrinter)>(
  (_) => (p) => switch (p.transport) {
        'wifi' => WifiPrinterSink(p.host ?? '', p.port ?? printerWifiPort),
        'bluetooth' when p.address != null => BlePrinterSink(p.address!),
        _ => throw UnsupportedError(
            '${printerTransportLabels[p.transport] ?? p.transport} printers are not supported in this version of the app yet.'),
      },
);

final printerStoreProvider = Provider((_) => PrinterStore());

/// How long to hold the link open after the last byte: some mini printers
/// drop the tail of a job if the socket closes at once.
final printerSettleProvider = Provider((_) => const Duration(milliseconds: 400));

/// Prints one document: connect, write, settle, close (Expo `sendToPrinter`).
/// The link is always torn down, even when the write throws. Answers null on
/// success, else what to tell the driver.
class PrinterService {
  PrinterService(this._ref);
  final Ref _ref;

  Future<String?> send(SavedPrinter printer, String payload) async {
    PrinterSink? sink;
    try {
      sink = _ref.read(printerSinkFactoryProvider)(printer);
      await sink.connect();
      await sink.write(payload);
      await Future<void>.delayed(_ref.read(printerSettleProvider));
      unawaited(_ref.read(printerStoreProvider).markPrinted(printer.id, DateTime.now().millisecondsSinceEpoch));
      return null;
    } catch (e) {
      return describePrintError(e, printer);
    } finally {
      await sink?.close();
    }
  }
}

final printerServiceProvider = Provider(PrinterService.new);

/// What a failed print tells the driver.
String describePrintError(Object e, SavedPrinter printer) {
  if (e is UnsupportedError) return e.message ?? 'This printer is not supported here.';
  if (e is StateError) return e.message;
  if (printer.transport == 'bluetooth') {
    return 'Could not reach ${printer.name} over Bluetooth. Check it is switched on, close to this phone '
        'and not connected to another phone.';
  }
  if (e is SocketException || e is TimeoutException) {
    return 'Could not reach ${printer.name} at ${printer.host}:${printer.port ?? printerWifiPort}. '
        'Check it is switched on and on the same Wi-Fi as this phone.';
  }
  return 'Could not print: $e';
}
