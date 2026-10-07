import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// The audio half of a support call: the microphone, the peer connection
/// and the speaker. An interface so the call logic is tested without a
/// microphone or a network ([CallSession] only ever talks to this).
abstract class CallMedia {
  /// Opens the microphone and a peer connection over [iceServers].
  /// [onIce] is called with each local candidate to send to the other side;
  /// [onConnected] whenever audio starts or stops flowing.
  Future<void> open(
    List<Map<String, dynamic>> iceServers, {
    required void Function(Map<String, dynamic> candidate) onIce,
    required void Function(bool connected) onConnected,
  });

  /// The caller's offer.
  Future<Map<String, dynamic>> createOffer();

  /// Takes the caller's [offer] and returns the answer to send back.
  Future<Map<String, dynamic>> acceptOffer(Map<String, dynamic> offer);

  /// Takes the answer to the offer this side made.
  Future<void> acceptAnswer(Map<String, dynamic> answer);

  Future<void> addIce(Map<String, dynamic> candidate);
  Future<void> setMuted(bool muted);
  Future<void> setSpeaker(bool on);
  Future<void> close();
}

/// [CallMedia] over flutter_webrtc: voice only, echo cancellation and noise
/// suppression on.
class WebrtcCallMedia implements CallMedia {
  RTCPeerConnection? _pc;
  MediaStream? _local;
  // The web plays remote audio through a media element; native platforms
  // route it to the earpiece/speaker by themselves.
  RTCVideoRenderer? _webAudio;

  @override
  Future<void> open(
    List<Map<String, dynamic>> iceServers, {
    required void Function(Map<String, dynamic> candidate) onIce,
    required void Function(bool connected) onConnected,
  }) async {
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': false,
    });
    final pc = await createPeerConnection({'iceServers': iceServers, 'sdpSemantics': 'unified-plan'});
    _pc = pc;
    for (final t in _local!.getAudioTracks()) {
      await pc.addTrack(t, _local!);
    }
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      onIce({'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
    };
    pc.onConnectionState = (s) => onConnected(s == RTCPeerConnectionState.RTCPeerConnectionStateConnected);
    if (kIsWeb) {
      final r = RTCVideoRenderer();
      await r.initialize();
      _webAudio = r;
      pc.onTrack = (e) {
        if (e.streams.isNotEmpty) r.srcObject = e.streams.first;
      };
    }
  }

  RTCPeerConnection get _peer {
    final pc = _pc;
    if (pc == null) throw StateError('Call media is not open');
    return pc;
  }

  static Map<String, dynamic> _sdp(RTCSessionDescription d) => {'sdp': d.sdp, 'type': d.type};
  static RTCSessionDescription _desc(Map<String, dynamic> m) =>
      RTCSessionDescription(m['sdp'] as String?, m['type'] as String?);

  @override
  Future<Map<String, dynamic>> createOffer() async {
    final offer = await _peer.createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': false});
    await _peer.setLocalDescription(offer);
    return _sdp(offer);
  }

  @override
  Future<Map<String, dynamic>> acceptOffer(Map<String, dynamic> offer) async {
    await _peer.setRemoteDescription(_desc(offer));
    final answer = await _peer.createAnswer({'offerToReceiveAudio': true, 'offerToReceiveVideo': false});
    await _peer.setLocalDescription(answer);
    return _sdp(answer);
  }

  @override
  Future<void> acceptAnswer(Map<String, dynamic> answer) => _peer.setRemoteDescription(_desc(answer));

  @override
  Future<void> addIce(Map<String, dynamic> c) => _peer.addCandidate(
    RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, (c['sdpMLineIndex'] as num?)?.toInt()),
  );

  @override
  Future<void> setMuted(bool muted) async {
    for (final t in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
  }

  @override
  Future<void> setSpeaker(bool on) async {
    if (kIsWeb) return;
    if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
      await Helper.setSpeakerphoneOn(on);
    }
  }

  @override
  Future<void> close() async {
    for (final t in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _local?.dispose();
    await _pc?.close();
    _webAudio?.srcObject = null;
    await _webAudio?.dispose();
    _local = null;
    _pc = null;
    _webAudio = null;
  }
}
