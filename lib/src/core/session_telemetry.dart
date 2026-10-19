/// Session and location telemetry (Expo `contexts/SessionTrackingContext.tsx`).
///
/// One `user_sessions` row per launch, sign-in and return to the app, with the
/// device, the app and the public IP / ISP resolved server-side by the
/// `ip-lookup` edge function; and, while signed in, a `user_location_history`
/// row at least every 30 s, or sooner after moving 10 m. These feed the admin
/// Session History and fraud screens. Every write is best-effort.
library;

/// The kind of session row (`user_sessions.event_type`).
enum SessionEvent {
  appLaunch('app_launch'),
  login('login'),
  appRelaunch('app_relaunch');

  const SessionEvent(this.value);
  final String value;
}

/// Heartbeat: a location row at least this often while signed in.
const locationPingInterval = Duration(seconds: 30);

/// Movement that justifies a row before the heartbeat is due.
const locationMoveMeters = 10.0;

/// Never two movement rows closer than this.
const locationMinGap = Duration(seconds: 5);

/// Whether a location row is due: the heartbeat has lapsed, or the phone has
/// moved and the last row is not too recent.
bool locationRowDue({DateTime? lastWrite, required DateTime now, double? movedMeters}) {
  if (lastWrite == null) return true;
  final since = now.difference(lastWrite);
  if (since >= locationPingInterval) return true;
  return movedMeters != null && movedMeters >= locationMoveMeters && since >= locationMinGap;
}

/// What `ip-lookup` answers.
class IpInfo {
  const IpInfo({this.publicIp, this.ispProvider, this.ispOrg, this.city, this.region, this.country});

  final String? publicIp;
  final String? ispProvider;
  final String? ispOrg;
  final String? city;
  final String? region;
  final String? country;

  static IpInfo? fromResponse(Object? data) {
    if (data is! Map) return null;
    String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    final info = IpInfo(
      publicIp: s(data['public_ip']),
      ispProvider: s(data['isp_provider']),
      ispOrg: s(data['isp_org']),
      city: s(data['ip_city']),
      region: s(data['ip_region']),
      country: s(data['ip_country']),
    );
    return info.publicIp == null && info.ispProvider == null ? null : info;
  }

  /// The `user_sessions` columns it fills.
  Map<String, dynamic> get columns => {
    'public_ip': publicIp,
    'isp_provider': ispProvider,
    'isp_org': ispOrg,
    'ip_city': city,
    'ip_region': region,
    'ip_country': country,
  };
}

/// The `ip-lookup` request for the caller's address alone (no ISP).
const ipOnlyBody = <String, dynamic>{'ip_only': true};

/// The `ip-lookup` answer, looked up once per launch and shared: every
/// session row of the launch reuses it. The device blacklist check only needs
/// the address, so it asks for that alone ([publicIp], `ip_only`: no rate
/// check and no ISP lookup on the server) instead of waiting for the full
/// answer; the full one fills the session rows when it comes. A failed or
/// empty lookup is tried again by the next caller.
class LaunchIpCache {
  Future<IpInfo?>? _inFlight;
  Future<String?>? _ipInFlight;
  String? _ip;

  /// The answer, once one came back.
  IpInfo? value;

  /// The public address as far as known: the full answer's, or the
  /// address-only one's.
  String? get knownIp => value?.publicIp ?? _ip;

  /// The public address, asked once per launch with [lookupIp] unless the
  /// full answer (or an earlier address-only one) already has it.
  Future<String?> publicIp(Future<String?> Function() lookupIp) {
    final known = knownIp;
    if (known != null) return Future.value(known);
    return _ipInFlight ??= Future.sync(lookupIp)
        .then((ip) {
          if (ip != null) _ip = ip;
          return value?.publicIp ?? ip;
        })
        .whenComplete(() => _ipInFlight = null);
  }

  Future<IpInfo?> get(Future<IpInfo?> Function() lookup) {
    final known = value;
    if (known != null) return Future.value(known);
    return _inFlight ??= Future.sync(lookup)
        .then((ip) {
          value = ip;
          return ip;
        })
        .whenComplete(() => _inFlight = null);
  }
}

/// This launch's [LaunchIpCache].
final launchIp = LaunchIpCache();

/// The device and app, as far as the platform tells (no native plugin).
class DeviceSnapshot {
  const DeviceSnapshot({
    required this.osName,
    this.osVersion,
    required this.deviceType,
    this.appVersion,
    this.appBuild,
  });

  /// `android`, `ios`, `web`, `macos`, `windows` or `linux`.
  final String osName;
  final String? osVersion;

  /// `phone` / `desktop` / `browser`, from the platform.
  final String deviceType;
  final String? appVersion;

  /// The build number (`+1` in pubspec), when the platform gives one.
  final String? appBuild;
}

/// What the phone tells about itself and its connection at the moment of an
/// event, without asking for any permission: make and model, the network
/// and the SIM's operator, the local IP. Anything the platform keeps back
/// stays null.
class DeviceDetails {
  const DeviceDetails({
    this.osVersion,
    this.brand,
    this.manufacturer,
    this.modelName,
    this.modelId,
    this.isPhysical,
    this.networkType,
    this.isConnected,
    this.internetReachable,
    this.networkOperator,
    this.mobileOperator,
    this.mobileCountryCode,
    this.mobileNetworkCode,
    this.cellularGeneration,
    this.localIp,
    this.extra = const {},
  });

