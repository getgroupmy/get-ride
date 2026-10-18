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
  static const _pairKey = 'gateway.key';
  static const _shareInternetKey = 'gateway.share_internet';
  static const _mobileDataOnlyKey = 'gateway.mobile_data_only';

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

  /// The device key from pairing (migration 0190): the gateway's only
  /// credential, kept until the phone is unpaired. Null: not paired.
  String? get gatewayKey => _clean(_prefs.getString(_pairKey));
  set gatewayKey(String? v) => _set(_pairKey, v);

  bool get paired => gatewayKey != null;

  /// Whether the gateway was left on, so opening the app turns it back on.
  bool get wantOnline => _prefs.getBool(_onlineKey) ?? false;
  set wantOnline(bool v) => _prefs.setBool(_onlineKey, v);

  /// Whether this phone's internet is shared with test sessions through the
  /// relay (migration 0226), while the gateway is online.
  bool get shareInternet => _prefs.getBool(_shareInternetKey) ?? false;
  set shareInternet(bool v) => _prefs.setBool(_shareInternetKey, v);

  /// Whether shared requests go out over mobile data only (the point of
  /// sharing: a real SIM's network), or the phone's default route.
  bool get mobileDataOnly => _prefs.getBool(_mobileDataOnlyKey) ?? true;
  set mobileDataOnly(bool v) => _prefs.setBool(_mobileDataOnlyKey, v);

  GatewayConfig config() => GatewayConfig(
    deviceId: deviceId,
    label: label,
    simNumber: simNumber,
    subscriptionId: subscriptionId,
    gatewayKey: gatewayKey,
    shareInternet: shareInternet,
    mobileDataOnly: mobileDataOnly,
  );

  void _set(String key, String? v) {
    final c = _clean(v);
    c == null ? _prefs.remove(key) : _prefs.setString(key, c);
  }

  static String? _clean(String? v) {
    final t = v?.trim() ?? '';
    return t.isEmpty ? null : t;
  }
}
