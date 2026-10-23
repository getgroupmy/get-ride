// Admin → User, Partner and God View: the Phone card. Each phone an account
// signed in on, from its `user_sessions` rows (session_telemetry.dart: the
// columns, and `raw`, which holds DeviceDetails.extra) and its `push_tokens`
// rows, newest first. Pure, so the grouping and the words are tested without
// a database.
library;

import 'dart:convert';

import 'app_permissions.dart' show PermState;
import 'app_version.dart';
import 'call_ring.dart' show voipPlatform;

/// The `raw` keys the app writes for the card (data/device_details.dart),
/// next to the older `screen`, `pixel_ratio`, `locale` and `utc_offset_min`.
abstract final class PhoneExtra {
  static const batteryPct = 'battery_pct';
  static const batteryCharging = 'battery_charging';
  static const storageFree = 'storage_free_bytes';
  static const storageTotal = 'storage_total_bytes';
  static const location = 'perm_location';
  static const locationServiceOn = 'location_service_on';
  static const notifications = 'perm_notifications';

  /// The phone's push device key (push_logic.dart `pushDeviceKey`), which
  /// ties the row to its `push_tokens` row.
  static const pushKey = 'push_device_key';
}

/// Under this the battery reads Low.
const phoneLowBatteryPct = 20;

/// What the app may do with location, as the phone answered.
enum PhoneLocationAccess {
  always('always', 'Always'),
  whileInUse('while_in_use', 'While using the app'),
  off('denied', 'Off'),
  unknown('unknown', 'Not known');

  const PhoneLocationAccess(this.value, this.label);

  /// What `raw.perm_location` holds.
  final String value;
  final String label;

  static PhoneLocationAccess parse(Object? v) =>
      values.firstWhere((a) => a.value == v, orElse: () => PhoneLocationAccess.unknown);

  /// The permission probe's answer (data/permission_probe.dart), as stored:
  /// Android's "not asked" is a refusal it may still ask again, so off.
  static PhoneLocationAccess ofPermState(PermState s) => switch (s) {
    PermState.granted => PhoneLocationAccess.always,
    PermState.limited => PhoneLocationAccess.whileInUse,
    PermState.denied || PermState.notAsked => PhoneLocationAccess.off,
    PermState.unknown => PhoneLocationAccess.unknown,
  };
}

/// Whether notifications reach the phone, from the probe's answer; null
/// when it can't tell (no push on this build).
bool? phoneNotificationsAllowed(PermState s) => switch (s) {
  PermState.granted || PermState.limited => true,
  PermState.denied || PermState.notAsked => false,
  PermState.unknown => null,
};

/// The installed app against Admin → Settings → App Version.
enum PhoneAppStatus { latest, behind, unknown }

String? _str(Object? v) {
  final s = v is String ? v.trim() : (v == null ? '' : '$v'.trim());
  return s.isEmpty || s == 'null' ? null : s;
}

int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

bool? _bool(Object? v) => v is bool ? v : (v == 'true' ? true : (v == 'false' ? false : null));

DateTime? _time(Object? v) => DateTime.tryParse('${v ?? ''}')?.toUtc();

Map<String, dynamic> _raw(Object? v) {
  if (v is Map) return Map<String, dynamic>.from(v);
  if (v is String && v.trim().startsWith('{')) {
    try {
      return Map<String, dynamic>.from(jsonDecode(v) as Map);
    } catch (_) {}
  }
  return const {};
}

