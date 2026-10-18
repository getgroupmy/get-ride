import 'dart:async';
import 'dart:math' show Random;

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

/// How often a live screen reads its rows again on its own while its
/// realtime channel is down (not yet open, errored, timed out or closed).
const realtimeBackupInterval = Duration(seconds: 5);

/// How often it reads them again while the channel is open and delivering:
/// only a safety net for an update realtime dropped, so it can be slow.
/// Every open stream used to re-read every few seconds regardless, which
/// with two phones online was thousands of API requests an hour.
const realtimeBackupHealthyInterval = Duration(seconds: 30);

/// The healthy interval for watchers that stay open app-wide (incoming
/// calls, the inbox, transfers): open on every phone all day, so while
/// realtime delivers they only check every few minutes.
const realtimeBackupSlowHealthyInterval = Duration(minutes: 5);

/// The safety net for the app-wide live tables while their channel reports
/// healthy: Supabase Realtime can stay "subscribed" while silently missing
/// changes, so even then everything is read again this often -- jittered by
/// [realtimeBackupSafetyNetJitter] so phones started together do not all
/// read at the same moment.
const realtimeBackupSafetyNetInterval = Duration(minutes: 20);

/// How far each healthy wait may move from [RealtimeBackup.healthy] either
/// way, as a fraction of it, for backups given a jitter.
const realtimeBackupSafetyNetJitter = 0.2;

/// [base] moved by up to [fraction] of itself either way: [unit] 0 is the
/// shortest wait, 0.5 [base] itself, 1 the longest. Pure.
Duration realtimeBackupJittered(Duration base, {required double fraction, required double unit}) {
  if (fraction <= 0) return base;
  final scale = 1 + fraction * (2 * unit.clamp(0.0, 1.0) - 1);
  return Duration(microseconds: (base.inMicroseconds * scale).round());
}

/// While the channel stays down, the reads that keep to [every] before the
/// wait starts doubling: a channel still opening costs nothing extra, one
/// that stays down (a struggling database, no realtime at all) stops being
/// read every few seconds by every screen on every phone -- which is what
/// turned a slow database into an outage.
const realtimeBackupSteadyDownReads = 3;

/// The longest wait between reads while the channel stays down; a slower
/// [RealtimeBackup.every] is allowed up to four times itself.
const realtimeBackupMaxDownInterval = Duration(minutes: 2);

/// The interval a backup re-reads at: [every] while the channel is down,
/// and the slower of [every] and [healthy] while it is open -- or none while
/// it is open when [healthy] is null. Pure.
Duration? realtimeBackupPeriod({required Duration every, required Duration? healthy, required bool connected}) {
  if (!connected) return every;
  if (healthy == null) return null;
  return healthy > every ? healthy : every;
}

/// The wait before the next read while the channel is down, after
/// [downReads] reads since it went down: [every] for the first
/// [realtimeBackupSteadyDownReads], then doubling, capped at
/// [realtimeBackupMaxDownInterval] (or four times [every], if longer). Pure.
Duration realtimeBackupDownDelay({required Duration every, required int downReads}) {
  final cap = every * 4 > realtimeBackupMaxDownInterval ? every * 4 : realtimeBackupMaxDownInterval;
  final doublings = downReads - realtimeBackupSteadyDownReads + 1;
  if (doublings <= 0) return every;
  final grown = every * (1 << (doublings > 16 ? 16 : doublings));
  return grown > cap ? cap : grown;
}

