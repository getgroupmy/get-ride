import 'dart:async';

import '../../core/obd.dart';
import 'obd_transport.dart';

/// Talks ELM327 over any [ObdTransport] (Expo `CanbusClient`): initialises
/// the adapter, reports the protocol it settled on, then sweeps [obdPids]
/// once a second.
///
/// An adapter answers one command at a time, so every command — the sweep's
/// and [request]'s — goes through one queue. Three failed commands in a row
/// on a live link report it lost, so a dongle that was unplugged or walked
/// out of Wi-Fi range is noticed even though the socket never says so.
class ObdClient {
  ObdClient(
    this._transport, {
    this.onTelemetry,
    this.onProtocol,
    this.onLinkLost,
    this.pollInterval = const Duration(seconds: 1),
    this.commandTimeout = const Duration(seconds: 4),
    this.wakeTimeout = const Duration(milliseconds: 1500),
    this.resetTimeout = const Duration(seconds: 5),
    this.linkLostFailures = 3,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final ObdTransport _transport;
  final void Function(Telemetry telemetry, int at)? onTelemetry;
  final void Function(String name, int? bitrateKbps)? onProtocol;
  final void Function()? onLinkLost;
  final Duration pollInterval;
  final Duration commandTimeout;

  /// How long the wake-up carriage return is waited on.
  final Duration wakeTimeout;

  /// How long the reset (ATZ) is waited on: the chip restarts before it
  /// answers, and Bluetooth clones take longest.
  final Duration resetTimeout;
  final int linkLostFailures;
  final int Function() _now;

  String _buffer = '';
  Completer<String>? _waiter;
  bool Function(String)? _skip;
  StreamSubscription<String>? _sub;
  Timer? _poll;
  Future<void> _tail = Future.value();
  bool _stopped = false;
  bool _polling = false;
  bool _paused = false;
  bool _live = false;
  int _failures = 0;
  bool _linkLostReported = false;

  bool get active => !_stopped;

  /// Initialises the adapter and starts the sweep. Throws when the adapter
  /// does not answer the init commands.
  Future<void> start() async {
    _sub = _transport.data.listen(_ingest);
    await _reset();
    for (final cmd in elmInitCommands.skip(1)) {
      await _command(cmd);
    }
    try {
      final dpn = await _command(elmDescribeProtocol);
      final p = describeProtocol(cleanElmResponse(dpn).firstOrNull);
      onProtocol?.call(p.name, p.bitrateKbps);
    } catch (_) {
      // The protocol name is best-effort.
    }
    _live = true;
    _poll = Timer.periodic(pollInterval, (_) => _pollOnce());
    unawaited(_pollOnce());
  }

  /// Wakes the reader and resets it (ATZ). A bare carriage return goes
  /// first, answered or not: it clears a half-typed command and takes the
  /// loss on clones that drop the first packet after the link opens. A
  /// reader that still doesn't answer is tried the link's other ways
  /// ([ObdRetunable]) before the handshake fails.
  Future<void> _reset() async {
    final reset = elmInitCommands.first;
    while (true) {
      try {
        await _command('', timeout: wakeTimeout);
      } catch (_) {
        // A reader that ignores the empty line still takes the reset.
      }
      try {
        await _command(reset, timeout: resetTimeout, skip: isStaleResetReply);
        return;
      } on TimeoutException {
        final t = _transport;
        if (_stopped || t is! ObdRetunable || !await (t as ObdRetunable).retune()) {
          throw TimeoutException('The reader connected but did not answer ($reset).');
        }
      }
    }
  }

  /// Pauses the sweep, for a long one-off read that must not interleave.
  void setPollingPaused(bool paused) => _paused = paused;

  /// Sends one command through the queue and answers the raw reply.
  Future<String> request(String command) => _command(command);

  Future<void> _pollOnce() async {
    if (_stopped || _paused || _polling) return;
    _polling = true;
    try {
      final telemetry = <String, double>{};
      for (final entry in obdPids.entries) {
        // Held mid-sweep (a print job starting): stop between readings.
        if (_stopped || _paused) return;
        try {
          final value = decodePid(await _command(entry.value.command), entry.value);
          if (value != null) telemetry[entry.key] = value;
        } catch (_) {
          // One unanswered PID is not a lost link; the failure count is.
        }
      }
      if (telemetry.isNotEmpty) onTelemetry?.call(telemetry, _now());
    } finally {
      _polling = false;
    }
  }

  void _noteFailure() {
    // Held for a print job or the vehicle scan, a missed reply is the radio
    // being busy, not the reader gone.
    if (!_live || _stopped || _linkLostReported || _paused) return;
    _failures++;
    if (_failures >= linkLostFailures) {
      _linkLostReported = true;
      onLinkLost?.call();
    }
  }

  /// [skip] passes over a reply that can't be this command's answer.
  Future<String> _command(String cmd, {Duration? timeout, bool Function(String)? skip}) {
    final run = _tail.then((_) => _sendNow(cmd, timeout, skip), onError: (_) => _sendNow(cmd, timeout, skip));
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<String> _sendNow(String cmd, [Duration? timeout, bool Function(String)? skip]) {
    if (_stopped) return Future.error(StateError('client stopped'));
    _buffer = '';
    _skip = skip;
    final waiter = Completer<String>();
    _waiter = waiter;
    final timer = Timer(timeout ?? commandTimeout, () {
      if (waiter.isCompleted) return;
      _waiter = null;
      _noteFailure();
      waiter.completeError(TimeoutException('"$cmd" timed out'));
    });
    _transport.write(cmd).catchError((Object e) {
      if (waiter.isCompleted) return;
      timer.cancel();
      _waiter = null;
      _noteFailure();
      waiter.completeError(e);
    });
    return waiter.future.whenComplete(timer.cancel);
  }

  void _ingest(String chunk) {
    _buffer += chunk;
    final waiter = _waiter;
    if (waiter == null || !_buffer.contains(elmPrompt)) return;
    final response = _buffer;
    _buffer = '';
    if (_skip?.call(response) ?? false) return;
    _waiter = null;
    _failures = 0;
    if (!waiter.isCompleted) waiter.complete(response);
  }

  Future<void> stop() async {
    _stopped = true;
    _live = false;
    _poll?.cancel();
    _poll = null;
    // Not awaited: nothing depends on the cancel, and a dead link must not
    // hold up the disconnect.
    unawaited(_sub?.cancel());
    _sub = null;
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.completeError(StateError('client stopped'));
    await _transport.disconnect();
  }
}
