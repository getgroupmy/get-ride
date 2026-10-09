// The rider ↔ driver chat's rules (lib/src/core/ride_chat.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/core/ride_chat.dart';
import 'package:get_ride/src/data/models.dart';

RideMessage msg(
  String id,
  String from, {
  RideMessageStatus status = RideMessageStatus.sent,
  DateTime? at,
  RideChatRole role = RideChatRole.rider,
}) => RideMessage(id: id, requestId: 'r1', senderId: from, senderRole: role, body: id, status: status, createdAt: at);

void main() {
  test('a row reads back, and a row that is not a message is dropped', () {
    final m = RideMessage.fromRow({
      'id': 'm1',
      'request_id': 'r1',
      'sender_id': 'u1',
      'sender_role': 'partner',
      'type': 'location',
      'latitude': 3,
      'longitude': 101.5,
      'status': 'delivered',
      'created_at': '2026-10-09T08:00:00Z',
    })!;
    expect(m.senderRole, RideChatRole.partner);
    expect(m.type, RideMessageType.location);
    expect(m.latitude, 3.0);
    expect(m.hasLocation, isTrue);
    expect(m.status, RideMessageStatus.delivered);
    expect(m.summary, 'Shared a location');
    expect(m.createdAt, DateTime.utc(2026, 10, 9, 8));
    expect(RideMessage.fromRow({'id': 'm2', 'sender_role': 'admin'}), isNull);
    expect(RideMessage.fromRow({'sender_role': 'rider'}), isNull);
    final odd = RideMessage.fromRow({'id': 'm3', 'sender_role': 'rider', 'type': '??', 'status': '??'})!;
    expect(odd.type, RideMessageType.text);
    expect(odd.status, RideMessageStatus.sent);
  });

  test('who is who on a ride', () {
    final r = RideRequest({'id': 'r1', 'rider_id': 'a', 'partner_id': 'b', 'status': 'accepted'});
    expect(rideChatRoleFor(r, 'a'), RideChatRole.rider);
    expect(rideChatRoleFor(r, 'b'), RideChatRole.partner);
    expect(rideChatRoleFor(r, 'c'), isNull);
    expect(rideChatRoleFor(r, null), isNull);
  });

  test('each side gets its own quick replies', () {
    expect(rideQuickReplies(RideChatRole.rider), [
      "I'm at the pickup point",
      'Running 2 minutes late',
      'Please call me',
      'OK',
    ]);
    expect(rideQuickReplies(RideChatRole.partner), [
      "I've arrived",
      "I'm on my way",
      'Stuck in traffic, 5 minutes',
      'OK',
    ]);
  });

  test('the chat takes messages only while a driver is on the job', () {
    expect(RideStatus.values.where(rideChatOpen), [RideStatus.accepted, RideStatus.arrived, RideStatus.onTrip]);
    expect(rideChatAvailable(RideRequest({'id': 'r', 'status': 'open'})), isFalse);
    expect(rideChatAvailable(RideRequest({'id': 'r', 'status': 'accepted', 'partner_id': 'b'})), isTrue);
    expect(rideChatAvailable(RideRequest({'id': 'r', 'status': 'completed', 'partner_id': 'b'})), isTrue);
    expect(rideChatAvailable(RideRequest({'id': 'r', 'status': 'expired'})), isFalse);
  });

  test('what is sent is trimmed, and nothing empty or too long', () {
    expect(rideMessageText('  On my way  '), 'On my way');
    expect(rideMessageText('   '), isNull);
    expect(rideMessageText('x' * rideMessageMaxLength), hasLength(rideMessageMaxLength));
    expect(rideMessageText('x' * (rideMessageMaxLength + 1)), isNull);
  });

  test('ticks, unread and what to mark', () {
    final list = [
      msg('a', 'me', status: RideMessageStatus.read),
      msg('b', 'them'),
      msg('c', 'them', status: RideMessageStatus.delivered),
      msg('d', 'them', status: RideMessageStatus.read),
    ];
    expect(rideMessageTick(list[0], 'me'), RideMessageStatus.read);
    expect(rideMessageTick(list[1], 'me'), isNull, reason: 'their messages carry no tick for me');
    expect(rideUnreadCount(list, 'me'), 2);
    expect(rideUnreadCount(list, null), 0);
    expect(rideMessagesToDeliver(list, 'me'), ['b']);
    expect(rideMessagesToRead(list, 'me'), ['b', 'c']);
    expect(rideMessagesToRead(list, 'them'), isEmpty, reason: 'my own messages are not theirs to read');

    final after = withRideMessageStatus(list, {'a', 'b', 'c'}, RideMessageStatus.delivered);
    expect(after.map((m) => m.status), [
      RideMessageStatus.read, // never lowered
      RideMessageStatus.delivered,
      RideMessageStatus.delivered,
      RideMessageStatus.read,
    ]);
  });

  test('day headings', () {
    final now = DateTime(2026, 10, 9, 15);
    expect(rideChatDayLabel(DateTime(2026, 10, 9, 0, 5), now), 'Today');
    expect(rideChatDayLabel(DateTime(2026, 10, 8, 23), now), 'Yesterday');
    expect(rideChatDayLabel(DateTime(2026, 10, 6), now), 'Tuesday');
    expect(rideChatDayLabel(DateTime(2026, 9, 1), now), '1 Sep');
    expect(rideChatDayLabel(DateTime(2025, 12, 31), now), '31 Dec 2025');
  });

  test('the thread is oldest first with a heading before each day', () {
    final now = DateTime(2026, 10, 9, 15);
    final items = rideChatItems([
      msg('c', 'me', at: DateTime(2026, 10, 9, 9)),
      msg('a', 'me', at: DateTime(2026, 10, 8, 22)),
      msg('b', 'them', at: DateTime(2026, 10, 8, 23)),
    ], now);
    expect(
      items.map(
        (i) => switch (i) {
          RideChatDay(:final label) => '# $label',
          RideChatEntry(:final message) => message.id,
        },
      ),
      ['# Yesterday', 'a', 'b', '# Today', 'c'],
    );
    expect(rideChatItems(const [], now), isEmpty);
  });

  test('a shared location opens the maps at that point', () {
    expect(
      rideLocationUri(3.1579, 101.7116).toString(),
      'https://www.google.com/maps/search/?api=1&query=3.157900,101.711600',
    );
  });

  test('a chat push opens the chat over the recipient\'s own trip screen', () {
    expect(pushRouteFor({'type': 'ride_message', 'request_id': 'r1', 'role': 'rider'}), '/ride/r1/chat');
    expect(pushRouteFor({'type': 'ride_message', 'request_id': 'r1', 'role': 'partner'}), '/drive/trip/r1/chat');
    expect(pushRouteFor({'type': 'ride_message', 'request_id': 'r1'}), '/ride/r1/chat');
    expect(pushRouteFor({'type': 'ride_message'}), isNull);
  });
}