/// The backup behind every realtime subscription in the app.
///
/// Realtime can drop an update (a weak connection, a socket that reopened),
/// it replays nothing that changed while the phone held the app suspended,
/// and a change made between a screen's first read and its channel opening
/// never arrives at all. So whatever follows rows live also reads them
/// again itself: when the channel opens ([onStatus]), when the app comes
/// back to the foreground, and on a timer -- every [every] while the
/// channel is down (backing off when it stays down, see
/// [realtimeBackupDownDelay]), every [healthy] while it is open. A missed
/// update then shows late instead of never, without polling the API while
/// realtime is doing the job. A channel that keeps dropping and reopening
/// reads at most once per [every] for it.
class RealtimeBackup {
  /// [onOpen] false skips the read when the channel first opens (the caller
  /// has just read everything anyway); a reopened channel still reads.
  /// [healthy] null reads nothing on the timer while the channel is open, and
  /// [resumeWhileOpen] false skips the read on coming back to the foreground
  /// while the channel is open and has not dropped since the last read (a
  /// socket that dropped meanwhile reads as it reopens). [healthyJitter]
  /// moves each wait while open by up to that fraction of [healthy] either
  /// way (see [realtimeBackupJittered]); [random] is for tests.
  RealtimeBackup(
    this._refresh, {
    this.every = realtimeBackupInterval,
    this.healthy = realtimeBackupHealthyInterval,
    bool onOpen = true,
    this.resumeWhileOpen = true,
    this.healthyJitter = 0,
    Random? random,
  }) : _skipOpen = !onOpen,
       _random = random ?? Random() {
    _schedule();
    try {
      _lifecycle = AppLifecycleListener(onResume: resumed);
    } catch (_) {
      // No binding (a plain unit test): the timer still runs.
    }
  }

  final FutureOr<void> Function() _refresh;

  /// The interval while the channel is down.
  final Duration every;

  /// The interval while it is open (never faster than [every]); null for no
  /// timer reads while it is open.
  final Duration? healthy;

  /// Whether coming back to the foreground reads even while the channel is
  /// open and has not dropped since the last read.
  final bool resumeWhileOpen;

  /// The fraction each wait while open may move by either way.
  final double healthyJitter;
  final Random _random;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  bool _busy = false;
  bool _disposed = false;
  bool _skipOpen;
  bool _connected = false;

  /// The channel went down after being open, and nothing was read since.
  bool _droppedSinceRead = false;

  /// Timer reads since the channel was last open.
  int _downReads = 0;

  /// Running from a status-triggered read until [every] after it: a channel
  /// flapping open and shut meanwhile does not read again on each flap.
  Timer? _cooldown;

  /// The wait before the timer's next read; null while none is due.
  Duration? get period => _connected
      ? realtimeBackupPeriod(every: every, healthy: healthy, connected: true)
      : realtimeBackupDownDelay(every: every, downReads: _downReads);

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (_disposed) return;
    var wait = period;
    if (wait == null) return;
    if (_connected && healthyJitter > 0) {
      wait = realtimeBackupJittered(wait, fraction: healthyJitter, unit: _random.nextDouble());
    }
    _timer = Timer(wait, () {
      if (!_connected) _downReads++;
      run();
      _schedule();
    });
  }

  /// Back in the foreground: reads again, unless [resumeWhileOpen] is false
  /// and the channel is open and has not dropped since the last read.
  void resumed() {
    if (!resumeWhileOpen && _connected && !_droppedSinceRead) return;
    run();
  }

  /// Reads again now, unless a read is already under way.
  void run() {
    if (_busy || _disposed) return;
    _busy = true;
    _droppedSinceRead = false;
    Future.sync(_refresh).catchError((Object _) {}).whenComplete(() => _busy = false);
  }

  /// [run] for a status change, unless one did less than [every] ago.
  void _runThrottled() {
    if (_cooldown != null) return;
    _cooldown = Timer(every, () => _cooldown = null);
    run();
  }

  /// Pass to `channel.subscribe(...)`: reads once more as the channel opens,
  /// slows the timer while it is open and speeds it up again (with a read
  /// straight away) when it errors, times out or closes.
  void onStatus(RealtimeSubscribeStatus status, [Object? _]) {
    if (_disposed) return;
    final connected = status == RealtimeSubscribeStatus.subscribed;
    final changed = connected != _connected;
    if (changed && !connected) _droppedSinceRead = true;
    _connected = connected;
    if (connected) _downReads = 0;
    if (changed) _schedule();
    if (!connected) {
      // Whatever the channel would have delivered is now the timer's job.
      if (changed) _runThrottled();
      return;
    }
    if (_skipOpen) {
      _skipOpen = false;
      return;
    }
    _runThrottled();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _cooldown?.cancel();
    _lifecycle?.dispose();
  }
}
