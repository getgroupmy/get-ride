// A call's own row and its WebRTC setup are read again every few seconds
// even while realtime is up; the app-wide incoming-ring watchers only every
// few minutes (PERF-70).
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/realtime_backup.dart';
import 'package:get_ride/src/data/realtime_hub.dart';
import 'package:get_ride/src/data/ride_call_repository.dart';
import 'package:get_ride/src/data/support_call_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final reads = <String, int>{};
  final statuses = <RealtimeStatusCallback>[];
  final db = SupabaseClient(
    'http://localhost',
    'anon',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((r) async {
      final table = r.url.pathSegments.last;
      reads[table] = (reads[table] ?? 0) + 1;
      return http.Response('[]', 200, headers: {'content-type': 'application/json'});
    }),
  );
  RealtimeHub.debugUse(
    db,
    RealtimeHub((name, table, event, filter, onChange, onStatus) {
      statuses.add(onStatus);
      return name;
    }, (_) {}),
  );
  final rides = RideCallRepository(db);
  final support = SupportCallRepository(db);

  /// Reads of [table] by [stream] over [span] while its channel is open.
  int readsWhileOpen(Stream<Object?> Function() stream, String table, Duration span) {
    var n = 0;
    fakeAsync((clock) {
      statuses.clear();
      final sub = stream().listen((_) {});
      clock.flushMicrotasks();
      for (final s in statuses) {
        s(RealtimeSubscribeStatus.subscribed);
      }
      clock.elapse(const Duration(milliseconds: 1));
      final before = reads[table] ?? 0;
      clock.elapse(span);
      n = (reads[table] ?? 0) - before;
      unawaited(sub.cancel());
      clock.flushMicrotasks();
    });
    return n;
  }

  test('the in-call interval is a few seconds, the ring watchers keep the slow one', () {
    expect(callRowsInCallHealthyInterval, lessThanOrEqualTo(const Duration(seconds: 5)));
    expect(realtimeBackupSlowHealthyInterval, greaterThanOrEqualTo(const Duration(minutes: 5)));
  });

  const minute = Duration(minutes: 1);
  final perMinute = minute.inSeconds ~/ callRowsInCallHealthyInterval.inSeconds;

  test("a call's own row and signals are read again every few seconds while realtime is up", () {
    expect(readsWhileOpen(() => rides.watch('k1'), 'ride_calls', minute), perMinute);
    expect(readsWhileOpen(() => rides.watchSignals('k1'), 'ride_call_signals', minute), perMinute);
    expect(readsWhileOpen(() => support.watch('c1'), 'support_calls', minute), perMinute);
    expect(readsWhileOpen(() => support.watchSignals('c1'), 'support_call_signals', minute), perMinute);
  });

  test('the incoming-ring watchers read only on the slow safety net while realtime is up', () {
    final slow = realtimeBackupSlowHealthyInterval - const Duration(seconds: 1);
    expect(readsWhileOpen(() => rides.watchIncoming('u1'), 'ride_calls', slow), 0);
    expect(readsWhileOpen(() => support.watchIncomingForUser('u1'), 'support_calls', slow), 0);
    expect(readsWhileOpen(support.watchIncomingForAgents, 'support_calls', slow), 0);
    expect(readsWhileOpen(() => rides.watchIncoming('u1'), 'ride_calls', realtimeBackupSlowHealthyInterval), 1);
  });

  test('watchCallRows keeps the slow interval unless told otherwise', () {
    final filter = PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: 'x');
    var calls = 0;
    Future<List<Map<String, dynamic>>> counted() async {
      calls++;
      return const [];
    }

    int over(Duration span, {Duration? healthy, bool given = false}) {
      calls = 0;
      readsWhileOpen(
        () => given
            ? watchCallRows(db, 'n', 't', filter, initial: counted, healthy: healthy)
            : watchCallRows(db, 'n', 't', filter, initial: counted),
        't',
        span,
      );
      return calls;
    }

    // [calls] also counts the two reads before the window: the first one
    // and the one as the channel opens.
    expect(over(const Duration(minutes: 4)), 2);
    expect(over(minute, healthy: const Duration(seconds: 3), given: true), 2 + 20);
    expect(over(const Duration(hours: 1), healthy: null, given: true), 2);
  });
}
