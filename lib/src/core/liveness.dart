// Whether the face in front of the camera is a live person: asked to blink,
// or to turn their head, while the camera is open (widgets/live_selfie.dart).
// The phone's face detector (ML Kit) hands in what it sees frame by frame;
// this decides. Pure, so it is tested without a camera. Where the phone has no
// detector (the web, desktops) the selfie is taken plain and recorded as
// 'not_checked', for the admin to see.
library;

import 'dart:math';

/// What the person is asked to do.
enum LiveChallenge {
  blink('Blink slowly', 'blink'),
  turn('Turn your head to one side', 'turn');

  const LiveChallenge(this.prompt, this.detail);

  final String prompt;

  /// What the server keeps (identity_checks.liveness_detail).
  final String detail;

  static LiveChallenge pick([Random? random]) => values[(random ?? Random()).nextInt(values.length)];
}

/// One frame's faces, as the detector saw them.
class FaceSample {
  const FaceSample({this.faces = 1, this.leftEyeOpen, this.rightEyeOpen, this.yaw, this.width = 0.5});

  final int faces;

  /// 0 (shut) to 1 (open); null when the detector can't tell.
  final double? leftEyeOpen;
  final double? rightEyeOpen;

  /// Head turn left or right, in degrees.
  final double? yaw;

  /// The face's width as a share of the frame's.
  final double width;
}

/// The camera's state, for the words under it.
enum LiveHint { noFace, manyFaces, closer, lookStraight, doIt, done }

/// Follows the frames until the challenge is done: a blink is eyes open,
/// then shut, then open again; a turn is the head straight, then turned.
class LivenessTracker {
  LivenessTracker(this.challenge);

  final LiveChallenge challenge;

  static const openAt = 0.7;
  static const shutAt = 0.25;
  static const straightWithin = 12.0;
  static const turnedPast = 25.0;
  static const minWidth = 0.2;

  var _ready = false;
  var _shut = false;
  var _passed = false;
  LiveHint _hint = LiveHint.noFace;

  bool get passed => _passed;
  LiveHint get hint => _hint;

  /// Feeds one frame; true once the challenge is done.
  bool feed(FaceSample s) {
    if (_passed) return true;
    if (s.faces == 0) return _say(LiveHint.noFace, reset: true);
    if (s.faces > 1) return _say(LiveHint.manyFaces, reset: true);
    if (s.width < minWidth) return _say(LiveHint.closer);
    switch (challenge) {
      case LiveChallenge.blink:
        final l = s.leftEyeOpen, r = s.rightEyeOpen;
        if (l == null || r == null) return _say(LiveHint.lookStraight);
        if (!_ready) {
          if (l >= openAt && r >= openAt) _ready = true;
          return _say(_ready ? LiveHint.doIt : LiveHint.lookStraight);
        }
        if (!_shut) {
          if (l <= shutAt && r <= shutAt) _shut = true;
          return _say(LiveHint.doIt);
        }
        if (l >= openAt && r >= openAt) _passed = true;
      case LiveChallenge.turn:
        final y = s.yaw;
        if (y == null) return _say(LiveHint.lookStraight);
        if (!_ready) {
          if (y.abs() <= straightWithin) _ready = true;
          return _say(_ready ? LiveHint.doIt : LiveHint.lookStraight);
        }
        if (y.abs() >= turnedPast) _passed = true;
    }
    return _say(_passed ? LiveHint.done : LiveHint.doIt);
  }

  bool _say(LiveHint h, {bool reset = false}) {
    if (reset) {
      _ready = false;
      _shut = false;
    }
    _hint = h;
    return _passed;
  }

  /// The words under the camera.
  String get text => switch (_hint) {
    LiveHint.noFace => 'Put your face in the circle',
    LiveHint.manyFaces => 'Only you in the picture, please',
    LiveHint.closer => 'Come a little closer',
    LiveHint.lookStraight => 'Look straight at the camera',
    LiveHint.doIt => challenge.prompt,
    LiveHint.done => 'Hold still',
  };
}
