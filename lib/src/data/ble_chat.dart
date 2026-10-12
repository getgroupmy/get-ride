// Chat over Bluetooth when there's no signal (reliability Phase D3,
// lib/src/core/ble_chat.dart): the driver's phone serves a small GATT
// service, the rider's connects to it once it has seen the driver's phone at
// the kerb (lib/src/data/ble_handshake.dart). Messages this phone couldn't
// get to the server go across, each until the other phone acknowledges it;
// what arrives is shown in the thread until the server has its own copy.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:universal_ble/universal_ble.dart';

import '../core/ble_chat.dart';
import '../core/ride_chat.dart';
import '../core/ride_chat_outbox.dart';

/// The link itself: a seam so tests can play both phones.
abstract class BleChatTransport {
  /// The driver's phone: serve the chat service. False when it can't.
  Future<bool> serve();

  /// The rider's phone: connect to the driver's phone. False when it can't.
  Future<bool> connect(String deviceId);

  /// Frames from the other phone.
  Stream<Uint8List> get incoming;

  /// Whether the other phone is on the link now.
  ValueListenable<bool> get linked;

  /// Sends [frame]; false when it didn't go.
  Future<bool> send(Uint8List frame);

  Future<void> stop();
}

class UniversalBleChatTransport implements BleChatTransport {
  final _incoming = StreamController<Uint8List>.broadcast();
  final _linked = ValueNotifier(false);
  final _subs = <StreamSubscription<Object?>>[];
  bool _serving = false;
  String? _device;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  ValueListenable<bool> get linked => _linked;

