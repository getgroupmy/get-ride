import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ride_chat.dart' show rideVoiceNoteMax, rideVoiceNoteMin;
import '../data/voice_recorder.dart';
import '../features/support/call/mic_gate.dart';
import 'common.dart';

/// Recording a voice note from a chat's composer: asks for the microphone
/// first, counts the time, stops by itself at [rideVoiceNoteMax], and hands
/// the clip to [sendVoiceClip]. A slip of the finger shorter than
/// [rideVoiceNoteMin] is dropped rather than sent.
mixin VoiceNoteComposer<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  static const _tick = Duration(milliseconds: 250);

  VoiceRecorder? _recorder;
  Timer? _ticker;
  bool _recording = false;
  Duration _elapsed = Duration.zero;
  bool _finishing = false;

  /// Whether the composer is recording.
  bool get recording => _recording;

  /// How long it has been recording (counted by the composer's own clock).
  Duration get recordElapsed => _elapsed;

  /// Sends a finished clip.
  Future<void> sendVoiceClip(VoiceClip clip);

  Future<void> startVoiceNote() async {
    if (recording) return;
    if (!await ensureMic(context, ref, MicUse.voiceNote) || !mounted) return;
    final rec = _recorder ??= ref.read(voiceRecorderFactoryProvider)();
    try {
      if (!await rec.start()) throw StateError("Couldn't start recording.");
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    setState(() {
      _recording = true;
      _elapsed = Duration.zero;
    });
    _ticker = Timer.periodic(_tick, (_) {
      if (!mounted) return;
      setState(() => _elapsed += _tick);
      if (_elapsed >= rideVoiceNoteMax) unawaited(finishVoiceNote());
    });
  }

  Future<void> finishVoiceNote() async {
    final rec = _recorder;
    if (!recording || rec == null || _finishing) return;
    _finishing = true;
    _ticker?.cancel();
    final elapsed = _elapsed;
    setState(() => _recording = false);
    try {
      final clip = await rec.stop();
      if (!mounted) return;
      if (clip == null || elapsed < rideVoiceNoteMin) {
        showInfo(context, 'Too short. Tap the microphone, speak, then tap send.');
        return;
      }
      final d = clip.duration > rideVoiceNoteMax ? rideVoiceNoteMax : clip.duration;
      await sendVoiceClip((bytes: clip.bytes, ext: clip.ext, duration: d));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      _finishing = false;
    }
  }

  Future<void> cancelVoiceNote() async {
    if (!recording) return;
    _ticker?.cancel();
    setState(() => _recording = false);
    await _recorder?.cancel();
  }

  /// Call from dispose.
  void disposeVoiceNote() {
    _ticker?.cancel();
    final rec = _recorder;
    _recorder = null;
    if (rec != null) unawaited(rec.dispose());
  }
}
