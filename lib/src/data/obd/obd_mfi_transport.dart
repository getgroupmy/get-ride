import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/obd.dart';
import '../../core/obd_mfi.dart';
import 'obd_transport.dart';

/// The native side was removed from the iOS app (App Review 2.1.0: the
/// External Accessory protocol needs MFi authorisation GET.ride doesn't
/// hold). Bluetooth LE and Wi-Fi readers carry on.
const mfiMethods = MethodChannel('get_ride/mfi');
const mfiEvents = EventChannel('get_ride/mfi/data');

/// No build offers MFi readers any more; a reader saved before says so.
bool get mfiSupported => debugMfiSupported ?? false;

/// Overrides [mfiSupported] in tests, which never run on iOS.
@visibleForTesting
bool? debugMfiSupported;

/// The readers paired with this iPhone that speak a declared protocol.
Future<List<MfiAccessory>> listMfiAccessories() async {
  if (!mfiSupported) return const [];
  final raw = await mfiMethods.invokeListMethod<Object?>('list') ?? const [];
  return [for (final m in raw) ?mfiAccessoryFromMap(m)];
}

/// An ELM327 over Bluetooth MFi (Expo's MFi transport): opens an External
/// Accessory session to the paired reader saved as [key] and streams the
/// replies.
class MfiObdTransport implements ObdTransport {
  MfiObdTransport(this.key, {this.name});

  /// The saved reader's serial number, or its name (see [mfiAccessoryKey]).
  final String key;
  final String? name;

  StreamSubscription<Object?>? _sub;
  final _data = StreamController<String>.broadcast();

  @override
  String get kind => 'mfi';

  @override
  Stream<String> get data => _data.stream;

  @override
  Future<String> connect() async {
    if (!mfiSupported) {
      throw UnsupportedError(
        'Bluetooth MFi readers are no longer supported. Add a Bluetooth LE or Wi-Fi reader in Settings → OBD-II reader.',
      );
    }
    await disconnect();
    final accessory = pickMfiAccessory(await listMfiAccessories(), preferred: key);
    if (accessory == null) {
      throw StateError(
        '${name ?? 'The reader'} is not connected to this iPhone. Pair it in Settings → Bluetooth and turn the '
        'ignition on.',
      );
    }
    // Errors on the stream are left to the client, which notices the silence.
    _sub = mfiEvents.receiveBroadcastStream().listen((chunk) {
      if (chunk is String) _data.add(chunk);
    }, onError: (_) {});
    try {
      final opened = await mfiMethods.invokeMethod<String>('connect', {'id': accessory.connectionId});
      return opened ?? accessory.name;
    } on PlatformException catch (e) {
      await disconnect();
      throw StateError(e.message ?? 'Could not open the reader.');
    }
  }

  @override
  Future<void> write(String command) => mfiMethods.invokeMethod<void>('write', {'text': '$command$elmCr'});

  @override
  Future<void> disconnect() async {
    unawaited(_sub?.cancel());
    _sub = null;
    if (!mfiSupported) return;
    try {
      await mfiMethods.invokeMethod<void>('disconnect');
    } catch (_) {}
  }
}
