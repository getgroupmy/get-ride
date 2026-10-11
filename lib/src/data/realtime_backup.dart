import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

/// How often a live screen reads its rows again on its own.
const realtimeBackupInterval = Duration(seconds: 5);

/// The backup behind every realtime subscription in the app.
///
/// Realtime can drop an update (a weak connection, a socket that reopened),
/// it replays nothing that changed while the phone held the app suspended,
/// and a change made between a screen's first read and its channel opening
/// never arrives at all. So whatever follows rows live also reads them
/// again itself: when the channel opens ([onStatus]), every [every], and
/// when the app comes back to the foreground. A missed update then shows a
/// few seconds late instead of never.
class RealtimeBackup {
  /// [onOpen] false skips the read when the channel first opens (the caller
  /// has just read everything anyway); a reopened channel still reads.
  RealtimeBackup(this._refresh, {Duration every = realtimeBackupInterval, bool onOpen = true}) : _skipOpen = !onOpen {
    _timer = Timer.periodic(every, (_) => run());
    try {
      _lifecycle = AppLifecycleListener(onResume: run);
    } catch (_) {
      // No binding (a plain unit test): the timer still runs.
    }
  }

  final FutureOr<void> Function() _refresh;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  bool _busy = false;
  bool _disposed = false;
  bool _skipOpen;

  /// Reads again now, unless a read is already under way.
  void run() {
    if (_busy || _disposed) return;
    _busy = true;
    Future.sync(_refresh).catchError((Object _) {}).whenComplete(() => _busy = false);
  }

  /// Pass to `channel.subscribe(...)`: reads once more as the channel opens.
  void onStatus(RealtimeSubscribeStatus status, [Object? _]) {
    if (status != RealtimeSubscribeStatus.subscribed) return;
    if (_skipOpen) {
      _skipOpen = false;
      return;
    }
    run();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _lifecycle?.dispose();
  }
}
