// The phones find each other at the kerb (reliability Phase D2): while a ride
// is accepted or arrived, this phone advertises its token (as a service UUID,
// lib/src/core/ble_handshake.dart) and scans for the other phone's; once it
// has seen it strongly enough for long enough it reports to the server
// (ble_handshake_proof, 0153), which decides. The trip code always still
// works: anything that goes wrong here leaves it as the way to start.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:universal_ble/universal_ble.dart';

import '../core/ble_chat.dart';
import '../core/ble_handshake.dart';
import 'ble.dart';
import 'ble_chat.dart';
import 'geo_service.dart';
import 'ride_repository.dart';

/// One phone in sight: the service UUID it advertised, and how strongly.
typedef BleAdvert = ({String uuid, int rssi, String deviceId});

/// The phone's own Bluetooth: advertising one UUID and scanning for others.
/// A seam so tests can play the kerb back.
abstract class BleRadio {
  /// Starts advertising [uuid] and scanning. Returns why it can't, for the
  /// badge; null when it is running.
  Future<String?> start(String uuid);

  /// Everything the scan sees, as it sees it.
  Stream<BleAdvert> get adverts;

  Future<void> stop();
}

final bleRadioProvider = Provider<BleRadio>((_) => UniversalBleRadio());

/// Where this phone is, sent with a report; overridable in tests.
final blePositionProvider = Provider<Future<LatLng?> Function()>((_) => currentPosition);

/// The clock sightings are timed by; overridable in tests.
final bleClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

class UniversalBleRadio implements BleRadio {
  bool _scanning = false;
  bool _advertising = false;

  @override
  Stream<BleAdvert> get adverts =>
      UniversalBle.scanStream.expand(
        (d) => [for (final s in d.services) (uuid: s, rssi: d.rssi ?? -127, deviceId: d.deviceId)],
      );

  @override
  Future<String?> start(String uuid) async {
    if (kIsWeb) return 'A browser can\'t use Bluetooth';
    try {
      await ensureBluetoothReady();
    } on StateError catch (e) {
      return e.message;
    } catch (e) {
      return 'Bluetooth isn\'t available';
    }
    try {
      if (_advertising) await UniversalBlePeripheral.stopAdvertising();
      await UniversalBlePeripheral.startAdvertising(services: [uuid]);
      _advertising = true;
      if (!_scanning) {
        await bleScans.acquire();
        _scanning = true;
      }
      return null;
    } catch (e) {
      await stop();
      return 'This phone can\'t be found over Bluetooth';
    }
  }

  @override
  Future<void> stop() async {
    if (_advertising) {
      _advertising = false;
      try {
        await UniversalBlePeripheral.stopAdvertising();
      } catch (_) {}
    }
    if (_scanning) {
      _scanning = false;
      await bleScans.release();
    }
  }
}

/// The server half, as the engine needs it. A seam for tests.
class BleHandshakeServer {
  const BleHandshakeServer({required this.ticket, required this.proof});

  final Future<BleTicket> Function() ticket;
  final Future<BleProofResult> Function(String seenToken, int rssi, Duration seenFor, LatLng? at) proof;

  factory BleHandshakeServer.forRide(RideRepository repo, String rideId) => BleHandshakeServer(
    ticket: () => repo.bleTicket(rideId),
    proof: (token, rssi, seenFor, at) =>
        repo.bleProof(rideId, seenToken: token, rssi: rssi, seenFor: seenFor, lat: at?.latitude, lng: at?.longitude),
  );
}

/// How often a qualifying sighting is reported again.
const bleReportEvery = Duration(seconds: 4);

/// How long to hold off after the server says "too many".
const bleRateLimitBackoff = Duration(seconds: 30);

/// Runs the handshake for one ride on this phone.
class BleHandshakeEngine {
  BleHandshakeEngine({
    required this.radio,
    required this.server,
    required this.isAndroid,
    required this.isIos,
    this._status,
    Future<LatLng?> Function()? position,
    DateTime Function()? now,
    this.chatFactory,
  }) : _position = position ?? currentPosition,
       _now = now ?? DateTime.now;

