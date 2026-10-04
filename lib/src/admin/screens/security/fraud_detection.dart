/// Pure fraud-signal detection — a port of `expo/utils/fraudDetection.ts`.
///
/// Every `detect*` function scans plain rows (as returned by a Supabase
/// `select`) and returns findings; nothing here touches the network.
library;

import 'dart:math' as math;

enum FraudSeverity { low, medium, high }

enum FraudCategory {
  multiDeviceAccount('multi_device_account', 'Multi-device account'),
  sharedDevice('shared_device', 'Shared device'),
  ipCluster('ip_cluster', 'IP cluster'),
  locationMismatch('location_mismatch', 'Fake pickup/drop-off'),
  implausibleTrip('implausible_trip', 'Implausible trip'),
  collusionPair('collusion_pair', 'Fake bookings / collusion'),
  excessiveCancellations('excessive_cancellations', 'Excessive cancellations'),
  promotionAbuse('promotion_abuse', 'Promotion / incentive abuse');

  const FraudCategory(this.id, this.label);
  final String id;
  final String label;
}

class FraudFinding {
  const FraudFinding({
    required this.id,
    required this.category,
    required this.severity,
    required this.title,
    required this.description,
    required this.subjects,
    required this.evidence,
  });

  final String id;
  final FraudCategory category;
  final FraudSeverity severity;
  final String title;
  final String description;

  /// Account keys / ride ids / device ids implicated, for drill-down.
  final List<String> subjects;
  final Map<String, Object?> evidence;
}

class SessionSignal {
  const SessionSignal({this.userId, this.phone, this.deviceId, this.publicIp, this.capturedAt = ''});

  factory SessionSignal.fromRow(Map<String, dynamic> r) => SessionSignal(
        userId: _s(r['user_id']),
        phone: _s(r['phone']),
        deviceId: _s(r['device_id']),
        publicIp: _s(r['public_ip']),
        capturedAt: '${r['captured_at'] ?? ''}',
      );

  final String? userId;
  final String? phone;
  final String? deviceId;
  final String? publicIp;
  final String capturedAt;
}

class RideSignal {
  const RideSignal({
    required this.id,
    this.riderId,
    this.partnerId,
    required this.status,
    this.distanceKm,
    this.durationMin,
    this.fare,
    this.pickupLat,
    this.pickupLng,
    this.dropLat,
    this.dropLng,
    this.partnerArriveLat,
    this.partnerArriveLng,
    this.partnerDropLat,
    this.partnerDropLng,
    this.userDropLat,
    this.userDropLng,
    this.cancelledAt,
  });

  factory RideSignal.fromRow(Map<String, dynamic> r) => RideSignal(
        id: '${r['id']}',
        riderId: _s(r['rider_id']),
        partnerId: _s(r['partner_id']),
        status: '${r['status'] ?? ''}',
        distanceKm: _d(r['distance_km']),
        durationMin: _d(r['duration_min']),
        fare: _d(r['fare']),
        pickupLat: _d(r['pickup_lat']),
        pickupLng: _d(r['pickup_lng']),
        dropLat: _d(r['drop_lat']),
        dropLng: _d(r['drop_lng']),
        partnerArriveLat: _d(r['partner_arrive_lat']),
        partnerArriveLng: _d(r['partner_arrive_lng']),
        partnerDropLat: _d(r['partner_drop_lat']),
        partnerDropLng: _d(r['partner_drop_lng']),
        userDropLat: _d(r['user_drop_lat']),
        userDropLng: _d(r['user_drop_lng']),
        cancelledAt: _s(r['cancelled_at']),
      );

  final String id;
  final String? riderId;
  final String? partnerId;
  final String status;
  final double? distanceKm;
  final double? durationMin;
  final double? fare;
  final double? pickupLat, pickupLng, dropLat, dropLng;
  final double? partnerArriveLat, partnerArriveLng, partnerDropLat, partnerDropLng;
  final double? userDropLat, userDropLng;
  final String? cancelledAt;
}

class WalletTxSignal {
  const WalletTxSignal({required this.id, required this.userId, required this.kind, required this.amount});

