import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:universal_ble/universal_ble.dart';

import '../../core/printers.dart';

/// Classic Bluetooth (SPP / RFCOMM) receipt printers on Android: the cheap
/// thermal printers that are paired in the phone's Bluetooth settings and
/// never show up in a Bluetooth LE scan.
///
/// The native side is a small platform channel in
/// android/app/src/main/kotlin/my/getgroup/get_ride/ClassicPrinterChannel.kt.
const classicBluetoothMethods = MethodChannel('get_ride/bt_classic');

/// The platform this build runs on, for [printerTransportAvailability].
PrinterPlatform get currentPrinterPlatform {
  if (debugPrinterPlatform != null) return debugPrinterPlatform!;
  if (kIsWeb) return PrinterPlatform.web;
  if (Platform.isAndroid) return PrinterPlatform.android;
  if (Platform.isIOS) return PrinterPlatform.ios;
  return PrinterPlatform.desktop;
}

/// Overrides [currentPrinterPlatform] in tests, which run on the desktop.
@visibleForTesting
PrinterPlatform? debugPrinterPlatform;

/// A classic Bluetooth failure, with the platform's error code (see
/// [describeClassicPrinterError]).
class ClassicBluetoothException implements Exception {
  const ClassicBluetoothException(this.code, [this.message]);
  final String code;
  final String? message;

  @override
  String toString() => 'ClassicBluetoothException($code${message == null ? '' : ': $message'})';
}

/// The phone's classic Bluetooth: its paired devices and one RFCOMM link at a
/// time. A seam so tests can stand in for the radio.
abstract class ClassicBluetooth {
  /// The devices paired with this phone. Throws [ClassicBluetoothException].
  Future<List<BondedBluetoothDevice>> bondedDevices();

  /// Opens the serial port of the paired device at [address].
  Future<void> connect(String address, {Duration timeout});

  Future<void> write(Uint8List bytes);
  Future<void> close();

  /// Opens the phone's Bluetooth settings, where printers are paired.
  /// Answers false when it could not.
  Future<bool> openSettings();
}

/// [ClassicBluetooth] over the Android platform channel.
class MethodChannelClassicBluetooth implements ClassicBluetooth {
  const MethodChannelClassicBluetooth();

  void _requireAndroid() {
    final a = printerTransportAvailability(classicPrinterTransport, currentPrinterPlatform);
    if (!a.available) throw UnsupportedError(a.reason ?? 'Classic Bluetooth printers are not supported here.');
  }

  /// Android 12+ asks for "Nearby devices" (BLUETOOTH_CONNECT) before a
  /// paired device can be listed or opened; the Bluetooth LE plugin already
  /// asks for exactly that set, so it is reused rather than asked twice.
  Future<void> _permission() async {
    try {
      await UniversalBle.requestPermissions();
    } catch (_) {
      // A refusal shows up as the native side's `permission` error.
    }
  }

  Future<T> _call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on PlatformException catch (e) {
      throw ClassicBluetoothException(e.code, e.message);
    }
  }

  @override
  Future<List<BondedBluetoothDevice>> bondedDevices() async {
    _requireAndroid();
    await _permission();
    final raw = await _call(() => classicBluetoothMethods.invokeListMethod<Object?>('bonded')) ?? const [];
    return [
      for (final m in raw)
        if (m is Map && m['address'] is String)
          (
            address: m['address'] as String,
            name: m['name'] is String ? m['name'] as String : null,
            majorClass: m['majorClass'] is int ? m['majorClass'] as int : null,
          ),
    ];
  }

  @override
  Future<void> connect(String address, {Duration timeout = const Duration(seconds: 12)}) async {
    _requireAndroid();
    await _permission();
    await _call(
      () => classicBluetoothMethods.invokeMethod<void>('connect', {
        'address': address,
        'uuid': classicSppUuid,
        'timeoutMs': timeout.inMilliseconds,
      }),
    );
  }

  @override
  Future<void> write(Uint8List bytes) =>
      _call(() => classicBluetoothMethods.invokeMethod<void>('write', {'bytes': bytes}));

  @override
  Future<void> close() async {
    if (currentPrinterPlatform != PrinterPlatform.android) return;
    try {
      await classicBluetoothMethods.invokeMethod<void>('close');
    } catch (_) {}
  }

  @override
  Future<bool> openSettings() async {
    if (currentPrinterPlatform != PrinterPlatform.android) return false;
    try {
      return await classicBluetoothMethods.invokeMethod<bool>('openSettings') ?? false;
    } catch (_) {
      return false;
    }
  }
}

final classicBluetoothProvider = Provider<ClassicBluetooth>((_) => const MethodChannelClassicBluetooth());
