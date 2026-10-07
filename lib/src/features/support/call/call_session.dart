import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/support_call.dart';
import '../../../data/support_call_repository.dart';
import 'call_media.dart';

/// Makes the audio for a call. Overridden in tests.
final callMediaFactoryProvider = Provider<CallMedia Function()>((_) => WebrtcCallMedia.new);

/// The clock a call is timed on. Overridden in tests.
final callClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// One end of a support call: follows the call's row, carries the WebRTC
/// setup over the signals table, and drives [CallMedia].
///
/// Whoever rang makes the offer once the other side has answered; the side
/// that answered replies to it. ICE candidates go both ways as they turn up,
/// held back until the other side's description is in. The call ends for
/// both when either hangs up (the row's status), and the caller gives up on
/// it after [callRingTimeout] of ringing.
class CallSession extends ChangeNotifier {
  CallSession({
    required this.repo,
    required this.media,
    required this.me,
    required SupportCall call,
    DateTime Function()? clock,
    this.connectTimeout = callConnectTimeout,
  }) : _clock = clock ?? DateTime.now {
    _call = call;
  }

  final SupportCallRepository repo;
  final CallMedia media;

  /// The signed-in account on this end.
  final String me;
  final DateTime Function() _clock;

  /// How long an answered call may take to connect ([callConnectTimeout]).
  final Duration connectTimeout;

  late SupportCall _call;
  SupportCall get call => _call;
  bool get outgoing => _call.startedBy(me);
  CallStatus get status => _call.status;

  bool _connected = false;
  bool get connected => _connected;
  DateTime? _connectedAt;

  bool _muted = false;
  bool get muted => _muted;
  bool _speaker = false;
  bool get speaker => _speaker;

  /// Set when the microphone or the connection could not be opened.
  String? error;

  bool get isOver => status.isOver || _closed;

  /// How long the call has been connected.
  Duration get elapsed {
    final from = _connectedAt ?? _call.startedAt;
    return from == null ? Duration.zero : _clock().difference(from);
  }

  StreamSubscription<SupportCall>? _rowSub;
  StreamSubscription<CallSignal>? _signalSub;
  Timer? _ringTimer;
  Timer? _connectTimer;
  bool _mediaOpen = false;
  bool _offered = false;
  bool _remoteSet = false;
  bool _closed = false;
  final _pendingIce = <Map<String, dynamic>>[];

  /// Starts this end: opens the microphone, then follows the row and the
  /// signals. A failure to open the microphone hangs up.
  Future<void> start() async {
    _rowSub = repo.watch(_call.id).listen(_onRow, onError: (Object _) {});
    try {
      final ice = await repo.iceServers();
      if (_closed) return;
      await media.open(ice, onIce: _sendIce, onConnected: _onConnected);
      _mediaOpen = true;
    } catch (e) {
      error = "Couldn't use the microphone. Check that GET.ride may use it, then try again.";
      await hangUp();
      return;
    }
    if (_closed) return;
    _signalSub = repo.watchSignals(_call.id).listen(_onSignal, onError: (Object _) {});
    if (outgoing && status == CallStatus.ringing) {
      final created = _call.createdAt ?? _clock();
      final left = callRingTimeout - _clock().difference(created);
      _ringTimer = Timer(left.isNegative ? Duration.zero : left, () {
        if (status == CallStatus.ringing) unawaited(_finish(CallStatus.missed));
      });
    }
    _armConnectTimeout();
    await _maybeOffer();
  }

  void _onRow(SupportCall c) {
    if (_closed) return;
    _call = c;
    _notify();
    if (c.status.isOver) {
      unawaited(_teardown());
    } else {
      _armConnectTimeout();
      unawaited(_maybeOffer());
    }
  }

  /// Gives up on an answered call whose audio never starts.
  void _armConnectTimeout() {
    if (status != CallStatus.accepted || _connected || _connectTimer != null || !_mediaOpen) return;
    _connectTimer = Timer(connectTimeout, () {
      if (_connected || _closed) return;
      error = "Couldn't connect the call audio. Please try again.";
      unawaited(hangUp());
    });
  }

  Future<void> _maybeOffer() async {
    if (!outgoing || _offered || !_mediaOpen || status != CallStatus.accepted || _closed) return;
    _offered = true;
    _ringTimer?.cancel();
    final offer = await media.createOffer();
    await repo.sendSignal(_call.id, 'offer', offer);
  }

  Future<void> _onSignal(CallSignal s) async {
    if (s.sender == me || _closed) return;
    switch (s.kind) {
      case 'offer' when !outgoing:
        final answer = await media.acceptOffer(s.payload);
        await _remoteReady();
        await repo.sendSignal(_call.id, 'answer', answer);
      case 'answer' when outgoing:
        await media.acceptAnswer(s.payload);
        await _remoteReady();
      case 'ice':
        if (_remoteSet) {
          await media.addIce(s.payload);
        } else {
          _pendingIce.add(s.payload);
        }
      case 'bye':
        await _teardown();
    }
  }

  Future<void> _remoteReady() async {
    _remoteSet = true;
    final queued = [..._pendingIce];
    _pendingIce.clear();
    for (final c in queued) {
      await media.addIce(c);
    }
  }

  void _sendIce(Map<String, dynamic> candidate) {
    if (_closed) return;
    unawaited(repo.sendSignal(_call.id, 'ice', candidate).catchError((Object _) {}));
  }

  void _onConnected(bool on) {
    if (_closed || on == _connected) return;
    _connected = on;
    if (on) _connectedAt ??= _clock();
    _notify();
  }

  Future<void> toggleMute() async {
    _muted = !_muted;
    _notify();
    await media.setMuted(_muted);
  }

  Future<void> toggleSpeaker() async {
    _speaker = !_speaker;
    _notify();
    await media.setSpeaker(_speaker);
  }

  /// Hangs up: an unanswered incoming call is declined, anything else ended.
  Future<void> hangUp() => _finish(status == CallStatus.ringing && !outgoing ? CallStatus.declined : CallStatus.ended);

  Future<void> _finish(CallStatus to) async {
    if (!status.isOver) {
      _call = SupportCall({..._call.raw, 'status': to.name});
      _notify();
      try {
        await repo.finish(_call.id, to);
      } catch (_) {}
    }
    await _teardown();
  }

  Future<void> _teardown() async {
    if (_closed) return;
    _closed = true;
    _ringTimer?.cancel();
    _connectTimer?.cancel();
    _connected = false;
    unawaited(_rowSub?.cancel());
    unawaited(_signalSub?.cancel());
    if (_mediaOpen) {
      _mediaOpen = false;
      try {
        await media.close();
      } catch (_) {}
    }
    _notify();
  }

  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_teardown());
    super.dispose();
  }
}