  factory WalletTxSignal.fromRow(Map<String, dynamic> r) => WalletTxSignal(
        id: '${r['id']}',
        userId: '${r['user_id']}',
        kind: '${r['kind'] ?? ''}',
        amount: _d(r['amount']) ?? 0,
      );

  final String id;
  final String userId;
  final String kind;
  final double amount;
}

class TransferSignal {
  const TransferSignal({required this.id, required this.fromUserId, required this.toUserId, required this.coins, required this.status});

  factory TransferSignal.fromRow(Map<String, dynamic> r) => TransferSignal(
        id: '${r['id']}',
        fromUserId: '${r['from_user_id']}',
        toUserId: '${r['to_user_id']}',
        coins: _d(r['coins']) ?? 0,
        status: '${r['status'] ?? ''}',
      );

  final String id;
  final String fromUserId;
  final String toUserId;
  final double coins;
  final String status;
}

String? _s(Object? v) => v == null || '$v'.isEmpty ? null : '$v';
double? _d(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');

double haversineKm(double lat1, double lng1, double lat2, double lng2) {
  double rad(double v) => v * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
  return 6371 * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// Fraud account key: `uid:<id>` else `phone:<phone>` (note: differs from the
/// session screen's key, as in Expo).
String? _accountKey(String? userId, String? phone) {
  if (userId != null) return 'uid:$userId';
  if (phone != null) return 'phone:$phone';
  return null;
}

FraudSeverity _severity(num count, num mediumAt, num highAt) {
  if (count >= highAt) return FraudSeverity.high;
  if (count >= mediumAt) return FraudSeverity.medium;
  return FraudSeverity.low;
}

String _short(String id) => id.length > 8 ? '${id.substring(0, 8)}…' : id;
String _id8(String id) => id.length > 8 ? id.substring(0, 8) : id;
double _round2(double v) => double.parse(v.toStringAsFixed(2));

/// JS-style `toFixed` for display (Dart's matches for these magnitudes).
String _fx(double v, int digits) => v.toStringAsFixed(digits);

/// Dart doubles print `5.0`; JS prints `5`. Keep descriptions identical.
String _js(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

List<String> _rideSubjects(RideSignal r) => [r.id, ?r.partnerId, ?r.riderId];

/// Same account signing in from several distinct devices.
List<FraudFinding> detectMultiDeviceAccounts(List<SessionSignal> sessions, {int minDevices = 2}) {
  final byAccount = <String, ({String? phone, Set<String> devices})>{};
  for (final s in sessions) {
    final key = _accountKey(s.userId, s.phone);
    if (key == null || s.deviceId == null) continue;
    final e = byAccount[key] ?? (phone: s.phone, devices: <String>{});
    e.devices.add(s.deviceId!);
    byAccount[key] = (phone: s.phone ?? e.phone, devices: e.devices);
  }
  return [
    for (final MapEntry(:key, :value) in byAccount.entries)
      if (value.devices.length >= minDevices)
        FraudFinding(
          id: 'multi_device_account:$key',
          category: FraudCategory.multiDeviceAccount,
          severity: _severity(value.devices.length, 3, 5),
          title: 'Account used on ${value.devices.length} devices',
          description: '${value.phone ?? key} signed in from ${value.devices.length} distinct devices.',
          subjects: [key],
          evidence: {
            'account': key,
            'phone': value.phone,
            'deviceCount': value.devices.length,
            'devices': value.devices.toList(),
          },
        ),
  ];
}

List<FraudFinding> _clusters(
  List<SessionSignal> sessions,
  String? Function(SessionSignal) groupOf,
  int minAccounts,
  FraudFinding Function(String group, Set<String> accounts, List<String> phones) build,
) {
  final byGroup = <String, Set<String>>{};
  final phoneByAccount = <String, String?>{};
  for (final s in sessions) {
    final key = _accountKey(s.userId, s.phone);
    final g = groupOf(s);
    if (key == null || g == null) continue;
    phoneByAccount.putIfAbsent(key, () => s.phone);
    byGroup.putIfAbsent(g, () => <String>{}).add(key);
  }
  return [
    for (final MapEntry(:key, :value) in byGroup.entries)
      if (value.length >= minAccounts) build(key, value, [for (final a in value) phoneByAccount[a] ?? a]),
  ];
}

/// One physical device logging in as several accounts.
List<FraudFinding> detectSharedDevices(List<SessionSignal> sessions, {int minAccounts = 2}) =>
    _clusters(sessions, (s) => s.deviceId, minAccounts, (deviceId, accounts, phones) {
      return FraudFinding(
        id: 'shared_device:$deviceId',
        category: FraudCategory.sharedDevice,
        severity: _severity(accounts.length, 3, 5),
        title: 'Device used by ${accounts.length} accounts',
        description:
            'Device $deviceId was used to sign in as ${accounts.length} different accounts (${phones.join(', ')}).',
        subjects: accounts.toList(),
        evidence: {'device_id': deviceId, 'accountCount': accounts.length, 'accounts': phones},
      );
    });

/// Many accounts sharing one public IP — a device-farm signal.
List<FraudFinding> detectIpClusters(List<SessionSignal> sessions, {int minAccounts = 3}) =>
    _clusters(sessions, (s) => s.publicIp, minAccounts, (ip, accounts, phones) {
      return FraudFinding(
        id: 'ip_cluster:$ip',
        category: FraudCategory.ipCluster,
        severity: _severity(accounts.length, 4, 8),
        title: '${accounts.length} accounts from one IP',
        description: 'Public IP $ip was shared by ${accounts.length} different accounts (${phones.join(', ')}).',
        subjects: accounts.toList(),
        evidence: {'public_ip': ip, 'accountCount': accounts.length, 'accounts': phones},
      );
    });

/// Checkpoint GPS that doesn't match the declared pickup/drop.
List<FraudFinding> detectLocationMismatches(
  List<RideSignal> rides, {
  double arriveThresholdKm = 1.5,
  double dropThresholdKm = 2,
  double dropAgreementKm = 1.5,
}) {
  final findings = <FraudFinding>[];
  for (final r in rides) {
    if (r.status != 'completed' && r.status != 'on_trip' && r.status != 'cancelled') continue;
    Map<String, Object?> ev(double d) =>
        {'ride_id': r.id, 'distance_km': _round2(d), 'rider_id': r.riderId, 'partner_id': r.partnerId};

    if (r.partnerArriveLat != null && r.partnerArriveLng != null && r.pickupLat != null && r.pickupLng != null) {
      final d = haversineKm(r.partnerArriveLat!, r.partnerArriveLng!, r.pickupLat!, r.pickupLng!);
      if (d >= arriveThresholdKm) {
        findings.add(FraudFinding(
          id: 'location_mismatch:arrive:${r.id}',
          category: FraudCategory.locationMismatch,
          severity: _severity(d.round(), 3, 6),
          title: 'Fake pickup on ride ${_id8(r.id)}',
          description: 'Partner marked "arrived" ${_fx(d, 1)} km from the declared pickup point.',
          subjects: _rideSubjects(r),
          evidence: ev(d),
        ));
      }
    }
    if (r.status == 'completed' &&
        r.partnerDropLat != null &&
        r.partnerDropLng != null &&
        r.dropLat != null &&
        r.dropLng != null) {
      final d = haversineKm(r.partnerDropLat!, r.partnerDropLng!, r.dropLat!, r.dropLng!);
      if (d >= dropThresholdKm) {
        findings.add(FraudFinding(
          id: 'location_mismatch:drop:${r.id}',
          category: FraudCategory.locationMismatch,
          severity: _severity(d.round(), 4, 8),
          title: 'Fake drop-off on ride ${_id8(r.id)}',
          description: 'Trip was completed ${_fx(d, 1)} km from the declared drop-off address.',
          subjects: _rideSubjects(r),
          evidence: ev(d),
        ));
      }
    }
    if (r.status == 'completed' &&
        r.partnerDropLat != null &&
        r.partnerDropLng != null &&
        r.userDropLat != null &&
        r.userDropLng != null) {
      final d = haversineKm(r.partnerDropLat!, r.partnerDropLng!, r.userDropLat!, r.userDropLng!);
      if (d >= dropAgreementKm) {
        findings.add(FraudFinding(
          id: 'location_mismatch:sides:${r.id}',
          category: FraudCategory.locationMismatch,
          severity: _severity(d.round(), 3, 6),
          title: 'Rider/partner drop-off disagree on ride ${_id8(r.id)}',
          description:
              "Rider and partner GPS at drop-off were ${_fx(d, 1)} km apart — one side's location looks spoofed.",
          subjects: _rideSubjects(r),
          evidence: ev(d),
        ));
      }
    }
  }
  return findings;
}

/// Trips whose distance/duration imply an impossible average speed.
List<FraudFinding> detectImplausibleTrips(List<RideSignal> rides, {double maxSpeedKmh = 140, double minDistanceKm = 1}) {
  final findings = <FraudFinding>[];
  for (final r in rides) {
    if (r.status != 'completed') continue;
    final dist = r.distanceKm;
    final dur = r.durationMin;
    if (dist == null || dur == null || dist < minDistanceKm) continue;
    if (dur <= 0) {
      findings.add(FraudFinding(
        id: 'implausible_trip:zero_time:${r.id}',
        category: FraudCategory.implausibleTrip,
        severity: FraudSeverity.high,
        title: 'Zero-duration trip ${_id8(r.id)}',
        description: 'A ${_fx(dist, 1)} km trip was logged with 0 minutes of duration.',
        subjects: _rideSubjects(r),
        evidence: {'ride_id': r.id, 'distance_km': dist, 'duration_min': dur},
      ));
      continue;
    }
    final speed = dist / (dur / 60);
    if (speed >= maxSpeedKmh) {
      findings.add(FraudFinding(
        id: 'implausible_trip:speed:${r.id}',
        category: FraudCategory.implausibleTrip,
        severity: _severity((speed / 40).round(), 3, 5),
        title: 'Implausible speed on trip ${_id8(r.id)}',
        description: '${_fx(dist, 1)} km in ${_js(dur)} min implies ~${_fx(speed, 0)} km/h.',
        subjects: _rideSubjects(r),
        evidence: {
          'ride_id': r.id,
          'distance_km': dist,
          'duration_min': dur,
          'implied_speed_kmh': double.parse(speed.toStringAsFixed(1)),
        },
      ));
    }
  }
  return findings;
}

/// A rider/partner pair completing unusually many trips together.
List<FraudFinding> detectCollusionPairs(List<RideSignal> rides, {int minTrips = 5}) {
  final byPair = <String, List<RideSignal>>{};
  for (final r in rides) {
    if (r.status != 'completed' || r.riderId == null || r.partnerId == null) continue;
    byPair.putIfAbsent('${r.riderId}::${r.partnerId}', () => []).add(r);
  }
  final findings = <FraudFinding>[];
  byPair.forEach((key, list) {
    if (list.length < minTrips) return;
    final parts = key.split('::');
    final total = list.fold<double>(0, (s, r) => s + (r.fare ?? 0));
    findings.add(FraudFinding(
      id: 'collusion_pair:$key',
      category: FraudCategory.collusionPair,
      severity: _severity(list.length, 8, 15),
      title: 'Rider/partner pair rode together ${list.length} times',
      description: 'Rider ${_short(parts[0])} and partner ${_short(parts[1])} completed ${list.length} trips '
          'together, totalling ${_fx(total, 2)}.',
      subjects: [parts[0], parts[1], ...list.map((r) => r.id)],
      evidence: {'rider_id': parts[0], 'partner_id': parts[1], 'tripCount': list.length, 'totalFare': _round2(total)},
    ));
  });
  return findings;
}

/// A rider or partner with many cancellations inside a sliding window.
List<FraudFinding> detectExcessiveCancellations(List<RideSignal> rides, {int minCancellations = 5, int windowHours = 24}) {
  final windowMs = windowHours * 3600 * 1000;
  final byActor = <String, ({String role, List<int> times})>{};
  for (final r in rides) {
    if (r.status != 'cancelled' || r.cancelledAt == null) continue;
    final t = DateTime.tryParse(r.cancelledAt!)?.millisecondsSinceEpoch;
    if (t == null) continue;
    if (r.riderId != null) {
      byActor.putIfAbsent('rider:${r.riderId}', () => (role: 'rider', times: <int>[])).times.add(t);
    }
    if (r.partnerId != null) {
      byActor.putIfAbsent('partner:${r.partnerId}', () => (role: 'partner', times: <int>[])).times.add(t);
    }
  }
  final findings = <FraudFinding>[];
  byActor.forEach((key, entry) {
    final times = [...entry.times]..sort();
    var maxInWindow = 1;
    var start = 0;
    for (var i = 0; i < times.length; i++) {
      while (times[i] - times[start] > windowMs) {
        start++;
      }
      maxInWindow = math.max(maxInWindow, i - start + 1);
    }
    if (maxInWindow < minCancellations) return;
    final actorId = key.substring(key.indexOf(':') + 1);
    findings.add(FraudFinding(
      id: 'excessive_cancellations:$key',
      category: FraudCategory.excessiveCancellations,
      severity: _severity(maxInWindow, 8, 15),
      title: '$maxInWindow cancellations by a ${entry.role} in ${windowHours}h',
      description: '${entry.role == 'rider' ? 'Rider' : 'Partner'} ${_short(actorId)} cancelled $maxInWindow rides '
          'within a $windowHours-hour window.',
      subjects: [actorId],
      evidence: {'actor_id': actorId, 'role': entry.role, 'cancellations': maxInWindow, 'windowHours': windowHours},
    ));
  });
  return findings;
}

final _promoKind = RegExp('reward|bonus|referral|incentive|promo', caseSensitive: false);

/// Several accounts on one device all collecting promotional credit.
List<FraudFinding> detectPromotionAbuse(List<WalletTxSignal> walletTx, List<SessionSignal> sessions,
    {int minAccountsPerDevice = 2}) {
  final devicesByAccount = <String, Set<String>>{};
  for (final s in sessions) {
    final key = _accountKey(s.userId, s.phone);
    if (key == null || s.deviceId == null) continue;
    devicesByAccount.putIfAbsent(key, () => <String>{}).add(s.deviceId!);
  }
  final byDevice = <String, ({Set<String> accounts, List<double> amounts, Set<String> kinds})>{};
  for (final t in walletTx.where((t) => _promoKind.hasMatch(t.kind))) {
    final key = 'uid:${t.userId}';
    final devices = devicesByAccount[key];
    if (devices == null) continue;
    for (final d in devices) {
      final e = byDevice.putIfAbsent(d, () => (accounts: <String>{}, amounts: <double>[], kinds: <String>{}));
      e.accounts.add(key);
      e.amounts.add(t.amount);
      e.kinds.add(t.kind);
    }
  }
  final findings = <FraudFinding>[];
  byDevice.forEach((deviceId, e) {
    if (e.accounts.length < minAccountsPerDevice) return;
    final total = e.amounts.fold<double>(0, (s, a) => s + a);
    findings.add(FraudFinding(
      id: 'promotion_abuse:$deviceId',
      category: FraudCategory.promotionAbuse,
      severity: _severity(e.accounts.length, 3, 5),
      title: 'Promo credit farmed on one device (${e.accounts.length} accounts)',
      description: '${e.accounts.length} accounts on device $deviceId collected ${e.kinds.join(', ')} credit '
          'totalling ${_fx(total, 2)}.',
      subjects: e.accounts.toList(),
      evidence: {
        'device_id': deviceId,
        'accountCount': e.accounts.length,
        'totalAmount': _round2(total),
        'kinds': e.kinds.toList(),
      },
    ));
  });
  return findings;
}

/// Accepted coin transfers ping-ponging between two accounts.
List<FraudFinding> detectTransferCircles(List<TransferSignal> transfers, {int minTransfers = 6}) {
  final byPair = <String, List<TransferSignal>>{};
  for (final t in transfers.where((t) => t.status == 'accepted')) {
    final pair = [t.fromUserId, t.toUserId]..sort();
    byPair.putIfAbsent(pair.join('::'), () => []).add(t);
  }
  final findings = <FraudFinding>[];
  byPair.forEach((key, list) {
    if (list.length < minTransfers) return;
    final parts = key.split('::');
    final total = list.fold<double>(0, (s, t) => s + t.coins);
    findings.add(FraudFinding(
      id: 'promotion_abuse:transfer_circle:$key',
      category: FraudCategory.promotionAbuse,
      severity: _severity(list.length, 10, 20),
      title: '${list.length} coin transfers between two accounts',
      description: '${_short(parts[0])} and ${_short(parts[1])} exchanged ${list.length} accepted coin transfers '
          'totalling ${_fx(total, 2)} GC.',
      subjects: [parts[0], parts[1]],
      evidence: {'accounts': [parts[0], parts[1]], 'transferCount': list.length, 'totalCoins': _round2(total)},
    ));
  });
  return findings;
}

/// All detectors, sorted high → low severity (stable within a severity).
List<FraudFinding> runFraudScan({
  List<SessionSignal> sessions = const [],
  List<RideSignal> rides = const [],
  List<WalletTxSignal> walletTx = const [],
  List<TransferSignal> transfers = const [],
}) {
  final findings = [
    ...detectMultiDeviceAccounts(sessions),
    ...detectSharedDevices(sessions),
    ...detectIpClusters(sessions),
    ...detectLocationMismatches(rides),
    ...detectImplausibleTrips(rides),
    ...detectCollusionPairs(rides),
    ...detectExcessiveCancellations(rides),
    ...detectPromotionAbuse(walletTx, sessions),
    ...detectTransferCircles(transfers),
  ];
  final indexed = [for (var i = 0; i < findings.length; i++) (i, findings[i])];
  indexed.sort((a, b) {
    final c = b.$2.severity.index.compareTo(a.$2.severity.index);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

// ---- Suspect directory (screen helpers) -------------------------------------

class SuspectInfo {
  const SuspectInfo({this.name, this.phone});
  final String? name;
  final String? phone;
}

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false);

bool looksLikeUuid(String s) => _uuid.hasMatch(s);

/// Strips the `uid:` / `phone:` prefix from a finding subject.
String normalizeSubject(String subject) {
  if (subject.startsWith('uid:')) return subject.substring(4);
  if (subject.startsWith('phone:')) return subject.substring(6);
  return subject;
}

/// Ids and phones worth resolving to names for these findings.
({Set<String> ids, Set<String> phones}) suspectCandidates(List<FraudFinding> findings) {
  final ids = <String>{};
  final phones = <String>{};
  for (final f in findings) {
    for (final s in f.subjects) {
      final n = normalizeSubject(s);
      if (n.isEmpty) continue;
      (looksLikeUuid(n) ? ids : phones).add(n);
    }
  }
  return (ids: ids, phones: phones);
}

/// Distinct suspects (by name+phone) for a finding.
List<SuspectInfo> suspectsFor(FraudFinding f, Map<String, SuspectInfo> directory) {
  final seen = <String>{};
  final out = <SuspectInfo>[];
  for (final s in f.subjects) {
    final info = directory[normalizeSubject(s)];
    if (info == null) continue;
    if (seen.add('${info.name ?? ''}|${info.phone ?? ''}')) out.add(info);
  }
  return out;
}

/// JSON-ish rendering of evidence for display/search/CSV.
String evidenceText(Map<String, Object?> e) {
  String enc(Object? v) => switch (v) {
        null => 'null',
        String s => '"$s"',
        num n => _js(n),
        List l => '[${l.map(enc).join(',')}]',
        _ => '$v',
      };
  return '{${e.entries.map((x) => '"${x.key}":${enc(x.value)}').join(',')}}';
}

bool matchesFindingQuery(FraudFinding f, String query, List<SuspectInfo> suspects) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final hay = [
    f.title,
    f.description,
    ...f.subjects,
    evidenceText(f.evidence),
    ...suspects.map((s) => '${s.name ?? ''} ${s.phone ?? ''}'),
  ].join(' ').toLowerCase();
  return hay.contains(q);
}
