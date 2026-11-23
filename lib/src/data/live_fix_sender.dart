// Sends the driver's GPS fixes to the passenger's map, one at a time.
//
// A phone's GPS gives a fix about once a second and each is news for about
// that long, so there is never a queue: one fix is on its way at a time, and
// while it is, only the newest of those that come in is kept for after it. On
// a slow connection the passenger's map then simply hears less often; it never
// hears positions minutes old in the order they were taken.
//
// It keeps time with timers alone and reads no clock, so it behaves the same
// wherever the app's clock is put (a test's included).
import 'dart:async';

import 'live_fix.dart';

/// The least time from the start of one send to the start of the next: a
/// little under the second between two GPS fixes, so that each of them goes
/// and a burst of them does not.
const liveFixSendLeast = Duration(milliseconds: 700);

/// How long a send may take before it is given up on (a connection that has
/// gone quiet without saying so would otherwise hold up every fix after it).
const liveFixSendTimeout = Duration(seconds: 6);

/// How long nothing is sent after a send failed: no connection just now.
const liveFixRetryAfter = Duration(seconds: 3);

/// How long nothing is sent after the server answered that the ride takes no
/// fixes from this phone (it has ended, or passed to another driver): the
/// screen is about to say so too.
const liveFixRefusedHold = Duration(seconds: 15);

/// Sends fixes through [send] as they are [offer]ed (see the top of this file).
class LiveFixSender {
  /// [send] answers whether the ride takes fixes (false: not from this phone,
  /// not now) and throws when the fix could not be sent; [unsupported] says
  /// whether what it threw means the server never will take one, and the
  /// sender then stops for good.
  LiveFixSender(this._send, {bool Function(Object error)? unsupported}) : _unsupported = unsupported ?? ((_) => false);

  final Future<bool> Function(LiveFix fix) _send;
  final bool Function(Object error) _unsupported;

  /// The newest fix not yet sent.
  LiveFix? _next;

  /// A send is on its way.
  bool _busy = false;

  /// The pause before the next send may start, while it runs.
  Timer? _pause;

  bool _stopped = false, _disposed = false;

  /// Whether the server has said it has nowhere to take a fix: nothing more
  /// is sent.
  bool get stopped => _stopped;

  /// A fix from the GPS: sent now, or kept — the newest only — until the one
  /// on its way is done and the pause after it is over.
  void offer(LiveFix fix) {
    if (_stopped || _disposed) return;
    _next = fix;
    _pump();
  }

  /// Forgets a fix that has not been sent: the ride is no longer under way.
  void drop() => _next = null;

  void dispose() {
    _disposed = true;
    _next = null;
    _pause?.cancel();
    _pause = null;
  }

  void _pump() {
    if (_busy || _pause != null || _stopped || _disposed) return;
    final fix = _next;
    if (fix == null) return;
    _next = null;
    _busy = true;
    _wait(liveFixSendLeast);
    unawaited(_run(fix));
  }

  /// Nothing more is sent for [time] (from now, whatever pause was running).
  void _wait(Duration time) {
    _pause?.cancel();
    _pause = Timer(time, () {
      _pause = null;
      _pump();
    });
  }

  Future<void> _run(LiveFix fix) async {
    try {
      final taken = await _send(fix).timeout(liveFixSendTimeout);
      if (!taken && !_disposed) {
        _next = null;
        _wait(liveFixRefusedHold);
      }
    } catch (e) {
      if (_disposed) return;
      if (_unsupported(e)) {
        _stopped = true;
        _next = null;
        _pause?.cancel();
        _pause = null;
      } else {
        _wait(liveFixRetryAfter);
      }
    } finally {
      _busy = false;
      if (!_disposed) _pump();
    }
  }
}