  final BleRadio radio;
  final BleHandshakeServer server;
  final bool isAndroid;
  final bool isIos;
  final Future<LatLng?> Function() _position;
  final DateTime Function() _now;

  /// Builds this ride's Bluetooth chat (Phase D3) from a ticket that carries
  /// a chat key; null leaves chat out.
  final BleChatSession Function(BleTicket ticket, Uint8List key)? chatFactory;

  /// The ride's Bluetooth chat while it runs.
  final chat = ValueNotifier<BleChatSession?>(null);

  /// What the badge shows.
  final phase = ValueNotifier(BleHandshakePhase.idle);

  /// Seconds left to cancel while counting down.
  final countdownLeft = ValueNotifier(0);

  /// The other phone's signal, smoothed, while it's in range; null when it
  /// isn't. Every sighting counts here, however weak (it's for the distance
  /// hint, not the match).
  final peerRssi = ValueNotifier<int?>(null);
  DateTime? _peerAt;

  String? _status;
  BleTicket? _ticket;
  String? _unavailable;
  PeerSighting _seen = const PeerSighting();
  StreamSubscription<BleAdvert>? _sub;
  Timer? _tick;
  Timer? _refresh;
  Timer? _countdown;
  DateTime? _lastReport;
  DateTime? _holdUntil;
  bool _reporting = false;
  bool _countedDown = false;
  bool _running = false;
  bool _done = false;
  bool _disposed = false;

  /// Why Bluetooth couldn't be used, when [phase] is unavailable.
  String? get unavailableReason => _unavailable;

  static bool _live(String? status) => status == 'accepted' || status == 'arrived';

  /// Starts, when the ride is waiting at the kerb and the admin has it on.
  Future<void> start() async {
    if (_done || _running || !_live(_status)) return;
    _running = true;
    final ticket = await _fetchTicket();
    if (ticket == null || _done) return _halt(BleHandshakePhase.idle);
    _sub = radio.adverts.listen(_onAdvert);
    if (!await _advertise(ticket)) return;
    phase.value = BleHandshakePhase.searching;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    await _startChat(ticket);
  }

  Future<void> _startChat(BleTicket t) async {
    final key = bleChatKey(t.chatKey);
    if (chatFactory == null || key == null || !t.settings.chat || chat.value != null || !_running) return;
    final session = chatFactory!(t, key);
    chat.value = session;
    await session.start();
  }

  /// The ride's status, as the screen sees it. Leaving the kerb stops this.
  void updateStatus(String? status) {
    final was = _status;
    if (status == was) return;
    _status = status;
    if (status == 'on_trip' && phase.value != BleHandshakePhase.idle) {
      _halt(phase.value == BleHandshakePhase.started ? BleHandshakePhase.started : BleHandshakePhase.idle);
    } else if (!_live(status)) {
      _halt(BleHandshakePhase.idle);
    } else if (!_running && !_done) {
      unawaited(start());
    } else {
      // accepted → arrived: autostart may now apply; ask again.
      _lastReport = null;
    }
  }

  /// The driver cancels: the code it is, for this ride.
  void cancel() {
    _done = true;
    _halt(BleHandshakePhase.cancelled);
  }

  Future<void> dispose() async {
    _done = true;
    _disposed = true;
    await _stopAll();
    phase.dispose();
    countdownLeft.dispose();
    peerRssi.dispose();
    chat.dispose();
  }

  Future<BleTicket?> _fetchTicket() async {
    BleTicket t;
    try {
      t = await server.ticket();
    } catch (_) {
      return null;
    }
    if (!t.usable || !t.settings.runsOn(isAndroid: isAndroid, isIos: isIos)) return null;
    _ticket = t;
    _scheduleRefresh(t);
    return t;
  }

  /// A fresh token shortly before this one's window closes (the server still
  /// takes the last window's, so a pair seen across the boundary matches).
  void _scheduleRefresh(BleTicket t) {
    _refresh?.cancel();
    var wait = t.expiresAt!.difference(_now()) - const Duration(seconds: 5);
    if (wait < const Duration(seconds: 5)) wait = const Duration(seconds: 5);
    _refresh = Timer(wait, () async {
      if (_done || !_running) return;
      final next = await _fetchTicket();
      if (next == null) return _halt(BleHandshakePhase.idle);
      await _advertise(next);
    });
  }

