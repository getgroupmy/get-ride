import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// A finished voice note: the file's bytes, its extension and how long it is.
typedef VoiceClip = ({Uint8List bytes, String ext, Duration duration});

/// Records voice notes for the chats. The microphone permission is asked for
/// before [start] (see `ensureMic`).
abstract class VoiceRecorder {
  /// Starts recording; false when it couldn't.
  Future<bool> start();

  /// Stops and hands back the clip, or null when nothing was recorded.
  Future<VoiceClip?> stop();

  /// Stops and throws the recording away.
  Future<void> cancel();

  Future<void> dispose();
}

class _DeviceRecorder implements VoiceRecorder {
  AudioRecorder? _rec;
  DateTime? _startedAt;
  String _ext = 'm4a';

  @override
  Future<bool> start() async {
    final rec = _rec ??= AudioRecorder();
    // AAC in an .m4a plays everywhere; a browser without it records Opus or,
    // last, WAV.
    var encoder = AudioEncoder.aacLc;
    _ext = 'm4a';
    if (kIsWeb && !await rec.isEncoderSupported(AudioEncoder.aacLc)) {
      if (await rec.isEncoderSupported(AudioEncoder.opus)) {
        encoder = AudioEncoder.opus;
        _ext = 'webm';
      } else {
        encoder = AudioEncoder.wav;
        _ext = 'wav';
      }
    }
    final path = kIsWeb
        ? ''
        : '${(await getTemporaryDirectory()).path}/voice-${DateTime.now().millisecondsSinceEpoch}.$_ext';
    await rec.start(RecordConfig(encoder: encoder, bitRate: 64000, sampleRate: 44100, numChannels: 1), path: path);
    _startedAt = DateTime.now();
    return true;
  }

  @override
  Future<VoiceClip?> stop() async {
    final rec = _rec;
    final started = _startedAt;
    _startedAt = null;
    if (rec == null || started == null) return null;
    final duration = DateTime.now().difference(started);
    final out = await rec.stop();
    if (out == null || out.isEmpty) return null;
    final Uint8List bytes;
    if (kIsWeb) {
      // The browser hands back a blob: link to the recording.
      bytes = (await http.get(Uri.parse(out))).bodyBytes;
    } else {
      final f = File(out);
      bytes = await f.readAsBytes();
      unawaited(f.delete().then((_) {}, onError: (_) {}));
    }
    if (bytes.isEmpty) return null;
    return (bytes: bytes, ext: _ext, duration: duration);
  }

  @override
  Future<void> cancel() async {
    _startedAt = null;
    try {
      await _rec?.cancel();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    final rec = _rec;
    _rec = null;
    if (rec == null) return;
    try {
      await rec.cancel();
    } catch (_) {}
    await rec.dispose();
  }
}

/// A new recorder for each screen that records (overridden in tests).
final voiceRecorderFactoryProvider = Provider<VoiceRecorder Function()>((ref) => _DeviceRecorder.new);
