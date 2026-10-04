/// Pure helpers behind the session & location history screen. Ports of
/// `expo/utils/deviceLinkage.ts`, `expo/utils/deviceGuard.ts` (the pure half),
/// `expo/utils/mobileOperator.ts` and the summarising/filtering done inline in
/// `expo/app/admin-session-history.tsx`.
library;

// ---- Device linkage (utils/deviceLinkage.ts) --------------------------------

class SessionIdentity {
  const SessionIdentity({this.userId, this.phone, this.deviceId});
  final String? userId;
  final String? phone;
  final String? deviceId;
}

/// Stable account key: the user id, else `phone:<phone>`, else null.
String? accountKey({String? userId, String? phone}) {
  if (userId != null && userId.isNotEmpty) return userId;
  if (phone != null && phone.isNotEmpty) return 'phone:$phone';
  return null;
}

class AccountLink {
  const AccountLink({required this.linkedAccounts, required this.sharedDevices});

  /// Other accounts seen on at least one device this account also used.
  final List<String> linkedAccounts;

  /// This account's devices that another account also used.
  final List<String> sharedDevices;
}

/// Accounts linked to at least one other account by a shared `device_id`.
/// Presence in the returned map means "flagged".
Map<String, AccountLink> computeDeviceLinks(Iterable<SessionIdentity> sessions) {
  final accountsByDevice = <String, Set<String>>{};
  final devicesByAccount = <String, Set<String>>{};
  for (final s in sessions) {
    final device = s.deviceId;
    if (device == null || device.isEmpty) continue;
    final acct = accountKey(userId: s.userId, phone: s.phone);
    if (acct == null) continue;
    accountsByDevice.putIfAbsent(device, () => <String>{}).add(acct);
    devicesByAccount.putIfAbsent(acct, () => <String>{}).add(device);
  }
  final result = <String, AccountLink>{};
  devicesByAccount.forEach((acct, devices) {
    final linked = <String>{};
    final shared = <String>{};
    for (final device in devices) {
      final accts = accountsByDevice[device];
      if (accts == null || accts.length < 2) continue;
      shared.add(device);
      linked.addAll(accts.where((a) => a != acct));
    }
    if (linked.isNotEmpty) {
      result[acct] = AccountLink(
        linkedAccounts: linked.toList()..sort(),
        sharedDevices: shared.toList()..sort(),
      );
    }
  });
  return result;
}

// ---- Duplicate-account guard (utils/deviceGuard.ts, pure half) -------------

const defaultMaxAccountsPerDevice = 3;

class DeviceGuardConfig {
  const DeviceGuardConfig({required this.enabled, required this.maxAccountsPerDevice, required this.blockEmulators});

  static const fallback =
      DeviceGuardConfig(enabled: true, maxAccountsPerDevice: defaultMaxAccountsPerDevice, blockEmulators: false);

  /// Parses the `device_guard_config()` RPC result (a row or a one-row list).
  factory DeviceGuardConfig.fromRpc(Object? data) {
    final row = data is List ? (data.isEmpty ? null : data.first) : data;
    if (row is! Map) return fallback;
    final max = num.tryParse('${row['max_accounts'] ?? ''}')?.toInt() ?? 0;
    return DeviceGuardConfig(
      enabled: row['enabled'] != false,
      maxAccountsPerDevice: max == 0 ? defaultMaxAccountsPerDevice : max,
      blockEmulators: row['block_emulators'] == true,
    );
  }

  final bool enabled;
  final int maxAccountsPerDevice;
  final bool blockEmulators;

  DeviceGuardConfig copyWith({bool? enabled, int? maxAccountsPerDevice, bool? blockEmulators}) => DeviceGuardConfig(
        enabled: enabled ?? this.enabled,
        maxAccountsPerDevice: maxAccountsPerDevice ?? this.maxAccountsPerDevice,
        blockEmulators: blockEmulators ?? this.blockEmulators,
      );

  /// Arguments for `device_guard_set_config` (the limit is clamped to ≥ 1).
  Map<String, dynamic> toRpcParams() => {
        'p_enabled': enabled,
        'p_max_accounts': maxAccountsPerDevice < 1 ? 1 : maxAccountsPerDevice,
        'p_block_emulators': blockEmulators,
      };
}

