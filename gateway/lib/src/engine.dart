// The gateway loop. While online it:
//   - says the phone is here (a heartbeat every minute), so the admin page
//     shows it online and the server knows which device row it is;
//   - asks every few seconds for the SMS routed to it, sends each from the
//     chosen SIM and reports how it went (every 5 s while there is work and
//     for a minute after, easing to every 15 s when quiet: `pollAfter`);
//   - hands every SMS the phone receives to the server, and only then drops
//     it from the phone's own queue, so nothing received is lost to a
//     dropped connection.
// A failed call to the server backs off (5 s doubling to 2 min) and keeps
// trying; a refusal (the account is not an admin, or signed out) stops the
// gateway and says why, since retrying cannot fix it.
//
// While online it can also share the phone's internet with a test session
// (migration 0226): the phone's side keeps a socket to the relay and
// performs the requests it is handed; the engine only turns that on and off
// with the switch and the gateway, and keeps its state for the screen.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'core.dart';
import 'sms_platform.dart';

enum GatewayState { off, starting, online, reconnecting }

/// The relay a shared internet connects to (cloudflare/session-proxy);
/// overridden with --dart-define=GATEWAY_RELAY_URL=... for another zone.
const defaultRelayUrl = String.fromEnvironment('GATEWAY_RELAY_URL', defaultValue: 'wss://proxy.getride.my/phone');

/// What the engine reads from the phone's settings when it needs it.
class GatewayConfig {
  const GatewayConfig({
    required this.deviceId,
    this.label,
    this.simNumber,
    this.subscriptionId,
    this.gatewayKey,
    this.shareInternet = false,
    this.mobileDataOnly = true,
  });

  /// This install's stable id (not the server's device row id).
  final String deviceId;
  final String? label;
  final String? simNumber;
  final int? subscriptionId;

  /// The device key from pairing; the shared internet connects with it.
  final String? gatewayKey;

  /// Whether to share this phone's internet while the gateway is online.
  final bool shareInternet;

  /// Whether shared requests go out over mobile data only.
  final bool mobileDataOnly;
}

class GatewayEngine extends ChangeNotifier {
  GatewayEngine({
    required this.backend,
    required this.platform,
    required this.config,
    this.appVersion,
    this.pollEvery = const Duration(seconds: 5),
    this.pollQuietMax = const Duration(seconds: 15),
    this.heartbeatEvery = const Duration(minutes: 1),
    this.schedule = true,
    this.relayUrl = defaultRelayUrl,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    platform.onProxyEvent(_proxyEvent);
  }

  final GatewayBackend backend;
  final SmsPlatform platform;
  final GatewayConfig Function() config;
  final String? appVersion;
  /// How often to ask for new SMS while busy, and at most how long to wait
  /// once quiet (`pollAfter`): the second is the longest a sign-in code
  /// can wait for this phone.
  final Duration pollEvery;
  final Duration pollQuietMax;
  final Duration heartbeatEvery;

  /// Where the shared internet connects (empty: never shared).
  final String relayUrl;

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

  /// The shared internet, as the phone's side last reported it.
  ProxyState _proxy = ProxyState.off;
  ProxyState get proxy => _proxy;

  /// Why the shared internet stopped by itself, until it is started again.
  String? _proxyReason;
  String? get proxyReason => _proxyReason;

  /// Whether the phone's side was last asked to share.
  bool _proxyAsked = false;

  Timer? _timer;
  StreamSubscription<IncomingSms>? _incomingSub;
  bool _busy = false;
  int _failures = 0;
  DateTime? _retryAt;
  DateTime? _lastHeartbeat;

  /// When an SMS last came to be sent or was received (or the gateway
  /// started): how quiet it is, for [pollAfter].
  DateTime _lastWork = DateTime.fromMillisecondsSinceEpoch(0);

  /// When the timer's next round is due (rounds the phone starts itself,
  /// such as on a received SMS, do not wait for it).
  DateTime? _nextPoll;

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
    _lastWork = _now();
    _nextPoll = null;
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
    if (schedule) _timer = Timer.periodic(_timerEvery, (_) => unawaited(poll()));
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
    await _stopProxy();
    await _safe(platform.stopService);
  }

  /// Shares the phone's internet, or stops sharing it, as the settings say
  /// now: called when the gateway comes online and when the switch moves.
  /// Nothing is shared while the gateway is off, or before it is paired.
  Future<void> syncProxy() async {
    final c = config();
    final key = c.gatewayKey;
    if (!running || !c.shareInternet || key == null || relayUrl.isEmpty) {
      await _stopProxy();
      return;
    }
    if (!_proxyAsked) {
      _proxyReason = null;
      _proxyAsked = true;
    }
    await _safe(() => platform.startProxy(url: relayUrl, key: key, label: c.label ?? '', mobileDataOnly: c.mobileDataOnly));
  }

  Future<void> _stopProxy() async {
    if (!_proxyAsked && _proxy == ProxyState.off) return;
    _proxyAsked = false;
    await _safe(platform.stopProxy);
    if (_proxy != ProxyState.off && _proxy != ProxyState.error) _setProxy(ProxyState.off, 'Internet sharing stopped.');
  }

  /// An event from the phone's side of the shared internet (ProxyClient.kt).
  void _proxyEvent(Map<String, Object?> event) {
    final state = proxyStateFrom(event);
    final line = proxyLogLine(event);
    if (state != null) {
      if (state == ProxyState.error) {
        _proxyAsked = false;
        _proxyReason = '${event['reason'] ?? 'The relay refused this phone.'}';
      }
      // Reconnecting is reported on every retry: logged once per outage.
      if (state != _proxy) _setProxy(state, line);
      return;
    }
    if (event['state'] == 'request') {
      if (event['error'] == null) stats.relayed++;
      if (line != null) log.add(GatewayLogEntry(_now(), GatewayLogKind.proxy, line));
    } else if (line != null) {
      log.add(GatewayLogEntry(_now(), GatewayLogKind.proxy, line));
    }
    notifyListeners();
  }

  void _setProxy(ProxyState s, String? line) {
    _proxy = s;
    if (line != null) {
      log.add(GatewayLogEntry(_now(), s == ProxyState.error ? GatewayLogKind.error : GatewayLogKind.proxy, line));
    }
    if (running) unawaited(_safe(() => platform.startService(_serviceText())));
    notifyListeners();
  }

  /// The timer's resolution: fine enough that a due round is never late by
  /// much, while a round only runs when [poll] says it is due.
  Duration get _timerEvery => pollEvery < const Duration(seconds: 1) ? pollEvery : const Duration(seconds: 1);

  /// How long the next timed round waits, as quiet as it is now.
  Duration get pollInterval => pollAfter(_now().difference(_lastWork), every: pollEvery, max: pollQuietMax);

  /// A timed round: runs [tick] once the interval since the last round has
  /// passed ([pollAfter]: 5 s while busy, easing to 15 s when quiet).
  Future<void> poll() async {
    final due = _nextPoll;
    if (due != null && _now().isBefore(due)) return;
    await tick();
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
      _nextPoll = _now().add(pollInterval);
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
      _lastWork = _now();
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
    _lastWork = _now();
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
      unawaited(syncProxy());
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

  String _serviceText() =>
      'Online · ${stats.sent} sent · ${stats.received} received'
      '${_proxy == ProxyState.connected ? ' · internet shared' : ''}';

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
