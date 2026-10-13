import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/inbox.dart';

InboxItem item(String id, {String? mode, String? kind, DateTime? at, bool read = false, Map<String, dynamic>? data}) =>
    InboxItem(
      id: id,
      title: 't$id',
      body: 'b$id',
      data: data ?? const {},
      kind: kind,
      mode: mode,
      createdAt: at ?? DateTime(2026, 10, 13, 12),
      readAt: read ? DateTime(2026, 10, 13, 13) : null,
    );

void main() {
  test('reads a row', () {
    final i = InboxItem.fromRow({
      'id': 'n1',
      'title': 'Ride confirmed',
      'body': 'Pick up at KLCC.',
      'data': {'type': 'ride_status', 'request_id': 'r1', 'role': 'rider'},
      'kind': 'ride_status',
      'mode': null,
      'created_at': '2026-10-13T04:00:00Z',
      'read_at': null,
    });
    expect(i.unread, isTrue);
    expect(i.route, '/ride/r1');
    expect(i.createdAt.isUtc, isFalse);
    expect(i.markedRead(DateTime(2026)).unread, isFalse);
  });

  test("a mode shows its own and the account's own, newest first", () {
    final items = [
      item('a', mode: 'partner', at: DateTime(2026, 10, 1)),
      item('b', mode: 'rider', at: DateTime(2026, 10, 2)),
      item('c', at: DateTime(2026, 10, 3)),
    ];
    expect(inboxFor(items, 'partner').map((i) => i.id), ['c', 'a']);
    expect(inboxFor(items, 'rider').map((i) => i.id), ['c', 'b']);
    expect(inboxFor(items, null).map((i) => i.id), ['c', 'b', 'a']);
  });

  test('the badge counts unread in the mode, capped at 99+', () {
    final items = [item('a', mode: 'partner'), item('b', mode: 'rider'), item('c', read: true), item('d')];
    expect(inboxUnread(items, 'rider'), 2);
    expect(inboxUnread(items, 'partner'), 2);
    expect(inboxBadgeText(7), '7');
    expect(inboxBadgeText(150), '99+');
  });

  test('icons by what it is about', () {
    expect(inboxIconFor(null), InboxIcon.broadcast);
    expect(inboxIconFor('ride_status'), InboxIcon.ride);
    expect(inboxIconFor('wallet_transfer_response'), InboxIcon.wallet);
    expect(inboxIconFor('vehicle_status'), InboxIcon.approval);
    expect(inboxIconFor('trip_separation'), InboxIcon.safety);
    expect(inboxIconFor('something_new'), InboxIcon.other);
  });

  test('when, in words', () {
    final now = DateTime(2026, 10, 13, 15, 0);
    expect(inboxWhen(now.subtract(const Duration(seconds: 20)), now), 'Just now');
    expect(inboxWhen(now.subtract(const Duration(minutes: 5)), now), '5 min ago');
    expect(inboxWhen(now.subtract(const Duration(hours: 3)), now), '3 h ago');
    expect(inboxWhen(DateTime(2026, 10, 12, 22), now), 'Yesterday');
    expect(inboxWhen(DateTime(2026, 10, 9), now), '4 days ago');
    expect(inboxWhen(DateTime(2026, 9, 1), now), '1 Sep');
    expect(inboxWhen(DateTime(2025, 9, 1), now), '1 Sep 2025');
  });
}
