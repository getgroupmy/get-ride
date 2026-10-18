// Streams on the same rows share one realtime channel (PERF-52).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/realtime_hub.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Channel {
  _Channel(this.table, this.filter, this.onChange, this.onStatus);
  final String table;
  final PostgresChangeFilter? filter;
  final void Function(PostgresChangePayload) onChange;
  final RealtimeStatusCallback onStatus;
  bool closed = false;
}

PostgresChangePayload _payload(Map<String, dynamic> row) => PostgresChangePayload(
  schema: 'public',
  table: 'ride_requests',
  commitTimestamp: DateTime(2026),
  eventType: PostgresChangeEvent.update,
  newRecord: row,
  oldRecord: const {},
  errors: null,
);

PostgresChangeFilter _id(String id) => PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: id);

void main() {
  late List<_Channel> opened;
  late RealtimeHub hub;

  setUp(() {
    opened = [];
    hub = RealtimeHub(
      (name, table, event, filter, onChange, onStatus) {
        final c = _Channel(table, filter, onChange, onStatus);
        opened.add(c);
        return c;
      },
      (c) => (c as _Channel).closed = true,
    );
  });

  test('followers of the same rows share a channel, which closes with the last of them', () {
    final a = <Object?>[], b = <Object?>[];
    final la = hub.listen(table: 'ride_requests', filter: _id('r1'), onChange: (p) => a.add(p.newRecord['n']));
    final lb = hub.listen(table: 'ride_requests', filter: _id('r1'), onChange: (p) => b.add(p.newRecord['n']));
    expect(opened, hasLength(1));
    expect(hub.openChannels, 1);

    opened.single.onChange(_payload({'n': 1}));
    expect(a, [1]);
    expect(b, [1]);

    la.cancel();
    la.cancel();
    expect(opened.single.closed, isFalse, reason: 'one follower is left');
    opened.single.onChange(_payload({'n': 2}));
    expect(a, [1]);
    expect(b, [1, 2]);

    lb.cancel();
    expect(opened.single.closed, isTrue);
    expect(hub.openChannels, 0);

    // Followed again: a new channel.
    hub.listen(table: 'ride_requests', filter: _id('r1'), onChange: (_) {});
    expect(opened, hasLength(2));
  });

  test('another filter, event or table is another channel', () {
    hub.listen(table: 'ride_requests', filter: _id('r1'), onChange: (_) {});
    hub.listen(table: 'ride_requests', filter: _id('r2'), onChange: (_) {});
    hub.listen(table: 'ride_requests', onChange: (_) {});
    hub.listen(table: 'ride_requests', event: PostgresChangeEvent.update, filter: _id('r1'), onChange: (_) {});
    hub.listen(table: 'ride_messages', filter: _id('r1'), onChange: (_) {});
    expect(hub.openChannels, 5);
    expect(
      realtimeKey('ride_requests', PostgresChangeEvent.update, _id('r1')),
      isNot(realtimeKey('ride_requests', PostgresChangeEvent.all, _id('r1'))),
    );
  });

  test('a follower joining an open channel hears its state at once, and every change of it after', () {
    final first = <RealtimeSubscribeStatus>[], second = <RealtimeSubscribeStatus>[];
    hub.listen(table: 't', onChange: (_) {}, onStatus: (s, [_]) => first.add(s));
    opened.single.onStatus(RealtimeSubscribeStatus.subscribed);
    hub.listen(table: 't', onChange: (_) {}, onStatus: (s, [_]) => second.add(s));
    expect(second, [RealtimeSubscribeStatus.subscribed]);
    opened.single.onStatus(RealtimeSubscribeStatus.channelError);
    expect(first, [RealtimeSubscribeStatus.subscribed, RealtimeSubscribeStatus.channelError]);
    expect(second, [RealtimeSubscribeStatus.subscribed, RealtimeSubscribeStatus.channelError]);
  });

  test('a follower that throws does not stop the others', () {
    final got = <Object?>[];
    hub.listen(table: 't', onChange: (_) => throw StateError('x'));
    hub.listen(table: 't', onChange: (p) => got.add(p.newRecord['n']));
    opened.single.onChange(_payload({'n': 7}));
    expect(got, [7]);
  });

  test('the repositories follow their rows through the hub, not channels of their own', () {
    for (final f in [
      'lib/src/data/ride_repository.dart',
      'lib/src/data/ride_chat_repository.dart',
      'lib/src/data/notifications_repository.dart',
      'lib/src/data/coin_transfer_repository.dart',
      'lib/src/data/support_call_repository.dart',
      'lib/src/data/branding_cache.dart',
    ]) {
      final src = File(f).readAsStringSync();
      expect(src, isNot(contains('.channel(')), reason: f);
    }
  });
}