/// Local policy fallback; non-positive / non-finite counts always allow.
bool isRegistrationAllowed(num priorAccounts, [int max = defaultMaxAccountsPerDevice]) {
  if (!priorAccounts.isFinite || priorAccounts <= 0) return true;
  return priorAccounts < max;
}

/// Parses the server's `DEVICE_LIMIT:<prior>/<max>` error.
({int priorAccounts, int maxAccounts})? parseDeviceLimitError(String? message) {
  if (message == null) return null;
  final m = RegExp(r'DEVICE_LIMIT:(\d+)/(\d+)').firstMatch(message);
  if (m == null) return null;
  return (priorAccounts: int.parse(m.group(1)!), maxAccounts: int.parse(m.group(2)!));
}

String _errMessage(Object? err) => switch (err) {
      String s => s,
      Exception e => e.toString(),
      Error e => e.toString(),
      _ => '',
    };

bool isDeviceLimitError(Object? err) => parseDeviceLimitError(_errMessage(err)) != null;
bool isEmulatorBlockedError(Object? err) => _errMessage(err).contains('EMULATOR_BLOCKED');
bool isRegistrationBlockedError(Object? err) => isDeviceLimitError(err) || isEmulatorBlockedError(err);

// ---- Mobile operator (utils/mobileOperator.ts) -----------------------------

const iosCarrierPlaceholder = '--';
const iosMobileCodePlaceholder = '65535';

String? normalizeMobileCode(String? raw) {
  if (raw == null) return null;
  final t = raw.trim();
  if (t.isEmpty || t == iosMobileCodePlaceholder) return null;
  if (!RegExp(r'^\d{1,6}$').hasMatch(t)) return null;
  return t;
}

/// "MCC-MNC" (e.g. "502-12"), whichever half is genuine, or null.
String? formatPlmn(String? mcc, String? mnc) {
  final m = normalizeMobileCode(mcc);
  final n = normalizeMobileCode(mnc);
  if (m != null && n != null) return '$m-$n';
  return m ?? n;
}

String? normalizeCarrierName(String? raw) {
  if (raw == null) return null;
  final t = raw.trim();
  if (t.isEmpty || t == iosCarrierPlaceholder) return null;
  return t;
}

String? resolveMobileOperator({String? carrierName, String? connectionType, String? ispProvider, String? ispOrg}) {
  final carrier = normalizeCarrierName(carrierName);
  if (carrier != null) return carrier;
  if (connectionType == 'mobile') {
    final p = (ispProvider ?? '').trim();
    final isp = p.isNotEmpty ? p : (ispOrg ?? '').trim();
    if (isp.isNotEmpty) return isp;
  }
  return null;
}

// ---- CSV ---------------------------------------------------------------------

String csvEscape(Object? v) {
  if (v == null) return '';
  final s = '$v';
  if (RegExp(r'[",\n\r]').hasMatch(s)) return '"${s.replaceAll('"', '""')}"';
  return s;
}

String rowsToCsv(List<Map<String, dynamic>> rows, List<String> columns) {
  final header = columns.map(csvEscape).join(',');
  final body = rows.map((r) => columns.map((c) => csvEscape(r[c])).join(',')).join('\n');
  return '$header\n$body';
}

const allSessionCsvColumns = [
  'captured_at', 'event_type', 'user_id', 'phone', 'device_id', 'os_name', 'os_version', 'device_brand',
  'device_manufacturer', 'device_model_name', 'device_model_id', 'device_type', 'is_physical_device',
  'network_type', 'network_operator', 'network_is_connected', 'network_is_internet_reachable', 'ip_address',
  'public_ip', 'connection_type', 'isp_provider', 'isp_org', 'ip_city', 'ip_region', 'ip_country', 'iccid',
  'mobile_operator_name', 'mobile_country_code', 'mobile_network_code', 'cellular_generation', 'app_version',
  'app_build_version', 'app_id', 'id',
];