String _capitalise(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// One phone, as of its newest report.
class PhoneDetails {
  const PhoneDetails({
    required this.key,
    this.platform,
    this.brand,
    this.modelName,
    this.modelId,
    this.osVersion,
    this.isPhysical,
    this.screen,
    this.pixelRatio,
    this.storageFree,
    this.storageTotal,
    this.locale,
    this.utcOffsetMin,
    this.appVersion,
    this.appBuild,
    this.location = PhoneLocationAccess.unknown,
    this.locationServiceOn,
    this.backgroundTracking,
    this.notifications,
    this.reportedAt,
    this.lastSeen,
    this.firstSeen,
    this.batteryPct,
    this.batteryCharging,
    this.networkType,
    this.cellularGeneration,
    this.networkOperator,
    this.simOperator,
    this.ipCity,
    this.ipRegion,
    this.ipCountry,
    this.reports = 1,
  });

  /// The session rows' `device_id`, else the platform and model.
  final String key;

  /// `ios`, `android`, `web`… (`user_sessions.os_name`).
  final String? platform;
  final String? brand;
  final String? modelName;
  final String? modelId;
  final String? osVersion;
  final bool? isPhysical;

  /// "1179x2556", in pixels, and the pixels to a point.
  final String? screen;
  final double? pixelRatio;
  final int? storageFree;
  final int? storageTotal;
  final String? locale;
  final int? utcOffsetMin;
  final String? appVersion;
  final String? appBuild;
  final PhoneLocationAccess location;

  /// False when the phone's location is switched off altogether.
  final bool? locationServiceOn;

  /// Always on reporting (`push_tokens.location_always`), when a push token
  /// is known for the phone.
  final bool? backgroundTracking;
  final bool? notifications;

  /// The newest report: the battery and the network are as of then.
  final DateTime? reportedAt;

  /// The newest report or background position, whichever is later.
  final DateTime? lastSeen;

  /// The oldest report read.
  final DateTime? firstSeen;
  final int? batteryPct;
  final bool? batteryCharging;
  final String? networkType;
  final String? cellularGeneration;
  final String? networkOperator;
  final String? simOperator;
  final String? ipCity;
  final String? ipRegion;
  final String? ipCountry;

  /// How many of the rows read came from this phone.
  final int reports;

  /// "iPhone 15 Pro", for its tab.
  String get tabLabel => modelName ?? modelId ?? (platform == null ? 'Phone' : _platformName(platform!));

  /// "Apple iPhone 15 Pro", "Samsung SM-A546E".
  String get modelLine {
    final b = brand == null ? null : _capitalise(brand!);
    final m = modelName ?? modelId;
    if (m == null) return b ?? 'Not known';
    if (b == null || m.toLowerCase().startsWith(b.toLowerCase())) return m;
    return '$b $m';
  }

  /// The hardware code when it says more than the name ("iPhone16,1").
  String? get modelCode => modelId != null && modelId != modelName ? modelId : null;

  /// "iOS 18.6", "Android 15 (SDK 35)".
  String get systemLabel => osVersion ?? (platform == null ? 'Not known' : _platformName(platform!));

  String get physicalLabel => switch (isPhysical) {
    true => 'Yes',
    false => 'No, an emulator',
    null => 'Not known',
  };

  /// "393 × 852 · 3×": the size in points and the pixels to a point.
  String? get screenLabel {
    final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(screen ?? '');
    if (m == null) return null;
    final w = int.parse(m.group(1)!), h = int.parse(m.group(2)!);
    final r = pixelRatio;
    if (r == null || r <= 0) return '$w × $h px';
    final ratio = r == r.roundToDouble() ? '${r.round()}' : r.toStringAsFixed(1);
    return '${(w / r).round()} × ${(h / r).round()} · $ratio×';
  }

  /// "38 GB free of 128 GB".
  String? get storageLabel {
    final f = storageFree, t = storageTotal;
    if (f == null) return t == null ? null : '${phoneBytesLabel(t)} in all';
    return t == null ? '${phoneBytesLabel(f)} free' : '${phoneBytesLabel(f)} free of ${phoneBytesLabel(t)}';
  }

  /// "en-MY · GMT+8".
  String? get languageLabel {
    final parts = [?locale, if (utcOffsetMin case final o?) phoneGmtLabel(o)];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// "1.5.2 (412)".
  String? get appLabel {
    final v = appVersion;
    if (v == null) return null;
    return appBuild == null || appBuild == v ? v : '$v ($appBuild)';
  }

  /// "Off (location switched off)" when the phone's location is off.
  String get locationLabel =>
      locationServiceOn == false ? 'Off (location switched off)' : location.label;

  /// Whether the location needs changing for a driver: anything but Always.
  bool get locationNeedsAlways =>
      locationServiceOn == false || (location != PhoneLocationAccess.always && location != PhoneLocationAccess.unknown);

  /// "62%", "14% · charging".
  String? get batteryLabel {
    final p = batteryPct;
    if (p == null) return batteryCharging == true ? 'Charging' : null;
    return batteryCharging == true ? '$p% · charging' : '$p%';
  }

  bool get batteryLow => batteryPct != null && batteryPct! < phoneLowBatteryPct;

  /// "Mobile data · 5G", "Wi-Fi".
  String? get networkLabel => switch (networkType) {
    null => null,
    'wifi' => 'Wi-Fi',
    'cellular' => cellularGeneration == null ? 'Mobile data' : 'Mobile data · $cellularGeneration',
    'ethernet' => 'Ethernet',
    'vpn' => 'VPN',
    'bluetooth' => 'Bluetooth',
    'none' => 'No connection',
    final o => _capitalise(o),
  };

  /// The network the phone is on, else the SIM's ("Maxis (SIM)").
  String? get operatorLabel {
    final n = networkOperator, s = simOperator;
    if (n == null) return s == null ? null : '$s (SIM)';
    return s == null || s.toLowerCase() == n.toLowerCase() ? n : '$n (SIM: $s)';
  }

  /// "Kajang, Selangor, MY".
  String? get ipAreaLabel {
    final parts = [?ipCity, ?ipRegion, ?ipCountry];
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// God View's one line: "Apple iPhone 15 Pro · iOS 18.6".
  String get summaryLine => '$modelLine · $systemLabel';

  /// God View's network line: "Mobile data · 5G · CelcomDigi".
  String? get networkSummary {
    final parts = [?networkLabel, ?operatorLabel];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// The installed app against the admin's [rules] (the same rule the app
  /// itself follows, [resolveUpdate]); unknown without a version or a rule
  /// for its platform.
  PhoneAppStatus appStatus(List<AppVersionRule> rules) {
    final v = appVersion;
    final p = rulePlatform(platform ?? '');
    if (v == null || parseVersion(v) == null || p == 'web') return PhoneAppStatus.unknown;
    if (!rules.any((r) => rulePlatform(r.platform) == p || rulePlatform(r.platform) == 'all')) {
      return PhoneAppStatus.unknown;
    }
    return resolveUpdate(rules, platform: p, current: v).kind == UpdateKind.none
        ? PhoneAppStatus.latest
        : PhoneAppStatus.behind;
  }
}

String _platformName(String p) => switch (p.toLowerCase()) {
  'ios' => 'iPhone',
  'android' => 'Android phone',
  'web' => 'Browser',
  'macos' => 'Mac',
  'windows' => 'Windows PC',
  final o => _capitalise(o),
};

/// "38 GB", "4.2 GB", "820 MB" (as phones count them, 1000 to the next).
String phoneBytesLabel(int bytes) {
  final gb = bytes / 1e9;
  if (gb >= 10) return '${gb.round()} GB';
  if (gb >= 1) {
    final s = gb.toStringAsFixed(1);
    return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s} GB';
  }
  return '${(bytes / 1e6).round()} MB';
}

/// "GMT+8", "GMT+5:30", "GMT-3", "GMT".
String phoneGmtLabel(int offsetMin) {
  if (offsetMin == 0) return 'GMT';
  final sign = offsetMin < 0 ? '-' : '+';
  final m = offsetMin.abs();
  final h = m ~/ 60, rest = m % 60;
  return rest == 0 ? 'GMT$sign$h' : 'GMT$sign$h:${rest.toString().padLeft(2, '0')}';
}

/// The tab names for [phones]: a second phone of the same model gets "(2)".
List<String> phoneTabLabels(List<PhoneDetails> phones) {
  final seen = <String, int>{};
  return [
    for (final p in phones)
      () {
        final n = seen.update(p.tabLabel, (c) => c + 1, ifAbsent: () => 1);
        return n == 1 ? p.tabLabel : '${p.tabLabel} ($n)';
      }(),
  ];
}

/// Which phone a session row came from: its `device_id`, else its platform
/// and model.
String phoneKeyOf(Map<String, dynamic> row) =>
    _str(row['device_id']) ??
    '${_str(row['os_name']) ?? '?'}|${_str(row['device_model_name']) ?? _str(row['device_model_id']) ?? '?'}';

/// The account's phones from its newest [sessions] rows and its
/// [tokens] (`push_tokens`), newest first. A token goes to the phone whose
/// rows carry its device key, else to the newest phone of its platform
/// still without one; VoIP tokens are left out (the same phone's ordinary
/// token speaks for it). Hardware fields come from the newest row that has
/// them; the app, battery, network and permissions from the newest row
/// only, since an older row's would be stale.
List<PhoneDetails> phonesFrom(List<Map<String, dynamic>> sessions, List<Map<String, dynamic>> tokens) {
  final rows = [...sessions]
    ..sort((a, b) => (_time(b['captured_at']) ?? DateTime(0)).compareTo(_time(a['captured_at']) ?? DateTime(0)));
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final r in rows) {
    groups.putIfAbsent(phoneKeyOf(r), () => []).add(r);
  }
  final left = [
    for (final t in tokens)
      if (_str(t['platform']) != voipPlatform) t,
  ]..sort((a, b) => (_time(b['updated_at']) ?? DateTime(0)).compareTo(_time(a['updated_at']) ?? DateTime(0)));

  final tokenFor = <String, Map<String, dynamic>>{};
  for (final e in groups.entries) {
    final keys = {for (final r in e.value) ?_str(_raw(r['raw'])[PhoneExtra.pushKey])};
    final i = left.indexWhere((t) => keys.contains(_str(t['device_key'])));
    if (i >= 0) tokenFor[e.key] = left.removeAt(i);
  }
  for (final e in groups.entries) {
    if (tokenFor.containsKey(e.key)) continue;
    final platform = _str(e.value.first['os_name'])?.toLowerCase();
    if (platform != 'ios' && platform != 'android') continue;
    final i = left.indexWhere((t) => _str(t['platform'])?.toLowerCase() == platform);
    if (i >= 0) tokenFor[e.key] = left.removeAt(i);
  }

  return [
    for (final e in groups.entries) _phone(e.key, e.value, tokenFor[e.key]),
  ];
}

PhoneDetails _phone(String key, List<Map<String, dynamic>> rows, Map<String, dynamic>? token) {
  final newest = rows.first;
  final raw = _raw(newest['raw']);
  T? first<T>(T? Function(Map<String, dynamic> r) f) {
    for (final r in rows) {
      final v = f(r);
      if (v != null) return v;
    }
    return null;
  }

  final reportedAt = _time(newest['captured_at']);
  final located = _time(token?['located_at']);
  final lastSeen = located != null && (reportedAt == null || located.isAfter(reportedAt)) ? located : reportedAt;
  var location = PhoneLocationAccess.parse(raw[PhoneExtra.location]);
  final always = _bool(token?['location_always']);
  if (location == PhoneLocationAccess.unknown && always == true) location = PhoneLocationAccess.always;
  final ratio = first((r) => _raw(r['raw'])['pixel_ratio']);
  return PhoneDetails(
    key: key,
    platform: _str(newest['os_name'])?.toLowerCase(),
    brand: first((r) => _str(r['device_brand']) ?? _str(r['device_manufacturer'])),
    modelName: first((r) => _str(r['device_model_name'])),
    modelId: first((r) => _str(r['device_model_id'])),
    osVersion: _str(newest['os_version']),
    isPhysical: first((r) => _bool(r['is_physical_device'])),
    screen: first((r) => _str(_raw(r['raw'])['screen'])),
    pixelRatio: ratio is num ? ratio.toDouble() : double.tryParse('${ratio ?? ''}'),
    storageFree: _int(raw[PhoneExtra.storageFree]),
    storageTotal: _int(raw[PhoneExtra.storageTotal]),
    locale: _str(raw['locale']),
    utcOffsetMin: _int(raw['utc_offset_min']),
    appVersion: _str(newest['app_version']),
    appBuild: _str(newest['app_build_version']) ?? _str(raw['app_build']),
    location: location,
    locationServiceOn: _bool(raw[PhoneExtra.locationServiceOn]),
    backgroundTracking: always,
    notifications: _bool(raw[PhoneExtra.notifications]),
    reportedAt: reportedAt,
    lastSeen: lastSeen,
    firstSeen: _time(rows.last['captured_at']),
    batteryPct: switch (_int(raw[PhoneExtra.batteryPct])) {
      final p? when p >= 0 && p <= 100 => p,
      _ => null,
    },
    batteryCharging: _bool(raw[PhoneExtra.batteryCharging]),
    networkType: _str(newest['network_type']) ?? _str(newest['connection_type']),
    cellularGeneration: _str(newest['cellular_generation']),
    networkOperator: _str(newest['network_operator']),
    simOperator: _str(newest['mobile_operator_name']),
    ipCity: _str(newest['ip_city']),
    ipRegion: _str(newest['ip_region']),
    ipCountry: _str(newest['ip_country']),
    reports: rows.length,
  );
}
