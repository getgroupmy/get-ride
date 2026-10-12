// Chat over Bluetooth when there's no signal (reliability Phase D3):
// lib/src/core/ble_chat.dart and the session in lib/src/data/ble_chat.dart.
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ble_chat.dart';
import 'package:get_ride/src/core/ride_chat.dart';
import 'package:get_ride/src/core/ride_chat_outbox.dart';
import 'package:get_ride/src/data/ble_chat.dart';

final _key = bleChatKey('00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff')!;
final _otherKey = bleChatKey('ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100')!;
const _id1 = '11111111-2222-4333-8444-555555555555';
const _id2 = '66666666-7777-4888-9999-aaaaaaaaaaaa';
final _t0 = DateTime.utc(2026, 10, 12, 9);

/// One end of a simulated Bluetooth link between two phones.
class _End implements BleChatTransport {
  _End? other;
  final _in = StreamController<Uint8List>.broadcast();
  final _linked = ValueNotifier(false);
  final sent = <Uint8List>[];
  bool served = false;
  String? connectedTo;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  ValueListenable<bool> get linked => _linked;

  @override
  Future<bool> serve() async => served = true;

  @override
  Future<bool> connect(String deviceId) async {
    if (!(other?.served ?? false)) return false;
    connectedTo = deviceId;
    _linked.value = true;
    other!._linked.value = true;
    return true;
  }

  @override
  Future<bool> send(Uint8List frame) async {
    if (!_linked.value) return false;
    sent.add(frame);
    other!._in.add(frame);
    return true;
  }

  /// Something else in range writes [frame] to this phone.
  void inject(Uint8List frame) => _in.add(frame);

  @override
  Future<void> stop() async => _linked.value = false;
}

PendingRideMessage _pending(
  String id,
  String body, {
  String request = 'r1',
  RideMessageType type = RideMessageType.text,
}) => PendingRideMessage(
  clientMsgId: id,
  requestId: request,
  senderId: 'u1',
  role: RideChatRole.rider,
  type: type,
  body: body,
  createdAt: _t0,
);

