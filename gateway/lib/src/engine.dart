// The gateway loop. While online it:
//   - says the phone is here (a heartbeat every minute), so the admin page
//     shows it online and the server knows which device row it is;
//   - asks every few seconds for the SMS routed to it, sends each from the
//     chosen SIM and reports how it went;
//   - hands every SMS the phone receives to the server, and only then drops
//     it from the phone's own queue, so nothing received is lost to a
//     dropped connection.
// A failed call to the server backs off (5 s doubling to 2 min) and keeps
// trying; a refusal (the account is not an admin, or signed out) stops the
// gateway and says why, since retrying cannot fix it.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'core.dart';
import 'sms_platform.dart';

enum GatewayState { off, starting, online, reconnecting }

/// What the engine reads from the phone's settings when it needs it.
class GatewayConfig {
  const GatewayConfig({required this.deviceId, this.label, this.simNumber, this.subscriptionId});

  /// This install's stable id (not the server's device row id).
  final String deviceId;
  final String? label;
  final String? simNumber;
  final int? subscriptionId;
}

class GatewayEngine extends ChangeNotifier {
  GatewayEngine({
    required this.backend,
    required this.platform,
    required this.config,
    this.appVersion,
    this.pollEvery = const Duration(seconds: 5),
    this.heartbeatEvery = const Duration(minutes: 1),
    this.schedule = true,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final GatewayBackend backend;
  final SmsPlatform platform;
  final GatewayConfig Function() config;
  final String? appVersion;
  final Duration pollEvery;
  final Duration heartbeatEvery;

  /// False in tests, which drive [tick] themselves.
  final bool schedule;
  final DateTime Function() _now;

  final log = GatewayLog();
  final stats = GatewayStats();

  GatewayState _state = GatewayState.off;
  GatewayState get state => _state;

  /// Why the gateway stopped by itself, until it is started again.
  String? _stopReason;
  String? get stopReason => _stopReason;

  /// The server's id for this phone, once a heartbeat has been accepted.
  String? _device;
  String? get device => _device;

  Timer? _timer;
  StreamSubscription<IncomingSms>? _incomingSub;
  bool _busy = false;
  int _failures = 0;
  DateTime? _retryAt;
  DateTime? _lastHeartbeat;

  /// Received SMS not yet accepted by the server, by the phone's id.
  final _inbound = <String, IncomingSms>{};

  /// Jobs sent (or failed) whose report did not reach the server yet: not
  /// sent again, only reported again.
  final _unreported = <String, SmsSendResult>{};

  bool get running => _state != GatewayState.off;

  Future<void> start() async {
    if (running) return;
    _stopReason = null;
    _failures = 0;
    _retryAt = null;
    _lastHeartbeat = null;
    _setState(GatewayState.starting);
    _info('Gateway started.');
    await _safe(() => platform.startService('Starting…'));
    _incomingSub = platform.incoming.listen((sms) {
      _inbound.putIfAbsent(sms.id, () => sms);
      unawaited(tick());
    });
    for (final sms in await _safeValue(platform.pending, const <IncomingSms>[])) {
      _inbound.putIfAbsent(sms.id, () => sms);
    }
    if (schedule) _timer = Timer.periodic(pollEvery, (_) => unawaited(tick()));
    await tick();
  }

  Future<void> stop({String? reason}) async {
    if (!running) return;
    _timer?.cancel();
    _timer = null;
    // Not awaited: nothing depends on the cancel finishing, and a platform
    // stream may only acknowledge it later.
    unawaited(_incomingSub?.cancel());
    _incomingSub = null;
    _stopReason = reason;
    _device = null;
    if (reason != null) {
      log.add(GatewayLogEntry(_now(), GatewayLogKind.error, reason));
    } else {
      _info('Gateway stopped.');
    }
    _setState(GatewayState.off);
    await _safe(platform.stopService);
  }

  /// One round: heartbeat when due, then received SMS, unsent reports and
  /// new jobs. Rounds never overlap.
  Future<void> tick() async {
    if (!running || _busy) return;
    final now = _now();
    if (_retryAt != null && now.isBefore(_retryAt!)) return;
    _busy = true;
    try {
      if (_device == null || _lastHeartbeat == null || now.difference(_lastHeartbeat!) >= heartbeatEvery) {
        final c = config();
        _device = await backend.heartbeat(
          deviceId: c.deviceId,
          label: c.label,
          simNumber: c.simNumber,
          appVersion: appVersion,
        );
        _lastHeartbeat = now;
      }
      final device = _device!;
      await _flushInbound(device);
      await _flushReports(device);
      await _sendJobs(device);
      _recovered();
    } catch (e) {
      final refusal = gatewayRefusal(e);
      if (refusal != null) {
        _busy = false;
        await stop(reason: refusal);
        return;
      }
      _failed(e);
    } finally {
      _busy = false;
    }
  }

  Future<void> _flushInbound(String device) async {
    for (final sms in _inbound.values.toList()) {
      await backend.receive(device, sms);
      _inbound.remove(sms.id);
      stats.received++;
      log.add(GatewayLogEntry(_now(), GatewayLogKind.received, 'SMS from ${maskPhone(sms.from)}'));
      await _safe(() => platform.acknowledge([sms.id]));
      notifyListeners();
    }
  }

  Future<void> _flushReports(String device) async {
    for (final e in _unreported.entries.toList()) {
      await backend.report(device, e.key, ok: e.value.ok, error: e.value.error);
      _unreported.remove(e.key);
    }
  }

  Future<void> _sendJobs(String device) async {
    final jobs = await backend.claim(device);
    if (jobs.isEmpty) return;
    final sub = config().subscriptionId;
    for (final job in jobs) {
      final result = await platform.send(job.to, job.body, subscriptionId: sub);
      if (result.ok) {
        stats.sent++;
        log.add(GatewayLogEntry(_now(), GatewayLogKind.sent, jobSummary(job)));
      } else {
        stats.failed++;
        log.add(GatewayLogEntry(_now(), GatewayLogKind.failed, '${jobSummary(job)}: ${result.error}'));
      }
      // Held until the server has it: a lost report must not send it twice.
      _unreported[job.id] = result;
      notifyListeners();
      await backend.report(device, job.id, ok: result.ok, error: result.error);
      _unreported.remove(job.id);
    }
    await _safe(() => platform.startService(_serviceText()));
  }

  void _recovered() {
    if (_failures > 0) _info('Connected again.');
    _failures = 0;
    _retryAt = null;
    if (_state != GatewayState.online) {
      _setState(GatewayState.online);
      unawaited(_safe(() => platform.startService(_serviceText())));
    }
  }

  void _failed(Object e) {
    _failures++;
    _retryAt = _now().add(backoffAfter(_failures));
    if (_failures == 1) log.add(GatewayLogEntry(_now(), GatewayLogKind.error, describeError(e)));
    if (_state != GatewayState.reconnecting) {
      _setState(GatewayState.reconnecting);
      unawaited(_safe(() => platform.startService('Reconnecting…')));
    } else {
      notifyListeners();
    }
  }

  String _serviceText() => 'Online · ${stats.sent} sent · ${stats.received} received';

  void _info(String text) => log.add(GatewayLogEntry(_now(), GatewayLogKind.info, text));

  void _setState(GatewayState s) {
    _state = s;
    notifyListeners();
  }

  /// The phone's side failing must not take the loop down with it.
  Future<void> _safe(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (kDebugMode) debugPrint('gateway platform: $e');
    }
  }

  Future<T> _safeValue<T>(Future<T> Function() f, T fallback) async {
    try {
      return await f();
    } catch (_) {
      return fallback;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_incomingSub?.cancel());
    super.dispose();
  }
}
