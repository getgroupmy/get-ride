import 'dart:async';
import 'dart:typed_data';

import 'package:get_ride/src/data/voice_recorder.dart';
import 'package:get_ride/src/widgets/voice_note.dart';

/// The recorder in widget tests: hands back [clip] (or nothing) on stop.
class FakeRecorder implements VoiceRecorder {
  FakeRecorder({this.clip});
  VoiceClip? clip;
  int started = 0, stopped = 0, cancelled = 0;
  bool disposed = false;

  @override
  Future<bool> start() async {
    started++;
    return true;
  }

  @override
  Future<VoiceClip?> stop() async {
    stopped++;
    return clip;
  }

  @override
  Future<void> cancel() async => cancelled++;

  @override
  Future<void> dispose() async => disposed = true;
}

/// A clip of [seconds] seconds.
VoiceClip fakeClip(int seconds) => (bytes: Uint8List(1200), ext: 'm4a', duration: Duration(seconds: seconds));

/// The player in widget tests: records what it was asked to play.
class FakePlayback implements VoicePlayback {
  final played = <String>[];
  final _pos = StreamController<Duration>.broadcast();
  final _len = StreamController<Duration>.broadcast();
  final _done = StreamController<void>.broadcast();
  int paused = 0;

  @override
  Stream<Duration> get position => _pos.stream;
  @override
  Stream<Duration> get duration => _len.stream;
  @override
  Stream<void> get completed => _done.stream;
  @override
  Future<void> play(String url) async => played.add(url);
  @override
  Future<void> pause() async => paused++;
  @override
  Future<void> resume() async {}
  @override
  Future<void> dispose() async {
    await _pos.close();
    await _len.close();
    await _done.close();
  }

  void at(Duration d) => _pos.add(d);
  void finish() => _done.add(null);
}
