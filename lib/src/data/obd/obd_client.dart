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
    this.linkLostFailures = 3,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final ObdTransport _transport;
  final void Function(Telemetry telemetry, int at)? onTelemetry;
  final void Function(String name, int? bitrateKbps)? onProtocol;
  final void Function()? onLinkLost;
  final Duration pollInterval;
  final Duration commandTimeout;
  final int linkLostFailures;
  final int Function() _now;

  String _buffer = '';
  Completer<String>? _waiter;
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
    for (final cmd in elmInitCommands) {
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
        if (_stopped) return;
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
    if (!_live || _stopped || _linkLostReported) return;
    _failures++;
    if (_failures >= linkLostFailures) {
      _linkLostReported = true;
      onLinkLost?.call();
    }
  }

  Future<String> _command(String cmd) {
    final run = _tail.then((_) => _sendNow(cmd), onError: (_) => _sendNow(cmd));
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<String> _sendNow(String cmd) {
    if (_stopped) return Future.error(StateError('client stopped'));
    _buffer = '';
    final waiter = Completer<String>();
    _waiter = waiter;
    final timer = Timer(commandTimeout, () {
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
