import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/realtime_backup.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

void main() {
  test('the period is the fast one while down, the slow one while connected', () {
    const fast = Duration(seconds: 5), slow = Duration(seconds: 30);
    expect(realtimeBackupPeriod(every: fast, healthy: slow, connected: false), fast);
    expect(realtimeBackupPeriod(every: fast, healthy: slow, connected: true), slow);
    // A healthy interval faster than the down one never speeds it up.
    expect(
      realtimeBackupPeriod(every: const Duration(minutes: 2), healthy: slow, connected: true),
      const Duration(minutes: 2),
    );
  });

  test('polls fast until the channel opens, slowly while open, fast again once it drops', () {
    fakeAsync((clock) {
      var reads = 0;
      final backup = RealtimeBackup(() => reads++);

      // Not open yet: every 5 s.
      clock.elapse(const Duration(seconds: 15));
      expect(reads, 3);

      // Opens: one read for whatever changed meanwhile, then every 30 s.
      backup.onStatus(RealtimeSubscribeStatus.subscribed);
      clock.flushMicrotasks();
      expect(reads, 4);
      clock.elapse(const Duration(seconds: 29));
      expect(reads, 4);
      clock.elapse(const Duration(seconds: 1));
      expect(reads, 5);
      clock.elapse(const Duration(seconds: 60));
      expect(reads, 7);

      // Drops: a read at once, then every 5 s again.
      backup.onStatus(RealtimeSubscribeStatus.channelError);
      clock.flushMicrotasks();
      expect(reads, 8);
      clock.elapse(const Duration(seconds: 10));
      expect(reads, 10);

      // Reopens: a read, then slow again.
      backup.onStatus(RealtimeSubscribeStatus.subscribed);
      clock.flushMicrotasks();
      expect(reads, 11);
      clock.elapse(const Duration(seconds: 20));
      expect(reads, 11);

      backup.dispose();
      clock.elapse(const Duration(minutes: 5));
      expect(reads, 11);
    });
  });

  test('onOpen: false skips only the first open, and a custom healthy interval applies', () {
    fakeAsync((clock) {
      var reads = 0;
      final backup = RealtimeBackup(
        () => reads++,
        every: const Duration(seconds: 3),
        healthy: const Duration(seconds: 15),
        onOpen: false,
      );
      backup.onStatus(RealtimeSubscribeStatus.subscribed);
      clock.flushMicrotasks();
      expect(reads, 0);
      clock.elapse(const Duration(seconds: 15));
      expect(reads, 1);

      backup.onStatus(RealtimeSubscribeStatus.timedOut);
      clock.flushMicrotasks();
      expect(reads, 2);
      clock.elapse(const Duration(seconds: 3));
      expect(reads, 3);

      // The reopened channel still reads.
      backup.onStatus(RealtimeSubscribeStatus.subscribed);
      clock.flushMicrotasks();
      expect(reads, 4);
      backup.dispose();
    });
  });

  test('a status repeated while already down does not read again', () {
    fakeAsync((clock) {
      var reads = 0;
      final backup = RealtimeBackup(() => reads++);
      backup.onStatus(RealtimeSubscribeStatus.closed);
      backup.onStatus(RealtimeSubscribeStatus.channelError);
      clock.flushMicrotasks();
      expect(reads, 0);
      expect(backup.period, realtimeBackupInterval);
      backup.dispose();
    });
  });
}
