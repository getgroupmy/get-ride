import 'package:get_ride/src/features/support/call/mic_gate.dart';

/// The microphone in widget tests: granted unless told otherwise, and
/// switched on in Settings when [grantInSettings].
class FakeMic implements MicPermission {
  FakeMic({this.granted = true, this.grantInSettings = false, this.neverAsked = false, this.grantOnAsk = false});
  bool granted;
  final bool grantInSettings;
  int asked = 0;

  /// iOS's "never asked": [ensure] behind the call screen leaves it so,
  /// unless [grantOnAsk] (the question was answered Allow).
  bool neverAsked;
  final bool grantOnAsk;
  int settingsOpened = 0;

  @override
  Future<bool> ensure() async {
    asked++;
    if (neverAsked && grantOnAsk && asked > 1) {
      neverAsked = false;
      granted = true;
    }
    return granted;
  }

  @override
  Future<MicStatus> status() async =>
      granted ? MicStatus.granted : (neverAsked ? MicStatus.undetermined : MicStatus.denied);

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    if (grantInSettings) granted = true;
    return true;
  }
}