const userSessionCsvColumns = [
  'captured_at', 'event_type', 'device_id', 'os_name', 'os_version', 'device_brand', 'device_model_name',
  'device_model_id', 'network_type', 'network_operator', 'ip_address', 'public_ip', 'connection_type',
  'isp_provider', 'isp_org', 'ip_city', 'ip_region', 'ip_country', 'iccid', 'mobile_operator_name',
  'mobile_country_code', 'mobile_network_code', 'cellular_generation', 'app_version', 'app_build_version', 'id',
];

const locationCsvColumns = [
  'captured_at', 'latitude', 'longitude', 'accuracy', 'altitude', 'heading', 'speed', 'session_id', 'device_id', 'id',
];

// ---- Summaries --------------------------------------------------------------

String? _str(Object? v) => v == null || '$v'.isEmpty ? null : '$v';
DateTime? _time(Object? v) => v == null ? null : DateTime.tryParse('$v');
double? _num(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');

/// Key used to group rows by account in the list (falls back to the row id
/// for anonymous sessions, exactly like the Expo screen).
String rowAccountKey(Map<String, dynamic> r) =>
    accountKey(userId: _str(r['user_id']), phone: _str(r['phone'])) ?? 'anon:${r['id']}';

String? _osLabel(Map<String, dynamic> s) {
  final os = _str(s['os_name']);
  if (os == null) return null;
  final v = _str(s['os_version']);
  return v == null ? os : '$os $v';
}

class UserSummary {
  UserSummary({required this.key, this.userId, this.phone, required this.lastSeen, this.lastDevice, this.lastOs, this.lastIsp});

  final String key;
  final String? userId;
  final String? phone;
  String lastSeen;
  int sessionCount = 1;
  String? lastDevice;
  String? lastOs;
  String? lastIsp;
  double? lastLat;
  double? lastLng;
  String? lastPingAt;
}

/// Groups `user_sessions` rows by account, newest first, and attaches each
/// account's latest `user_location_history` ping. [pings] must be sorted
/// newest first (as loaded).
List<UserSummary> summarizeUsers(List<Map<String, dynamic>> sessions, List<Map<String, dynamic>> pings) {
  final map = <String, UserSummary>{};
  for (final s in sessions) {
    final key = rowAccountKey(s);
    final existing = map[key];
    if (existing == null) {
      map[key] = UserSummary(
        key: key,
        userId: _str(s['user_id']),
        phone: _str(s['phone']),
        lastSeen: '${s['captured_at']}',
        lastDevice: _str(s['device_model_name']),
        lastOs: _osLabel(s),
        lastIsp: _str(s['isp_provider']),
      );
    } else {
      existing.sessionCount += 1;
      final t = _time(s['captured_at']);
      final prev = _time(existing.lastSeen);
      if (t != null && (prev == null || t.isAfter(prev))) {
        existing.lastSeen = '${s['captured_at']}';
        existing.lastDevice = _str(s['device_model_name']);
        existing.lastOs = _osLabel(s);
        existing.lastIsp = _str(s['isp_provider']);
      }
    }
  }
  final latestPing = <String, Map<String, dynamic>>{};
  for (final l in pings) {
    final key = accountKey(userId: _str(l['user_id']), phone: _str(l['phone']));
    if (key == null) continue;
    latestPing.putIfAbsent(key, () => l);
  }
  for (final u in map.values) {
    final p = latestPing[u.key];
    if (p != null) {
      u.lastLat = _num(p['latitude']);
      u.lastLng = _num(p['longitude']);
      u.lastPingAt = _str(p['captured_at']);
    }
  }
  final list = map.values.toList();
  list.sort((a, b) {
    final ta = _time(a.lastSeen)?.millisecondsSinceEpoch ?? 0;
    final tb = _time(b.lastSeen)?.millisecondsSinceEpoch ?? 0;
    return tb.compareTo(ta);
  });
  return list;
}

/// Accounts with at least one session from a non-physical device.
Set<String> emulatorAccounts(List<Map<String, dynamic>> sessions) => {
      for (final s in sessions)
        if (s['is_physical_device'] == false) ?accountKey(userId: _str(s['user_id']), phone: _str(s['phone'])),
    };

List<SessionIdentity> identitiesOf(List<Map<String, dynamic>> sessions) => [
      for (final s in sessions)
        SessionIdentity(userId: _str(s['user_id']), phone: _str(s['phone']), deviceId: _str(s['device_id'])),
    ];

/// Human label for an account key (phone, short uid, or the raw key).
String accountLabel(String key, List<UserSummary> users) {
  for (final u in users) {
    if (u.key != key) continue;
    if (u.phone != null) return u.phone!;
    if (u.userId != null) return 'uid ${u.userId!.substring(0, u.userId!.length < 8 ? u.userId!.length : 8)}…';
  }
  return key.startsWith('phone:') ? key.substring(6) : key;
}

bool matchesUserQuery(UserSummary u, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return [u.phone, u.userId, u.lastDevice, u.lastOs].any((v) => (v ?? '').toLowerCase().contains(q));
}

// ---- Date filters -----------------------------------------------------------

DateTime? _day(String ymd) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(ymd.trim());
  if (m == null) return null;
  return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

/// Local-time [from 00:00, to 23:59:59.999] bounds for `YYYY-MM-DD` inputs;
/// empty/invalid inputs leave that side open.
({DateTime? from, DateTime? to}) dayRange(String from, String to) {
  final f = _day(from);
  final t = _day(to);
  return (from: f, to: t?.add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1)));
}