  Future<bool> _advertise(BleTicket t) async {
    final why = await radio.start(tokenServiceUuid(t.token)!);
    if (why != null) {
      _unavailable = why;
      _halt(BleHandshakePhase.unavailable);
      return false;
    }
    return true;
  }

  void _onAdvert(BleAdvert a) {
    final t = _ticket;
    if (t == null || !_running) return;
    if (tokenFromServiceUuid(a.uuid) != t.peerToken?.toLowerCase()) return;
    _peerAt = _now();
    peerRssi.value = bleSmoothRssi(peerRssi.value, a.rssi);
    // The rider's phone links up to the driver's for chat (Phase D3).
    if (t.side == 'rider') unawaited(chat.value?.connectTo(a.deviceId));
    _seen = _seen.add(a.rssi, _now(), thresholdDbm: t.settings.rssiThresholdDbm);
    if (phase.value == BleHandshakePhase.searching && _seen.count > 0) phase.value = BleHandshakePhase.nearby;
  }

  void _onTick() {
    if (!_running) return;
    final now = _now();
    _seen = _seen.expire(now);
    if (_peerAt != null && now.difference(_peerAt!) > bleSightingGap) {
      _peerAt = null;
      peerRssi.value = null;
    }
    if (_seen.count == 0 && phase.value == BleHandshakePhase.nearby) phase.value = BleHandshakePhase.searching;
    if (!_seen.qualifies || _reporting || phase.value == BleHandshakePhase.countdown) return;
    if (_holdUntil != null && now.isBefore(_holdUntil!)) return;
    if (_lastReport != null && now.difference(_lastReport!) < bleReportEvery) return;
    final t = _ticket!;
    if (!_countedDown && bleNeedsCountdown(side: t.side, status: _status, settings: t.settings)) {
      _startCountdown();
      return;
    }
    unawaited(_report());
  }

  void _startCountdown() {
    phase.value = BleHandshakePhase.countdown;
    countdownLeft.value = bleCountdown.inSeconds;
    _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_running) return timer.cancel();
      countdownLeft.value -= 1;
      if (countdownLeft.value > 0) return;
      timer.cancel();
      _countedDown = true;
      phase.value = BleHandshakePhase.nearby;
      unawaited(_report());
    });
  }

  Future<void> _report() async {
    final t = _ticket;
    final rssi = _seen.averageRssi;
    if (t == null || rssi == null || _reporting) return;
    _reporting = true;
    _lastReport = _now();
    try {
      LatLng? at;
      try {
        at = await _position();
      } catch (_) {}
      final r = await server.proof(t.peerToken!, rssi, _seen.seenFor, at);
      if (!_running) return;
      switch (r) {
        case BleProofResult.started:
          _done = true;
          _halt(BleHandshakePhase.started);
        case BleProofResult.matched:
          phase.value = BleHandshakePhase.matched;
        case BleProofResult.off || BleProofResult.wrongStatus:
          _halt(BleHandshakePhase.idle);
        case BleProofResult.rateLimited:
          _holdUntil = _now().add(bleRateLimitBackoff);
        case BleProofResult.noMatch || BleProofResult.waiting:
          break;
      }
    } catch (_) {
      // A dropped connection: try again on a later tick.
    } finally {
      _reporting = false;
    }
  }

  void _halt(BleHandshakePhase to) {
    unawaited(_stopAll());
    if (!_disposed) phase.value = to;
  }

  Future<void> _stopAll() async {
    final wasRunning = _running;
    _running = false;
    _tick?.cancel();
    _refresh?.cancel();
    _countdown?.cancel();
    _tick = _refresh = _countdown = null;
    _seen = const PeerSighting();
    _peerAt = null;
    if (!_disposed) peerRssi.value = null;
    final session = chat.value;
    if (session != null) {
      if (!_disposed) chat.value = null;
      unawaited(session.stop());
    }
    final sub = _sub;
    _sub = null;
    // Bluetooth is let go first; the listener goes in its own time.
    unawaited(sub?.cancel());
    if (wasRunning) {
      try {
        await radio.stop();
      } catch (_) {}
    }
  }
}
