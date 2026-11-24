/// Decides, frame by frame, when the face is in the pose a cue asks for.
///
/// Cues come from the server: "selfie" and "center" mean looking straight,
/// "left" and "right" mean clear head turns. The server checks only that the
/// two turns go in opposite directions (front cameras may mirror), so the SDK
/// accepts the first turn either way and requires the second to be opposite.
class PoseSteps {
  PoseSteps(this.cues, {this.straightMax = 8, this.turnMin = 25, this.hold = const Duration(milliseconds: 450)});

  final List<String> cues;
  final double straightMax; // degrees of yaw still counted as straight
  final double turnMin; // degrees of yaw counted as a turn
  final Duration hold; // the pose must be held this long

  int index = 0;
  double? _firstTurnSign;
  DateTime? _since;

  bool get done => index >= cues.length;
  String? get cue => done ? null : cues[index];

  static bool isTurn(String cue) => cue == 'left' || cue == 'right';

  /// Whether [yaw] (degrees, null = no face) satisfies the current cue.
  bool matches(double? yaw) {
    final c = cue;
    if (c == null || yaw == null) return false;
    if (!isTurn(c)) return yaw.abs() <= straightMax;
    if (yaw.abs() < turnMin) return false;
    return _firstTurnSign == null || yaw.sign != _firstTurnSign;
  }

  /// Feed one frame. True when the photo for the current cue should be taken now.
  bool feed(double? yaw, DateTime now) {
    if (!matches(yaw)) {
      _since = null;
      return false;
    }
    _since ??= now;
    return now.difference(_since!) >= hold;
  }

  /// The photo for the current cue was taken with this yaw (null if taken by hand).
  void captured(double? yaw) {
    final c = cue;
    if (c != null && isTurn(c) && yaw != null && yaw.abs() >= turnMin) _firstTurnSign ??= yaw.sign;
    index++;
    _since = null;
  }
}
