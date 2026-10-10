import 'package:get_ride/src/features/support/call/mic_gate.dart';

/// The microphone in widget tests: granted unless told otherwise, and
/// switched on in Settings when [grantInSettings].
class FakeMic implements MicPermission {
  FakeMic({this.granted = true, this.grantInSettings = false});
  bool granted;
  final bool grantInSettings;
  int asked = 0;
  int settingsOpened = 0;

  @override
  Future<bool> ensure() async {
    asked++;
    return granted;
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    if (grantInSettings) granted = true;
    return true;
  }
}
