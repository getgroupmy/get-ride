// Turns the gateway back on by itself when it was left on. Runs from main(),
// not from a screen: Android may start the app with no screen at all (after
// a restart, an update, or ending the app), and the service asks again each
// time it is restarted ([SmsPlatform.onResume]).
import 'engine.dart';
import 'permissions.dart';
import 'settings.dart';
import 'sms_platform.dart';

class GatewayKeeper {
  GatewayKeeper({
    required this.engine,
    required this.settings,
    required this.platform,
    required this.permissions,
    required this.signedIn,
  });

  final GatewayEngine engine;
  final GatewaySettings settings;
  final SmsPlatform platform;
  final GatewayPermissions permissions;

  /// Whether this phone is paired (has its device key). The engine itself
  /// stops, saying why, if the server no longer knows the key.
  final bool Function() signedIn;

  /// Starts the gateway if it was left on and can run; otherwise takes down
  /// a notification the service put up without it.
  Future<void> resume() async {
    if (engine.running) return;
    if (settings.wantOnline && signedIn() && await _smsGranted()) {
      await engine.start();
      return;
    }
    if (engine.running) return;
    try {
      await platform.stopService();
    } catch (_) {}
  }

  Future<bool> _smsGranted() async {
    try {
      return await permissions.granted(GatewayPermission.sms);
    } catch (_) {
      return false;
    }
  }
}