  /// "Android 14 (SDK 34)", "iOS 18.1": better than the platform's own string.
  final String? osVersion;
  final String? brand;
  final String? manufacturer;

  /// "Galaxy A54" / "iPhone"; [modelId] the hardware code ("SM-A546E", "iPhone15,2").
  final String? modelName;
  final String? modelId;
  final bool? isPhysical;

  /// `wifi`, `cellular`, `ethernet`, `vpn`, `bluetooth`, `other` or `none`.
  final String? networkType;
  final bool? isConnected;
  final bool? internetReachable;

  /// The network the phone is on ("CelcomDigi"), and the SIM's operator.
  final String? networkOperator;
  final String? mobileOperator;
  final String? mobileCountryCode;
  final String? mobileNetworkCode;

  /// `2G` … `5G`, where the platform tells it.
  final String? cellularGeneration;
  final String? localIp;

  /// Everything else worth keeping (SIM country, metered, screen, locale…).
  final Map<String, Object?> extra;

  /// The `user_sessions` columns these fill (nulls left out).
  Map<String, Object?> get columns => {
    'device_brand': ?brand,
    'device_manufacturer': ?manufacturer,
    'device_model_name': ?modelName,
    'device_model_id': ?modelId,
    'is_physical_device': ?isPhysical,
    'network_type': ?networkType,
    'connection_type': ?networkType,
    'network_is_connected': ?isConnected,
    'network_is_internet_reachable': ?internetReachable,
    'network_operator': ?networkOperator,
    'mobile_operator_name': ?mobileOperator,
    'mobile_country_code': ?mobileCountryCode,
    'mobile_network_code': ?mobileNetworkCode,
    'cellular_generation': ?cellularGeneration,
    'ip_address': ?localIp,
  };
}

/// "50219" (an operator code) as its country and network codes; null for
/// anything shorter. Pure.
(String, String)? splitOperatorCode(String? code) {
  final c = code?.trim() ?? '';
  if (c.length < 5 || int.tryParse(c) == null) return null;
  return (c.substring(0, 3), c.substring(3));
}

/// iOS's radio technology (`CTRadioAccessTechnologyLTE`) as a generation;
/// null for anything else. Pure.
String? cellularGenerationOf(String? radio) {
  final r = (radio ?? '').replaceFirst('CTRadioAccessTechnology', '');
  if (r.isEmpty) return null;
  if (r.startsWith('NR')) return '5G';
  if (r == 'LTE') return '4G';
  if (const {'WCDMA', 'HSDPA', 'HSUPA', 'eHRPD', 'CDMAEVDORev0', 'CDMAEVDORevA', 'CDMAEVDORevB'}.contains(r)) {
    return '3G';
  }
  if (const {'GPRS', 'Edge', 'CDMA1x'}.contains(r)) return '2G';
  return null;
}

/// A name the platform gives, or null for a blank or placeholder ("--",
/// what iOS 16+ answers for the carrier). Pure.
String? cleanDeviceText(Object? v) {
  if (v is! String) return null;
  final s = v.trim();
  return s.isEmpty || s == '--' || s == 'unknown' || s == '65535' ? null : s;
}

/// The `user_sessions` row for one event.
Map<String, dynamic> sessionRow({
  required String id,
  required SessionEvent event,
  required String deviceId,
  required DeviceSnapshot device,
  String? userId,
  String? phone,
  IpInfo? ip,
  DeviceDetails? details,
}) => {
  ...?details?.columns,
  'id': id,
  'user_id': userId,
  'phone': phone,
  'event_type': event.value,
  'device_id': deviceId,
  'os_name': device.osName,
  'os_version': details?.osVersion ?? device.osVersion,
  'device_type': device.deviceType,
  'app_version': device.appVersion,
  'app_build_version': ?device.appBuild,
  'app_id': 'com.taxxee.teksi',
  ...(ip ?? const IpInfo()).columns,
  'raw': {'client': 'flutter', 'platform': device.osName, 'app_build': ?device.appBuild, ...?details?.extra},
};

/// The `user_location_history` row for one fix.
Map<String, dynamic> locationRow({
  required double latitude,
  required double longitude,
  required String deviceId,
  String? userId,
  String? phone,
  String? sessionId,
  double? accuracy,
  double? altitude,
  double? heading,
  double? speed,
}) => {
  'user_id': userId,
  'phone': phone,
  'session_id': sessionId,
  'device_id': deviceId,
  'latitude': latitude,
  'longitude': longitude,
  'accuracy': accuracy,
  'altitude': altitude,
  'heading': heading,
  'speed': speed,
};

/// The column a PostgREST "missing column" error names, so the insert can be
/// retried without it on a database behind on migrations (Expo does the same).
String? missingColumn(String message) => RegExp(r"Could not find the '([^']+)' column").firstMatch(message)?.group(1);

/// One position reading, as written to `user_location_history`.
class TelemetryFix {
  const TelemetryFix({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.altitude,
    this.heading,
    this.speed,
  });

  final double latitude;
  final double longitude;
  final double? accuracy;
  final double? altitude;
  final double? heading;
  final double? speed;
}
