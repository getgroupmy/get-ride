// The looping alert the partner hears when a ride request is spotlighted
// (the Expo request modal), like the big ride apps. It rings over the phone's
// silent switch and keeps going while the screen is locked, for at most the
// admin's Ride offers length (OfferSettings.alertSoundSeconds), and is always
// cut short the moment the request is answered, skipped or its spotlight ends.
import 'dart:async';

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Rings the incoming-request alert. Overridden in tests with a silent one.
abstract class OfferAlertSound {
  /// Starts the loop, for at most [max]; a zero or negative [max] rings
  /// nothing. Calling it again restarts the ring from the top.
  Future<void> start(Duration max);

  /// Stops at once.
  Future<void> stop();

  /// Frees the player.
  Future<void> dispose();
}

/// Where the bundled sound lives (audioplayers prepends `assets/`).
const offerAlertAsset = 'sounds/incoming_offer.mp3';

class _DeviceOfferAlertSound implements OfferAlertSound {
  final _p = ap.AudioPlayer();
  Timer? _cap;
  bool _primed = false;

  Future<void> _prime() async {
    if (_primed) return;
    await _p.setReleaseMode(ap.ReleaseMode.loop);
    // Ring even on silent, and keep ringing while the phone is locked — a
    // driver must hear the request whatever the ringer switch is doing.
    await _p.setAudioContext(ap.AudioContextConfig(respectSilence: false, stayAwake: true).build());
    _primed = true;
  }

  @override
  Future<void> start(Duration max) async {
    _cap?.cancel();
    _cap = null;
    if (max <= Duration.zero) {
      await stop();
      return;
    }
    try {
      await _prime();
      await _p.stop();
      await _p.play(ap.AssetSource(offerAlertAsset), volume: 1);
      _cap = Timer(max, () => unawaited(stop()));
    } catch (_) {
      // A build without the asset, or audio refused: the request still pops
      // up and buzzes, it just doesn't ring.
    }
  }

  @override
  Future<void> stop() async {
    _cap?.cancel();
    _cap = null;
    try {
      await _p.stop();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    _cap?.cancel();
    _cap = null;
    try {
      await _p.dispose();
    } catch (_) {}
  }
}

/// A ring that does nothing — the web/desktop builds and tests.
class SilentOfferAlertSound implements OfferAlertSound {
  const SilentOfferAlertSound();
  @override
  Future<void> start(Duration max) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

/// The partner screen's ringer; one per app. Overridden in tests. Web and
/// desktop get the silent one (audioplayers' asset ring is a phone feature).
final offerAlertSoundProvider = Provider<OfferAlertSound>((ref) {
  final mobile = !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
  final sound = mobile ? _DeviceOfferAlertSound() : const SilentOfferAlertSound();
  ref.onDispose(sound.dispose);
  return sound;
});

/// How long the ring may play for a spotlight that lasts [spotlight], given
/// the admin's [alertSoundSeconds] (0 = off). Pure, so it is tested: the ring
/// never outlasts the spotlight, and 0 is silence.
Duration offerAlertRingFor({required int alertSoundSeconds, required Duration spotlight}) {
  if (alertSoundSeconds <= 0 || spotlight <= Duration.zero) return Duration.zero;
  final asked = Duration(seconds: alertSoundSeconds);
  return asked < spotlight ? asked : spotlight;
}
