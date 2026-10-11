// The phone's text-to-speech, and the driver's on/off for ride messages read
// aloud (lib/src/core/ride_read_aloud.dart). On by default: it is there for a
// driver who shouldn't be looking at the screen.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Says things out loud. A seam so tests can listen.
abstract class Speaker {
  Future<void> speak(String text);
  Future<void> stop();
}

class TtsSpeaker implements Speaker {
  FlutterTts? _tts;

  Future<FlutterTts> _ready() async {
    final existing = _tts;
    if (existing != null) return existing;
    final tts = FlutterTts();
    // One message after another rather than cutting each other off.
    await tts.awaitSpeakCompletion(true);
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // Spoken over the navigation app's audio, which ducks for it.
      await tts.setSharedInstance(true);
      await tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
        IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        IosTextToSpeechAudioCategoryOptions.duckOthers,
      ]);
    }
    return _tts = tts;
  }

  @override
  Future<void> speak(String text) async {
    try {
      await (await _ready()).speak(text);
    } catch (e) {
      debugPrint('[read-aloud] $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }
}

final speakerProvider = Provider<Speaker>((ref) => TtsSpeaker());

const _key = 'ride_read_aloud_v1';

/// Whether ride messages are read aloud on the driver's trip screen.
class ReadAloudSetting extends Notifier<bool> {
  @override
  bool build() {
    unawaited(_load());
    return true;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_key);
      if (saved != null) state = saved;
    } catch (_) {}
  }

  void set(bool on) {
    state = on;
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_key, on);
      } catch (_) {}
    }());
  }
}

final readAloudProvider = NotifierProvider<ReadAloudSetting, bool>(ReadAloudSetting.new);
