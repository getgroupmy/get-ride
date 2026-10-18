import 'dart:math' show Random;

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

  test('healthy null: no period while open', () {
    expect(realtimeBackupPeriod(every: const Duration(minutes: 2), healthy: null, connected: true), isNull);
    expect(
      realtimeBackupPeriod(every: const Duration(minutes: 2), healthy: null, connected: false),
      const Duration(minutes: 2),
    );
  });

  test('healthy null, resumeWhileOpen false: reads only while down or as the channel reopens', () {
    fakeAsync((clock) {
      var reads = 0;
      final backup = RealtimeBackup(
        () => reads++,
        every: const Duration(minutes: 2),
        healthy: null,
        onOpen: false,
        resumeWhileOpen: false,
      );
      // Down at start: resuming reads.
      backup.resumed();
      clock.flushMicrotasks();
      expect(reads, 1);

      backup.onStatus(RealtimeSubscribeStatus.subscribed);
      clock.flushMicrotasks();
      expect(reads, 1);
      // Open: nothing on the timer, nothing on resume.
      clock.elapse(const Duration(hours: 1));
      backup.resumed();
      clock.flushMicrotasks();
      expect(reads, 1);
      expect(backup.period, isNull);

      // Drops: a read, then the 2-minute pace while down.
      backup.onStatus(RealtimeSubscribeStatus.closed);
      clock.flushMicrotasks();
      expect(reads, 2);
      clock.elapse(const Duration(minutes: 2));
      expect(reads, 3);
      backup.resumed();
      clock.flushMicrotasks();
      expect(reads, 4);

      // Reopens: a read, then quiet again.
      backup.onStatus(RealtimeSubscribeStatus.subscribed);
      clock.flushMicrotasks();
      expect(reads, 5);
      clock.elapse(const Duration(hours: 1));
      expect(reads, 5);
      backup.dispose();
    });
  });

  test('resumeWhileOpen false still reads on resume when a drop was not read yet', () {
    fakeAsync((clock) {
      var reads = 0;
      final backup = RealtimeBackup(() => reads++, healthy: null, resumeWhileOpen: false);
      backup.onStatus(RealtimeSubscribeStatus.subscribed);
      clock.flushMicrotasks();
      expect(reads, 1);
      // Drop and reopen inside the cooldown: neither reads.
      backup.onStatus(RealtimeSubscribeStatus.closed);
      backup.onStatus(RealtimeSubscribeStatus.subscribed);
      clock.flushMicrotasks();
      expect(reads, 1);
      backup.resumed();
      clock.flushMicrotasks();
      expect(reads, 2);
      backup.resumed();
      clock.flushMicrotasks();
      expect(reads, 2);
      backup.dispose();
    });
  });

  test('the slow tier reads every five minutes while open', () {
    fakeAsync((clock) {
      var reads = 0;
      final backup = RealtimeBackup(() => reads++, healthy: realtimeBackupSlowHealthyInterval);
      backup.onStatus(RealtimeSubscribeStatus.subscribed);
      clock.flushMicrotasks();
      expect(reads, 1);
      clock.elapse(const Duration(minutes: 4, seconds: 59));
      expect(reads, 1);
      clock.elapse(const Duration(seconds: 1));
      expect(reads, 2);
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

  test('down delay: steady at first, then doubling up to the cap', () {
    const every = Duration(seconds: 5);
    final delays = [for (var n = 0; n < 9; n++) realtimeBackupDownDelay(every: every, downReads: n).inSeconds];
    expect(delays, [5, 5, 5, 10, 20, 40, 80, 120, 120]);
    // A slow backup may wait up to four times its own interval.
    expect(
      realtimeBackupDownDelay(every: const Duration(minutes: 2), downReads: 20),
      const Duration(minutes: 8),
    );
    expect(realtimeBackupDownDelay(every: every, downReads: 1000), realtimeBackupMaxDownInterval);
  });

  test('a channel that stays down is read less and less often, and fast again once it opens', () {
    fakeAsync((clock) {
      var reads = 0;
      final backup = RealtimeBackup(() => reads++);
      // 5, 10, 15, then 25, 45, 85, 165, 285 s.
      clock.elapse(const Duration(seconds: 285));
      expect(reads, 8);
      // Ten more minutes down: at most one read every two minutes.
      clock.elapse(const Duration(minutes: 10));
      expect(reads, 13);

      // It opens: one read, the healthy pace, and the back-off forgotten.
      backup.onStatus(RealtimeSubscribeStatus.subscribed);
      clock.flushMicrotasks();
      expect(reads, 14);
      backup.onStatus(RealtimeSubscribeStatus.channelError);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 15));
      // The read as it opened stands in for the drop right after it; then
      // every 5 s again, not the backed-off pace.
      expect(reads, 17);
      backup.dispose();
    });
  });

  test('a channel flapping open and shut reads at most once per interval for it', () {
    fakeAsync((clock) {
      var reads = 0;
      final backup = RealtimeBackup(() => reads++);
      for (var i = 0; i < 10; i++) {
        backup.onStatus(RealtimeSubscribeStatus.subscribed);
        backup.onStatus(RealtimeSubscribeStatus.channelError);
        clock.elapse(const Duration(milliseconds: 200));
      }
      expect(reads, 1);
      backup.dispose();
    });
  });

  test('jitter moves a wait by up to the fraction either way', () {
    const base = Duration(minutes: 20);
    expect(realtimeBackupJittered(base, fraction: 0.2, unit: 0), const Duration(minutes: 16));
    expect(realtimeBackupJittered(base, fraction: 0.2, unit: 0.5), base);
    expect(realtimeBackupJittered(base, fraction: 0.2, unit: 1), const Duration(minutes: 24));
    expect(realtimeBackupJittered(base, fraction: 0, unit: 0), base);
  });

  test('safety net: slow jittered reads while healthy, the fast pace only while down', () {
    fakeAsync((clock) {
      var reads = 0;
      final backup = RealtimeBackup(
        () => reads++,
        every: const Duration(minutes: 2),
        healthy: realtimeBackupSafetyNetInterval,
        healthyJitter: realtimeBackupSafetyNetJitter,
        onOpen: false,
        resumeWhileOpen: false,
        random: Random(7),
      );
      backup.onStatus(RealtimeSubscribeStatus.subscribed);
      clock.flushMicrotasks();
      expect(reads, 0);
      // Never sooner than 16 minutes, always by 24.
      clock.elapse(const Duration(minutes: 16) - const Duration(seconds: 1));
      expect(reads, 0);
      clock.elapse(const Duration(minutes: 8) + const Duration(seconds: 1));
      expect(reads, 1);
      // A few hours healthy: about three reads an hour, never more than one
      // per 16 minutes nor fewer than one per 24.
      clock.elapse(const Duration(hours: 4));
      expect(reads, inInclusiveRange(1 + 10, 1 + 15));

      // Drops: a read at once, then every 2 minutes while down.
      final before = reads;
      backup.onStatus(RealtimeSubscribeStatus.channelError);
      clock.flushMicrotasks();
      expect(reads, before + 1);
      clock.elapse(const Duration(minutes: 6));
      expect(reads, before + 4);

      // Reopens: a read, then back to the safety net.
      backup.onStatus(RealtimeSubscribeStatus.subscribed);
      clock.flushMicrotasks();
      expect(reads, before + 5);
      clock.elapse(const Duration(minutes: 15));
      expect(reads, before + 5);
      backup.dispose();
      clock.elapse(const Duration(hours: 1));
      expect(reads, before + 5);
    });
  });

  test('phones started together spread their safety-net reads', () {
    final waits = <Duration>{};
    for (var seed = 0; seed < 20; seed++) {
      fakeAsync((clock) {
        Duration? first;
        final backup = RealtimeBackup(
          () => first ??= clock.elapsed,
          every: const Duration(minutes: 2),
          healthy: realtimeBackupSafetyNetInterval,
          healthyJitter: realtimeBackupSafetyNetJitter,
          onOpen: false,
          random: Random(seed),
        );
        backup.onStatus(RealtimeSubscribeStatus.subscribed);
        clock.elapse(const Duration(minutes: 25));
        expect(first, isNotNull);
        expect(first!, greaterThanOrEqualTo(const Duration(minutes: 16)));
        expect(first!, lessThanOrEqualTo(const Duration(minutes: 24)));
        waits.add(first!);
        backup.dispose();
      });
    }
    expect(waits.length, greaterThan(10));
  });
}
