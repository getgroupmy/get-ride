import 'dart:typed_data';

import 'package:get_ride/src/core/printers.dart';
import 'package:get_ride/src/data/printer/classic_bluetooth.dart';

/// Stands in for the phone's classic Bluetooth: a fixed paired list, and a
/// link that keeps what it was sent or refuses with a platform error code.
class FakeClassicBluetooth implements ClassicBluetooth {
  FakeClassicBluetooth({this.devices = const [], this.listError, this.connectError});

  List<BondedBluetoothDevice> devices;
  String? listError;
  String? connectError;
  final writes = <Uint8List>[];
  final connected = <String>[];
  int closes = 0;
  int settingsOpened = 0;
  bool open = false;

  @override
  Future<List<BondedBluetoothDevice>> bondedDevices() async {
    if (listError != null) throw ClassicBluetoothException(listError!);
    return devices;
  }

  @override
  Future<void> connect(String address, {Duration timeout = const Duration(seconds: 12)}) async {
    if (connectError != null) throw ClassicBluetoothException(connectError!);
    connected.add(address);
    open = true;
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (!open) throw const ClassicBluetoothException('not_connected');
    writes.add(bytes);
  }

  @override
  Future<void> close() async {
    open = false;
    closes++;
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }

  /// Everything written, joined back into one document.
  String get printed => String.fromCharCodes([for (final w in writes) ...w]);
}
