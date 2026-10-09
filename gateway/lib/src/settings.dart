// What this phone remembers about being a gateway.
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'engine.dart';

class GatewaySettings {
  GatewaySettings._(this._prefs);

  static Future<GatewaySettings> load() async => GatewaySettings._(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  static const _deviceKey = 'gateway.device_id';
  static const _labelKey = 'gateway.label';
  static const _simNumberKey = 'gateway.sim_number';
  static const _subscriptionKey = 'gateway.subscription_id';
  static const _onlineKey = 'gateway.online';

  /// This install's id, made once; the server keys the device row on it.
  String get deviceId {
    var id = _prefs.getString(_deviceKey);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      _prefs.setString(_deviceKey, id);
    }
    return id;
  }

  String? get label => _clean(_prefs.getString(_labelKey));
  set label(String? v) => _set(_labelKey, v);

  /// The SIM's number as the admin page shows it (Android often cannot read
  /// it, so the person setting the phone up types it).
  String? get simNumber => _clean(_prefs.getString(_simNumberKey));
  set simNumber(String? v) => _set(_simNumberKey, v);

  /// The SIM that sends; null is the phone's default SMS SIM.
  int? get subscriptionId => _prefs.getInt(_subscriptionKey);
  set subscriptionId(int? v) => v == null ? _prefs.remove(_subscriptionKey) : _prefs.setInt(_subscriptionKey, v);

  /// Whether the gateway was left on, so opening the app turns it back on.
  bool get wantOnline => _prefs.getBool(_onlineKey) ?? false;
  set wantOnline(bool v) => _prefs.setBool(_onlineKey, v);

  GatewayConfig config() =>
      GatewayConfig(deviceId: deviceId, label: label, simNumber: simNumber, subscriptionId: subscriptionId);

  void _set(String key, String? v) {
    final c = _clean(v);
    c == null ? _prefs.remove(key) : _prefs.setString(key, c);
  }

  static String? _clean(String? v) {
    final t = v?.trim() ?? '';
    return t.isEmpty ? null : t;
  }
}