bool inDayRange(Object? iso, ({DateTime? from, DateTime? to}) range) {
  final t = _time(iso)?.toLocal();
  if (t == null) return true;
  if (range.from != null && t.isBefore(range.from!)) return false;
  if (range.to != null && t.isAfter(range.to!)) return false;
  return true;
}

String ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

enum TrailScope { today, yesterday, range }

/// The window a trail query covers, or an error message for the range form.
({DateTime start, DateTime end})? trailWindow(TrailScope scope, DateTime now,
    {String rangeFrom = '', String rangeTo = '', void Function(String error)? onError}) {
  switch (scope) {
    case TrailScope.today:
      return (start: DateTime(now.year, now.month, now.day), end: now);
    case TrailScope.yesterday:
      final d = DateTime(now.year, now.month, now.day - 1);
      return (start: d, end: DateTime(d.year, d.month, d.day, 23, 59, 59, 999));
    case TrailScope.range:
      if (rangeFrom.trim().isEmpty || rangeTo.trim().isEmpty) {
        onError?.call('Choose both a start and end date.');
        return null;
      }
      final r = dayRange(rangeFrom, rangeTo);
      if (r.from == null || r.to == null || r.from!.isAfter(r.to!)) {
        onError?.call('Check the date range values.');
        return null;
      }
      return (start: r.from!, end: r.to!);
  }
}

int _minutesOf(String hhmm) {
  final parts = hhmm.split(':');
  final h = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0;
  final m = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
  return h * 60 + m;
}

/// Keeps pings whose local time of day is inside [from, to] (`HH:MM`),
/// wrapping past midnight when from > to.
List<Map<String, dynamic>> filterByTimeOfDay(List<Map<String, dynamic>> rows, String from, String to) {
  final f = _minutesOf(from);
  final t = _minutesOf(to);
  return rows.where((l) {
    final d = _time(l['captured_at'])?.toLocal();
    if (d == null) return false;
    final mins = d.hour * 60 + d.minute;
    return f <= t ? mins >= f && mins <= t : mins >= f || mins <= t;
  }).toList();
}

/// Every `stride`-th item so at most [max] remain (heatmap sampling).
List<T> sampleEvenly<T>(List<T> items, int max) {
  if (items.length <= max) return items;
  final stride = (items.length / max).ceil();
  return [for (var i = 0; i < items.length; i += stride) items[i]];
}

/// Newest-first pings → oldest-first coordinates, capped at [max] points.
List<({double lat, double lng})> trailCoordinates(List<Map<String, dynamic>> newestFirst, {int max = 400}) {
  final total = newestFirst.length;
  if (total < 2) return const [];
  final stride = total > max ? (total / max).ceil() : 1;
  final out = <({double lat, double lng})>[];
  for (var i = total - 1; i >= 0; i -= stride) {
    final lat = _num(newestFirst[i]['latitude']);
    final lng = _num(newestFirst[i]['longitude']);
    if (lat != null && lng != null) out.add((lat: lat, lng: lng));
  }
  return out;
}
