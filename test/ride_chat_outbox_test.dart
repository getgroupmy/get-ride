// Chat messages kept on the phone until there is a connection
// (lib/src/core/ride_chat_outbox.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_chat.dart';
import 'package:get_ride/src/core/ride_chat_outbox.dart';

PendingRideMessage pending(
  String id, {
  String request = 'r1',
  DateTime? at,
  RideMessageType type = RideMessageType.text,
}) => PendingRideMessage(
  clientMsgId: id,
  requestId: request,
  senderId: 'u1',
  role: RideChatRole.rider,
  type: type,
  body: type == RideMessageType.location ? null : 'At the gate',
  latitude: type == RideMessageType.location ? 3.1 : null,
  longitude: type == RideMessageType.location ? 101.6 : null,
  createdAt: at ?? DateTime(2026, 10, 11, 8),
);

void main() {
  test('the row carries the id it will be stored under, and nothing the server stamps', () {
    final row = pending('c1').toRow();
    expect(row, {
      'request_id': 'r1',
      'sender_role': 'rider',
      'type': 'text',
      'client_msg_id': 'c1',
      'body': 'At the gate',
    });
    expect(pending('c2', type: RideMessageType.location).toRow(), containsPair('latitude', 3.1));
  });

  test('a queued message survives being stored and read back', () {
    final back = PendingRideMessage.fromJson(pending('c1').toJson())!;
    expect(back.clientMsgId, 'c1');
    expect(back.role, RideChatRole.rider);
    expect(back.body, 'At the gate');
    expect(back.createdAt, DateTime(2026, 10, 11, 8));
    expect(PendingRideMessage.fromJson({'client_msg_id': 'x'}), isNull, reason: 'a broken entry is skipped');
    expect(PendingRideMessage.fromJson('nonsense'), isNull);
    expect(
      PendingRideMessage.fromJson({...pending('c3').toJson(), 'type': 'image'}),
      isNull,
      reason: 'a photo is never queued: it needs its upload first',
    );
  });

  test('it shows in the thread as waiting, mine, until the server has it', () {
    final m = pending('c1').toMessage();
    expect(m.pending, isTrue);
    expect(m.senderId, 'u1');
    expect(m.clientMsgId, 'c1');

    const onServer = RideMessage(
      id: 'm1',
      requestId: 'r1',
      senderId: 'u1',
      senderRole: RideChatRole.rider,
      clientMsgId: 'c1',
    );
    final list = withPendingMessages([onServer], [pending('c1'), pending('c2'), pending('c3', request: 'r2')], 'r1');
    expect(list.map((m) => m.id), ['m1', 'pending-c2'], reason: 'already sent, and another ride\'s, are left out');
  });

  test('the queue drops what the server has and what is too old to send', () {
    final now = DateTime(2026, 10, 11, 8, 20);
    final kept = prunePending(
      [pending('c1'), pending('c2'), pending('old', at: now.subtract(const Duration(minutes: 31)))],
      onServer: {'c1'},
      now: now,
    );
    expect(kept.map((p) => p.clientMsgId), ['c2']);
  });
}