void main() {
  group('frames', () {
    test('a message survives the trip, signed with the ride\'s key', () {
      final f = encodeBleChatMessage(_key, _id1, 'I\'m at the blue door 🚪', _t0)!;
      expect(f.length, lessThanOrEqualTo(bleChatMaxFrame));
      final back = decodeBleChatFrame(_key, f, now: _t0.add(const Duration(minutes: 1)));
      expect(back, isA<BleChatMessage>());
      back as BleChatMessage;
      expect(back.clientMsgId, _id1);
      expect(back.text, 'I\'m at the blue door 🚪');
      expect(back.sentAt, _t0);

      final ack = decodeBleChatFrame(_key, encodeBleChatAck(_key, _id1)!, now: _t0);
      expect(ack, isA<BleChatAck>().having((a) => a.clientMsgId, 'id', _id1));
    });

    test('another ride\'s key, a changed byte, an old message or noise is refused', () {
      final f = encodeBleChatMessage(_key, _id1, 'hello', _t0)!;
      expect(decodeBleChatFrame(_otherKey, f, now: _t0), isNull, reason: 'someone else in range');
      final tampered = Uint8List.fromList(f)..[20] ^= 0x01;
      expect(decodeBleChatFrame(_key, tampered, now: _t0), isNull, reason: 'changed on the way');
      expect(
        decodeBleChatFrame(_key, f, now: _t0.add(const Duration(hours: 1))),
        isNull,
        reason: 'replayed an hour on',
      );
      expect(decodeBleChatFrame(_key, [1, 2, 3], now: _t0), isNull);
    });

    test('only short text fits one frame', () {
      expect(bleChatFits('On my way'), isTrue);
      expect(bleChatFits(''), isFalse);
      expect(bleChatFits('a' * bleChatMaxTextBytes), isTrue);
      expect(bleChatFits('a' * (bleChatMaxTextBytes + 1)), isFalse);
      expect(bleChatFits('é' * (bleChatMaxTextBytes ~/ 2 + 1)), isFalse, reason: 'counted in UTF-8 bytes');
      expect(encodeBleChatMessage(_key, _id1, 'a' * 200, _t0), isNull);
      expect(encodeBleChatMessage(_key, 'not-a-uuid', 'hi', _t0), isNull);
      expect(bleChatKey('short'), isNull);
    });

    test('the thread shows a Bluetooth message until the server has it', () {
      final ble = bleChatToMessage(
        BleChatMessage(_id1, text: 'At the gate', sentAt: _t0),
        requestId: 'r1',
        senderId: bleChatPeerSenderId,
        senderRole: RideChatRole.partner,
      );
      expect(ble.viaBluetooth, isTrue);
      final early = RideMessage(
        id: 'm0',
        requestId: 'r1',
        senderId: 'u1',
        senderRole: RideChatRole.rider,
        createdAt: _t0.subtract(const Duration(minutes: 1)),
      );
      final shown = withBluetoothMessages([early], [ble]);
      expect(shown.map((m) => m.id), ['m0', 'ble-$_id1']);

      final serverCopy = RideMessage(
        id: 'srv',
        requestId: 'r1',
        senderId: 'd1',
        senderRole: RideChatRole.partner,
        clientMsgId: _id1,
        createdAt: _t0,
      );
      expect(withBluetoothMessages([early, serverCopy], [ble]).map((m) => m.id), [
        'm0',
        'srv',
      ], reason: 'the server copy replaces it');
    });
  });

  group('the session', () {
    late _End driverEnd, riderEnd;
    late List<PendingRideMessage> riderQueue;

    setUp(() {
      driverEnd = _End();
      riderEnd = _End();
      driverEnd.other = riderEnd;
      riderEnd.other = driverEnd;
      riderQueue = [];
    });

    BleChatSession session(_End end, {required bool driver, List<PendingRideMessage> Function()? pending}) =>
        BleChatSession(
          transport: end,
          key: _key,
          requestId: 'r1',
          driver: driver,
          pending: pending ?? () => const [],
          now: () => _t0,
        );

    test('the rider\'s waiting message reaches the driver\'s phone and comes back acknowledged', () {
      fakeAsync((async) {
        final driver = session(driverEnd, driver: true);
        final rider = session(riderEnd, driver: false, pending: () => riderQueue);
        driver.start();
        rider.start();
        async.flushMicrotasks();
        expect(driverEnd.served, isTrue);

        riderQueue.add(_pending(_id1, 'Blue shirt, by the pillar'));
        riderQueue.add(_pending(_id2, 'a pin', type: RideMessageType.location));
        riderQueue.add(_pending('77777777-7777-4777-8777-777777777777', 'other ride', request: 'r2'));
        rider.connectTo('driver-phone');
        async.elapse(const Duration(seconds: 1));

        expect(riderEnd.connectedTo, 'driver-phone');
        expect(driver.received.value.map((m) => m.body), [
          'Blue shirt, by the pillar',
        ], reason: 'only this ride\'s text goes across');
        expect(driver.received.value.single.senderRole, RideChatRole.rider);
        expect(driver.received.value.single.senderId, bleChatPeerSenderId);
        expect(rider.delivered.value, {_id1});

        // Sent again on the next round until the server has it: shown once.
        async.elapse(bleChatResendEvery * 2);
        expect(driver.received.value, hasLength(1));
        expect(rider.delivered.value, {_id1});

        driver.stop();
        rider.stop();
        async.flushMicrotasks();
      });
    });

    test('nothing goes before the link is up, and a stranger\'s frame is ignored', () {
      fakeAsync((async) {
        final rider = session(riderEnd, driver: false, pending: () => [_pending(_id1, 'hello')]);
        rider.start();
        async.elapse(bleChatResendEvery * 2);
        expect(riderEnd.sent, isEmpty);

        final driver = session(driverEnd, driver: true);
        driver.start();
        async.flushMicrotasks();
        driverEnd.inject(encodeBleChatMessage(_otherKey, _id2, 'let me in', _t0)!);
        async.flushMicrotasks();
        expect(driver.received.value, isEmpty);

        driver.stop();
        rider.stop();
        async.flushMicrotasks();
      });
    });

    test('the driver\'s waiting message reaches the rider over the same link', () {
      fakeAsync((async) {
        final driverQueue = [
          PendingRideMessage(
            clientMsgId: _id2,
            requestId: 'r1',
            senderId: 'd1',
            role: RideChatRole.partner,
            type: RideMessageType.quick,
            body: 'I\'ve arrived',
            createdAt: _t0,
          ),
        ];
        final driver = session(driverEnd, driver: true, pending: () => driverQueue);
        final rider = session(riderEnd, driver: false);
        driver.start();
        rider.start();
        async.flushMicrotasks();
        rider.connectTo('driver-phone');
        async.elapse(bleChatResendEvery);
        expect(rider.received.value.single.body, 'I\'ve arrived');
        expect(rider.received.value.single.senderRole, RideChatRole.partner);
        expect(driver.delivered.value, {_id2});
        expect(utf8.decode([...driverEnd.sent.first.skip(21).take(10)]), 'I\'ve arriv');

        driver.stop();
        rider.stop();
        async.flushMicrotasks();
      });
    });
  });
}