  @override
  Future<bool> serve() async {
    if (kIsWeb) return false;
    try {
      await UniversalBlePeripheral.addService(
        BlePeripheralService(
          uuid: bleChatServiceUuid,
          characteristics: [
            BlePeripheralCharacteristic(
              uuid: bleChatRxUuid,
              properties: [CharacteristicProperty.write, CharacteristicProperty.writeWithoutResponse],
              permissions: [PeripheralAttributePermission.writeable],
            ),
            BlePeripheralCharacteristic(
              uuid: bleChatTxUuid,
              properties: [CharacteristicProperty.read, CharacteristicProperty.notify],
              permissions: [PeripheralAttributePermission.readable],
            ),
          ],
        ),
      );
      UniversalBlePeripheral.setWriteRequestHandlers((device, characteristic, offset, value) {
        if (characteristic.toLowerCase() == bleChatRxUuid && value != null) {
          _incoming.add(value);
        }
        return null; // accepted
      });
      _subs.add(
        UniversalBlePeripheral.characteristicSubscriptionStream.listen((e) {
          if (e.characteristicId.toLowerCase() == bleChatTxUuid) _linked.value = e.isSubscribed;
        }),
      );
      _serving = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> connect(String deviceId) async {
    if (kIsWeb) return false;
    try {
      await UniversalBle.connect(deviceId, timeout: const Duration(seconds: 15));
      _device = deviceId;
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Room for a whole frame in one write (iOS settles on 185 itself).
        try {
          await UniversalBle.requestMtu(deviceId, 185);
        } catch (_) {}
      }
      final services = await UniversalBle.discoverServices(deviceId);
      if (!services.any((s) => s.uuid.toLowerCase() == bleChatServiceUuid)) {
        await stop();
        return false;
      }
      _subs.add(UniversalBle.characteristicValueStream(deviceId, bleChatTxUuid).listen(_incoming.add));
      _subs.add(UniversalBle.connectionStream(deviceId).listen((up) => _linked.value = up));
      await UniversalBle.subscribeNotifications(deviceId, bleChatServiceUuid, bleChatTxUuid);
      _linked.value = true;
      return true;
    } catch (_) {
      await stop();
      return false;
    }
  }

  @override
  Future<bool> send(Uint8List frame) async {
    try {
      if (_serving) {
        await UniversalBlePeripheral.updateCharacteristicValue(characteristicId: bleChatTxUuid, value: frame);
      } else if (_device != null) {
        await UniversalBle.write(_device!, bleChatServiceUuid, bleChatRxUuid, frame);
      } else {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    _linked.value = false;
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    if (_serving) {
      _serving = false;
      try {
        UniversalBlePeripheral.setWriteRequestHandlers(null);
        await UniversalBlePeripheral.removeService(bleChatServiceUuid);
      } catch (_) {}
    }
    final d = _device;
    _device = null;
    if (d != null) {
      try {
        await UniversalBle.disconnect(d);
      } catch (_) {}
    }
  }
}

/// How often waiting messages are sent again until acknowledged.
const bleChatResendEvery = Duration(seconds: 4);

/// One ride's Bluetooth chat on this phone.
class BleChatSession {
  BleChatSession({
    required this.transport,
    required this.key,
    required this.requestId,
    required this.driver,
    required this.pending,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final BleChatTransport transport;
  final Uint8List key;
  final String requestId;

  /// This is the driver's phone (it serves; the rider's connects).
  final bool driver;

  /// This phone's messages still waiting for the server.
  final List<PendingRideMessage> Function() pending;
  final DateTime Function() _now;

  /// What arrived from the other phone, as the thread shows it.
  final received = ValueNotifier<List<RideMessage>>(const []);

  /// This phone's messages the other phone has acknowledged.
  final delivered = ValueNotifier<Set<String>>(const {});

  ValueListenable<bool> get linked => transport.linked;

  StreamSubscription<Uint8List>? _sub;
  Timer? _resend;
  bool _connecting = false;
  bool _stopped = false;

  /// Starts listening; the driver's phone starts serving.
  Future<void> start() async {
    _sub = transport.incoming.listen(_onFrame);
    if (driver) await transport.serve();
    _resend = Timer.periodic(bleChatResendEvery, (_) => unawaited(flush()));
  }

  /// The rider's phone: connect to the driver's phone, once at a time.
  Future<void> connectTo(String deviceId) async {
    if (driver || _connecting || _stopped || transport.linked.value) return;
    _connecting = true;
    try {
      if (await transport.connect(deviceId)) await flush();
    } finally {
      _connecting = false;
    }
  }

  /// Sends every waiting message the other phone hasn't acknowledged.
  Future<void> flush() async {
    if (_stopped || !transport.linked.value) return;
    for (final p in pending()) {
      if (p.requestId != requestId || delivered.value.contains(p.clientMsgId)) continue;
      if (p.type != RideMessageType.text && p.type != RideMessageType.quick) continue;
      final frame = encodeBleChatMessage(key, p.clientMsgId, p.body ?? '', p.createdAt);
      if (frame == null) continue;
      if (!await transport.send(frame)) return;
    }
  }

  void _onFrame(Uint8List bytes) {
    final f = decodeBleChatFrame(key, bytes, now: _now());
    switch (f) {
      case BleChatMessage():
        final ack = encodeBleChatAck(key, f.clientMsgId);
        if (ack != null) unawaited(transport.send(ack));
        if (received.value.any((m) => m.clientMsgId == f.clientMsgId)) return;
        received.value = [
          ...received.value,
          bleChatToMessage(
            f,
            requestId: requestId,
            senderId: bleChatPeerSenderId,
            senderRole: driver ? RideChatRole.rider : RideChatRole.partner,
          ),
        ];
      case BleChatAck():
        if (!delivered.value.contains(f.clientMsgId)) delivered.value = {...delivered.value, f.clientMsgId};
      case null:
        break;
    }
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _resend?.cancel();
    unawaited(_sub?.cancel());
    await transport.stop();
  }
}

/// Who a message that arrived over Bluetooth is from, as far as the thread
/// is concerned: never this phone's account.
const bleChatPeerSenderId = 'bluetooth-peer';

/// The live Bluetooth chat of each ride on this phone, kept by the pickup
/// badge's engine while it runs, read by the chat screen.
class BleChatSessions extends Notifier<Map<String, BleChatSession>> {
  @override
  Map<String, BleChatSession> build() => const {};

  void put(BleChatSession s) => state = {...state, s.requestId: s};

  void remove(BleChatSession s) {
    if (state[s.requestId] != s) return;
    state = {...state}..remove(s.requestId);
  }
}

final bleChatSessionsProvider = NotifierProvider<BleChatSessions, Map<String, BleChatSession>>(BleChatSessions.new);

final bleChatTransportProvider = Provider<BleChatTransport Function()>((_) => UniversalBleChatTransport.new);
