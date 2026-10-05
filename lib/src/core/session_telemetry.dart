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
}

/// The device and app, as far as the platform tells (no native plugin).
class DeviceSnapshot {
  const DeviceSnapshot({required this.osName, this.osVersion, required this.deviceType, this.appVersion});

  /// `android`, `ios`, `web`, `macos`, `windows` or `linux`.
  final String osName;
  final String? osVersion;

  /// `phone` / `desktop` / `browser`, from the platform.
  final String deviceType;
  final String? appVersion;
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
}) => {
  'id': id,
  'user_id': userId,
  'phone': phone,
  'event_type': event.value,
  'device_id': deviceId,
  'os_name': device.osName,
  'os_version': device.osVersion,
  'device_type': device.deviceType,
  'app_version': device.appVersion,
  'app_id': 'com.taxxee.teksi',
  'public_ip': ip?.publicIp,
  'isp_provider': ip?.ispProvider,
  'isp_org': ip?.ispOrg,
  'ip_city': ip?.city,
  'ip_region': ip?.region,
  'ip_country': ip?.country,
  'raw': {'client': 'flutter', 'platform': device.osName},
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
