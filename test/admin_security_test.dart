import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/security/api_keys_logic.dart';
import 'package:get_ride/src/admin/screens/security/backend_logic.dart';
import 'package:get_ride/src/admin/screens/security/elife_logic.dart';
import 'package:get_ride/src/admin/screens/security/fare_ai_logic.dart';
import 'package:get_ride/src/admin/screens/security/fraud_detection.dart';
import 'package:get_ride/src/admin/screens/security/ip_access_logic.dart';
import 'package:get_ride/src/admin/screens/security/security_module.dart';
import 'package:get_ride/src/admin/screens/security/session_logic.dart';

SessionSignal sess(String? user, String? phone, String? device, [String? ip]) =>
    SessionSignal(userId: user, phone: phone, deviceId: device, publicIp: ip, capturedAt: '2026-01-01T00:00:00Z');

RideSignal ride({
  String id = 'ride-1',
  String status = 'completed',
  double? distanceKm = 5,
  double? durationMin = 10,
  double? fare,
  double? pickupLat,
  double? pickupLng,
  double? dropLat,
  double? dropLng,
  double? partnerArriveLat,
  double? partnerArriveLng,
  double? partnerDropLat,
  double? partnerDropLng,
  double? userDropLat,
  double? userDropLng,
  String? cancelledAt,
}) =>
    RideSignal(
      id: id,
      riderId: 'rider-1',
      partnerId: 'partner-1',
      status: status,
      distanceKm: distanceKm,
      durationMin: durationMin,
      fare: fare,
      pickupLat: pickupLat,
      pickupLng: pickupLng,
      dropLat: dropLat,
      dropLng: dropLng,
      partnerArriveLat: partnerArriveLat,
      partnerArriveLng: partnerArriveLng,
      partnerDropLat: partnerDropLat,
      partnerDropLng: partnerDropLng,
      userDropLat: userDropLat,
      userDropLng: userDropLng,
      cancelledAt: cancelledAt,
    );

ApiKeyEntry key(String id, String value, {int failed = 0, int used = 0, bool? disabled, String? label}) =>
    ApiKeyEntry(id: id, label: label ?? id, value: value, failedCount: failed, useCount: used, disabled: disabled);

void main() {
  // ---- deviceLinkage.test.ts -------------------------------------------------
  group('accountKey', () {
    test('prefers the user id', () => expect(accountKey(userId: 'u1', phone: '+601'), 'u1'));
    test('falls back to a phone-prefixed key', () => expect(accountKey(phone: '+601'), 'phone:+601'));
    test('null for an anonymous session', () => expect(accountKey(), isNull));
  });

  group('computeDeviceLinks', () {
    test('flags two accounts that share one device', () {
      final links = computeDeviceLinks(const [
        SessionIdentity(userId: 'a', deviceId: 'dev-1'),
        SessionIdentity(userId: 'b', deviceId: 'dev-1'),
      ]);
      expect(links['a']!.linkedAccounts, ['b']);
      expect(links['a']!.sharedDevices, ['dev-1']);
      expect(links['b']!.linkedAccounts, ['a']);
    });

    test('does not flag an account that keeps its own devices', () {
      expect(
        computeDeviceLinks(const [
          SessionIdentity(userId: 'a', deviceId: 'dev-1'),
          SessionIdentity(userId: 'a', deviceId: 'dev-2'),
          SessionIdentity(userId: 'b', deviceId: 'dev-3'),
        ]),
        isEmpty,
      );
    });

    test('links three accounts sharing one device to each other', () {
      final links = computeDeviceLinks(const [
        SessionIdentity(userId: 'a', deviceId: 'dev-1'),
        SessionIdentity(userId: 'b', deviceId: 'dev-1'),
        SessionIdentity(userId: 'c', deviceId: 'dev-1'),
      ]);
      expect(links['a']!.linkedAccounts, ['b', 'c']);
      expect(links['b']!.linkedAccounts, ['a', 'c']);
      expect(links['c']!.linkedAccounts, ['a', 'b']);
    });

    test('collects multiple shared devices for the same pair', () {
      final links = computeDeviceLinks(const [
        SessionIdentity(userId: 'a', deviceId: 'dev-1'),
        SessionIdentity(userId: 'b', deviceId: 'dev-1'),
        SessionIdentity(userId: 'a', deviceId: 'dev-2'),
        SessionIdentity(userId: 'b', deviceId: 'dev-2'),
      ]);
      expect(links['a']!.sharedDevices, ['dev-1', 'dev-2']);
      expect(links['a']!.linkedAccounts, ['b']);
    });

    test('keys accounts by phone when there is no user id', () {
      final links = computeDeviceLinks(const [
        SessionIdentity(phone: '+6011', deviceId: 'dev-1'),
        SessionIdentity(phone: '+6022', deviceId: 'dev-1'),
      ]);
      expect(links['phone:+6011']!.linkedAccounts, ['phone:+6022']);
    });

    test('ignores sessions with no device id, anonymous sessions, and self-links', () {
      expect(computeDeviceLinks(const [SessionIdentity(userId: 'a'), SessionIdentity(userId: 'b')]), isEmpty);
      expect(computeDeviceLinks(const [SessionIdentity(deviceId: 'dev-1'), SessionIdentity(userId: 'b', deviceId: 'dev-1')]),
          isEmpty);
      expect(
        computeDeviceLinks(const [
          SessionIdentity(userId: 'a', deviceId: 'dev-1'),
          SessionIdentity(userId: 'a', deviceId: 'dev-1'),
        ]),
        isEmpty,
      );
    });
  });

  // ---- deviceGuard.test.ts ---------------------------------------------------
  group('device guard', () {
    test('isRegistrationAllowed', () {
      expect(isRegistrationAllowed(0), isTrue);
      expect(isRegistrationAllowed(defaultMaxAccountsPerDevice - 1), isTrue);
      expect(isRegistrationAllowed(defaultMaxAccountsPerDevice), isFalse);
      expect(isRegistrationAllowed(defaultMaxAccountsPerDevice + 5), isFalse);
      expect(isRegistrationAllowed(1, 2), isTrue);
      expect(isRegistrationAllowed(2, 2), isFalse);
      expect(isRegistrationAllowed(double.nan), isTrue);
      expect(isRegistrationAllowed(-3), isTrue);
      expect(isRegistrationAllowed(double.infinity), isTrue);
    });

    test('parseDeviceLimitError', () {
      final a = parseDeviceLimitError('DEVICE_LIMIT:2/3')!;
      expect((a.priorAccounts, a.maxAccounts), (2, 3));
      final b = parseDeviceLimitError('ERROR: DEVICE_LIMIT:5/3 (SQLSTATE P0001)')!;
      expect((b.priorAccounts, b.maxAccounts), (5, 3));
      expect(parseDeviceLimitError('PIN must be exactly 6 digits'), isNull);
      expect(parseDeviceLimitError(null), isNull);
    });

    test('error classifiers', () {
      expect(isDeviceLimitError(Exception('DEVICE_LIMIT:4/3')), isTrue);
      expect(isDeviceLimitError('DEVICE_LIMIT:4/3'), isTrue);
      expect(isDeviceLimitError(Exception('nope')), isFalse);
      expect(isDeviceLimitError(null), isFalse);
      expect(isDeviceLimitError(42), isFalse);
      expect(isEmulatorBlockedError(Exception('EMULATOR_BLOCKED')), isTrue);
      expect(isEmulatorBlockedError('ERROR: EMULATOR_BLOCKED (SQLSTATE P0001)'), isTrue);
      expect(isEmulatorBlockedError(Exception('DEVICE_LIMIT:2/3')), isFalse);
      expect(isRegistrationBlockedError(Exception('DEVICE_LIMIT:4/3')), isTrue);
      expect(isRegistrationBlockedError(Exception('EMULATOR_BLOCKED')), isTrue);
      expect(isRegistrationBlockedError(Exception('PIN must be exactly 6 digits')), isFalse);
      expect(isRegistrationBlockedError(null), isFalse);
    });

    test('config parses the RPC row and clamps the limit when saving', () {
      final c = DeviceGuardConfig.fromRpc([
        {'enabled': false, 'max_accounts': 5, 'block_emulators': true},
      ]);
      expect((c.enabled, c.maxAccountsPerDevice, c.blockEmulators), (false, 5, true));
      expect(DeviceGuardConfig.fromRpc(null).maxAccountsPerDevice, defaultMaxAccountsPerDevice);
      expect(DeviceGuardConfig.fromRpc({'max_accounts': 0}).maxAccountsPerDevice, defaultMaxAccountsPerDevice);
      expect(c.copyWith(maxAccountsPerDevice: 0).toRpcParams(),
          {'p_enabled': false, 'p_max_accounts': 1, 'p_block_emulators': true});
    });
  });

  // ---- mobileOperator.test.ts ------------------------------------------------
  group('mobile operator', () {
    test('normalizeCarrierName', () {
      expect(normalizeCarrierName('Maxis'), 'Maxis');
      expect(normalizeCarrierName('  Celcom  '), 'Celcom');
      for (final v in [null, '', '   ', '--', '  --  ']) {
        expect(normalizeCarrierName(v), isNull);
      }
    });

    test('normalizeMobileCode', () {
      expect(normalizeMobileCode('502'), '502');
      expect(normalizeMobileCode('017'), '017');
      expect(normalizeMobileCode('  310  '), '310');
      for (final v in [null, '', '   ', '65535', '  65535  ', '--', 'N/A', '50a']) {
        expect(normalizeMobileCode(v), isNull);
      }
    });

    test('formatPlmn', () {
      expect(formatPlmn('502', '12'), '502-12');
      expect(formatPlmn('502', null), '502');
      expect(formatPlmn(null, '12'), '12');
      expect(formatPlmn('65535', '65535'), isNull);
      expect(formatPlmn('', ''), isNull);
    });

    test('resolveMobileOperator', () {
      expect(resolveMobileOperator(carrierName: 'Digi', connectionType: 'mobile', ispProvider: 'X', ispOrg: 'Y'), 'Digi');
      expect(resolveMobileOperator(carrierName: '--', connectionType: 'mobile', ispProvider: 'Celcom Axiata'),
          'Celcom Axiata');
      expect(resolveMobileOperator(connectionType: 'mobile', ispOrg: 'Maxis Broadband'), 'Maxis Broadband');
      expect(resolveMobileOperator(connectionType: 'wifi', ispProvider: 'Home Fibre Co'), isNull);
      expect(resolveMobileOperator(connectionType: 'other', ispProvider: 'Office WiFi'), isNull);
      expect(resolveMobileOperator(carrierName: '--', connectionType: 'mobile', ispProvider: '  '), isNull);
    });
  });

  // ---- session screen helpers ------------------------------------------------
  group('session summaries & filters', () {
    final sessions = [
      {'id': 's1', 'user_id': 'u1', 'phone': '+601', 'captured_at': '2026-01-02T00:00:00Z', 'os_name': 'iOS', 'os_version': '17', 'device_model_name': 'iPhone', 'isp_provider': 'Maxis'},
      {'id': 's2', 'user_id': 'u1', 'phone': '+601', 'captured_at': '2026-01-01T00:00:00Z', 'os_name': 'Android'},
      {'id': 's3', 'user_id': null, 'phone': null, 'captured_at': '2026-01-03T00:00:00Z', 'is_physical_device': false},
      {'id': 's4', 'user_id': 'u2', 'phone': null, 'captured_at': '2025-12-01T00:00:00Z', 'is_physical_device': false},
    ];
    final pings = [
      {'user_id': 'u1', 'latitude': 3.1, 'longitude': 101.6, 'captured_at': '2026-01-02T01:00:00Z'},
      {'user_id': 'u1', 'latitude': 9.9, 'longitude': 9.9, 'captured_at': '2026-01-01T01:00:00Z'},
    ];

    test('summarizeUsers groups by account, keeps the newest details and the latest ping', () {
      final users = summarizeUsers(sessions, pings);
      expect(users.map((u) => u.key), ['anon:s3', 'u1', 'u2']);
      final u1 = users[1];
      expect(u1.sessionCount, 2);
      expect(u1.lastOs, 'iOS 17');
      expect(u1.lastIsp, 'Maxis');
      expect((u1.lastLat, u1.lastLng), (3.1, 101.6));
      expect(accountLabel('u1', users), '+601');
      expect(accountLabel('u2', users), 'uid u2…');
      expect(accountLabel('phone:+609', users), '+609');
      expect(matchesUserQuery(u1, 'iphone'), isTrue);
      expect(matchesUserQuery(u1, 'pixel'), isFalse);
    });

    test('emulatorAccounts ignores anonymous sessions', () {
      expect(emulatorAccounts(sessions), {'u2'});
    });

    test('CSV escaping matches Expo', () {
      expect(csvEscape(null), '');
      expect(csvEscape('a,b'), '"a,b"');
      expect(csvEscape('say "hi"'), '"say ""hi"""');
      expect(rowsToCsv([
        {'a': 1, 'b': 'x\ny'},
      ], ['a', 'b']), 'a,b\n1,"x\ny"');
    });

    test('day range is inclusive of both days in local time', () {
      final r = dayRange('2026-01-02', '2026-01-02');
      expect(inDayRange(DateTime(2026, 1, 2, 0, 0).toUtc().toIso8601String(), r), isTrue);
      expect(inDayRange(DateTime(2026, 1, 2, 23, 59, 59).toUtc().toIso8601String(), r), isTrue);
      expect(inDayRange(DateTime(2026, 1, 3).toUtc().toIso8601String(), r), isFalse);
      expect(inDayRange('2020-01-01T00:00:00Z', dayRange('', '')), isTrue);
    });

    test('trail windows', () {
      final now = DateTime(2026, 3, 10, 15, 30);
      final today = trailWindow(TrailScope.today, now)!;
      expect(today.start, DateTime(2026, 3, 10));
      final y = trailWindow(TrailScope.yesterday, now)!;
      expect(y.start, DateTime(2026, 3, 9));
      expect(y.end, DateTime(2026, 3, 9, 23, 59, 59, 999));
      String? err;
      expect(trailWindow(TrailScope.range, now, onError: (e) => err = e), isNull);
      expect(err, 'Choose both a start and end date.');
      expect(trailWindow(TrailScope.range, now, rangeFrom: '2026-03-05', rangeTo: '2026-03-01', onError: (e) => err = e),
          isNull);
      expect(err, 'Check the date range values.');
      expect(trailWindow(TrailScope.range, now, rangeFrom: '2026-03-01', rangeTo: '2026-03-05')!.start, DateTime(2026, 3, 1));
    });

    test('time-of-day filter wraps past midnight', () {
      Map<String, dynamic> at(int h) => {'captured_at': DateTime(2026, 1, 1, h).toUtc().toIso8601String()};
      final rows = [at(1), at(9), at(23)];
      expect(filterByTimeOfDay(rows, '08:00', '10:00').length, 1);
      expect(filterByTimeOfDay(rows, '22:00', '02:00').length, 2);
    });

    test('trail sampling', () {
      expect(sampleEvenly(List.generate(200, (i) => i), 80).length, lessThanOrEqualTo(80));
      final coords = trailCoordinates([
        {'latitude': 3, 'longitude': 3},
        {'latitude': 2, 'longitude': 2},
        {'latitude': 1, 'longitude': 1},
      ]);
      expect(coords.map((c) => c.lat), [1, 2, 3]);
      expect(trailCoordinates([{'latitude': 1, 'longitude': 1}]), isEmpty);
    });
  });

  // ---- fraudDetection.test.ts ------------------------------------------------
  group('haversineKm', () {
    test('zero for the same point', () => expect(haversineKm(3.139, 101.6869, 3.139, 101.6869), 0));
    test('KL to KLIA is 40-60 km', () {
      final d = haversineKm(3.139, 101.6869, 2.7456, 101.7099);
      expect(d, inInclusiveRange(40, 60));
    });
  });

  group('session detectors', () {
    test('multi-device account', () {
      final f = detectMultiDeviceAccounts([sess('u1', '+60111', 'dA'), sess('u1', '+60111', 'dB'), sess('u1', '+60111', 'dC')]);
      expect(f, hasLength(1));
      expect(f.first.category, FraudCategory.multiDeviceAccount);
      expect(f.first.evidence['deviceCount'], 3);
      expect(detectMultiDeviceAccounts([sess('u1', '+60111', 'dA'), sess('u1', '+60111', 'dA')]), isEmpty);
      final two = [sess('u1', null, 'dA'), sess('u1', null, 'dB')];
      expect(detectMultiDeviceAccounts(two, minDevices: 2), hasLength(1));
      expect(detectMultiDeviceAccounts(two, minDevices: 3), isEmpty);
    });

    test('shared device', () {
      final f = detectSharedDevices([sess('u1', '+60111', 'dS'), sess('u2', '+60222', 'dS'), sess('u3', '+60333', 'dS')]);
      expect(f, hasLength(1));
      expect(f.first.category, FraudCategory.sharedDevice);
      expect(f.first.subjects, containsAll(['uid:u1', 'uid:u2', 'uid:u3']));
      expect(detectSharedDevices([sess('u1', null, null), sess('u2', null, null)]), isEmpty);
    });

    test('ip cluster', () {
      final s = [for (var i = 0; i < 3; i++) sess('u${i + 1}', '+601$i', 'd$i', '1.2.3.4')];
      expect(detectIpClusters(s, minAccounts: 3), hasLength(1));
      expect(detectIpClusters(s, minAccounts: 4), isEmpty);
    });
  });

  group('detectLocationMismatches', () {
    test('fake pickup', () {
      final f = detectLocationMismatches([ride(pickupLat: 3.139, pickupLng: 101.6869, partnerArriveLat: 3.2, partnerArriveLng: 101.75)]);
      expect(f.any((x) => x.id.startsWith('location_mismatch:arrive')), isTrue);
    });
    test('fake drop-off', () {
      final f = detectLocationMismatches([ride(dropLat: 3.139, dropLng: 101.6869, partnerDropLat: 3.3, partnerDropLng: 101.9)]);
      expect(f.any((x) => x.id.startsWith('location_mismatch:drop')), isTrue);
    });
    test('rider/partner disagreement', () {
      final f = detectLocationMismatches(
          [ride(partnerDropLat: 3.139, partnerDropLng: 101.6869, userDropLat: 3.25, userDropLng: 101.8)]);
      expect(f.any((x) => x.id.startsWith('location_mismatch:sides')), isTrue);
    });
    test('close checkpoints and open rides are not flagged', () {
      expect(
        detectLocationMismatches([
          ride(
            pickupLat: 3.139, pickupLng: 101.6869, partnerArriveLat: 3.1391, partnerArriveLng: 101.687,
            dropLat: 3.15, dropLng: 101.7, partnerDropLat: 3.1501, partnerDropLng: 101.7001,
            userDropLat: 3.1502, userDropLng: 101.7002,
          ),
        ]),
        isEmpty,
      );
      expect(detectLocationMismatches([ride(status: 'open')]), isEmpty);
    });
  });

  group('detectImplausibleTrips', () {
    test('zero duration', () {
      final f = detectImplausibleTrips([ride(distanceKm: 8, durationMin: 0)]);
      expect(f, hasLength(1));
      expect(f.first.id, contains('zero_time'));
      expect(f.first.severity, FraudSeverity.high);
    });
    test('impossible speed', () {
      final f = detectImplausibleTrips([ride(distanceKm: 100, durationMin: 5)]);
      expect(f, hasLength(1));
      expect(f.first.id, contains('speed'));
      expect(f.first.description, '100.0 km in 5 min implies ~1200 km/h.');
    });
    test('normal pace and non-completed rides are ignored', () {
      expect(detectImplausibleTrips([ride(distanceKm: 10, durationMin: 15)]), isEmpty);
      expect(detectImplausibleTrips([ride(status: 'on_trip', distanceKm: 100, durationMin: 1)]), isEmpty);
    });
  });

  group('detectCollusionPairs', () {
    test('flags a frequent pair', () {
      final f = detectCollusionPairs([for (var i = 0; i < 6; i++) ride(id: 'ride-$i', fare: 20)], minTrips: 5);
      expect(f, hasLength(1));
      expect(f.first.evidence['tripCount'], 6);
      expect(f.first.evidence['totalFare'], 120);
    });
    test('below threshold', () {
      expect(detectCollusionPairs([for (var i = 0; i < 3; i++) ride(id: 'ride-$i')], minTrips: 5), isEmpty);
    });
  });

  group('detectExcessiveCancellations', () {
    test('many in the window', () {
      final rides = [
        for (var i = 0; i < 6; i++)
          ride(id: 'ride-$i', status: 'cancelled', cancelledAt: DateTime.utc(2026, 1, 1, i).toIso8601String()),
      ];
      final f = detectExcessiveCancellations(rides, minCancellations: 5, windowHours: 24);
      expect(f.any((x) => x.evidence['role'] == 'rider'), isTrue);
    });
    test('spread far apart', () {
      final rides = [
        for (var i = 0; i < 6; i++)
          ride(id: 'ride-$i', status: 'cancelled', cancelledAt: DateTime.utc(2026, i + 1, 1).toIso8601String()),
      ];
      expect(detectExcessiveCancellations(rides, minCancellations: 5, windowHours: 24), isEmpty);
    });
  });

  group('detectPromotionAbuse', () {
    final sessions = [sess('u1', '+60111', 'dS'), sess('u2', '+60222', 'dS')];
    test('several accounts on one device collecting rewards', () {
      final f = detectPromotionAbuse(const [
        WalletTxSignal(id: 't1', userId: 'u1', kind: 'reward', amount: 10),
        WalletTxSignal(id: 't2', userId: 'u2', kind: 'reward', amount: 10),
      ], sessions);
      expect(f, hasLength(1));
      expect(f.first.evidence['accountCount'], 2);
    });
    test('non-promotional kinds are ignored', () {
      expect(
        detectPromotionAbuse(const [
          WalletTxSignal(id: 't1', userId: 'u1', kind: 'topup', amount: 10),
          WalletTxSignal(id: 't2', userId: 'u2', kind: 'topup', amount: 10),
        ], sessions),
        isEmpty,
      );
    });
  });

  group('detectTransferCircles', () {
    test('many accepted transfers between two accounts', () {
      final t = [
        for (var i = 0; i < 7; i++)
          TransferSignal(id: 'x$i', fromUserId: i.isEven ? 'a' : 'b', toUserId: i.isEven ? 'b' : 'a', coins: 5, status: 'accepted'),
      ];
      final f = detectTransferCircles(t, minTransfers: 6);
      expect(f, hasLength(1));
      expect(f.first.evidence['transferCount'], 7);
    });
    test('pending transfers ignored', () {
      final t = [for (var i = 0; i < 7; i++) TransferSignal(id: 'x$i', fromUserId: 'a', toUserId: 'b', coins: 5, status: 'pending')];
      expect(detectTransferCircles(t, minTransfers: 6), isEmpty);
    });
  });

  group('runFraudScan', () {
    test('combines detectors sorted by severity', () {
      final f = runFraudScan(
        sessions: [sess('u1', '+60111', 'dS', '1.1.1.1'), sess('u2', '+60222', 'dS', '1.1.1.1')],
        rides: [ride(distanceKm: 8, durationMin: 0)],
      );
      expect(f, isNotEmpty);
      for (var i = 1; i < f.length; i++) {
        expect(f[i - 1].severity.index, greaterThanOrEqualTo(f[i].severity.index));
      }
      expect(f.first.severity, FraudSeverity.high);
    });
    test('empty input', () => expect(runFraudScan(), isEmpty));
  });

  group('suspect helpers', () {
    const uid = '123e4567-e89b-12d3-a456-426614174000';
    final finding = FraudFinding(
      id: 'x',
      category: FraudCategory.sharedDevice,
      severity: FraudSeverity.low,
      title: 'Device used by 2 accounts',
      description: 'd',
      subjects: const ['uid:$uid', 'phone:+6011'],
      evidence: const {'device_id': 'dev', 'accountCount': 2},
    );
    test('normalizes and splits subjects', () {
      final c = suspectCandidates([finding]);
      expect(c.ids, {uid});
      expect(c.phones, {'+6011'});
    });
    test('dedupes suspects and searches names', () {
      const info = SuspectInfo(name: 'Ali', phone: '+6011');
      final s = suspectsFor(finding, {uid: info, '+6011': info});
      expect(s, hasLength(1));
      expect(matchesFindingQuery(finding, 'ali', s), isTrue);
      expect(matchesFindingQuery(finding, 'accountcount', s), isTrue);
      expect(matchesFindingQuery(finding, 'zzz', s), isFalse);
      expect(evidenceText(finding.evidence), '{"device_id":"dev","accountCount":2}');
    });
  });

  // ---- ipAccessStore.test.ts -------------------------------------------------
  group('IP access', () {
    test('classifyIp: whitelist, blacklist, blacklist wins, unmatched', () {
      expect(classifyIp(['whitelist']), IpListType.whitelist);
      expect(classifyIp(['blacklist']), IpListType.blacklist);
      expect(classifyIp(['whitelist', 'blacklist']), IpListType.blacklist);
      expect(classifyIp(const []), isNull);
      expect(classifyIp(['bogus']), isNull);
    });

    test('rule rows trim and blank the label; blank IPs are refused', () {
      expect(ipRuleRow(ip: '  ', listType: IpListType.whitelist).error, isNotNull);
      expect(ipRuleRow(ip: ' 1.2.3.4 ', listType: IpListType.blacklist, label: '  ').row,
          {'ip_address': '1.2.3.4', 'list_type': 'blacklist', 'label': null});
      expect(ipRuleRow(ip: '1.2.3.4', listType: IpListType.whitelist, label: ' Office ').row!['label'], 'Office');
    });

    test('filtering, counts and subtitles', () {
      final rules = [
        IpAccessRule.fromRow({'id': 'r1', 'ip_address': '1.2.3.4', 'list_type': 'whitelist', 'label': 'Office'}),
        IpAccessRule.fromRow({'id': 'r2', 'ip_address': '5.6.7.8', 'list_type': 'blacklist'}),
      ];
      expect(countRules(rules), (white: 1, black: 1));
      expect(filterRules(rules, query: 'office').map((r) => r.id), ['r1']);
      expect(filterRules(rules, filter: IpListType.blacklist).map((r) => r.id), ['r2']);
      expect(ruleSubtitle(rules[1]), 'Blocked — Service Not Available');
    });

    test('parsePublicIp handles JSON and plain-text providers', () {
      expect(parsePublicIp('{"ip":"203.0.113.9"}'), '203.0.113.9');
      expect(parsePublicIp('203.0.113.9\n'), '203.0.113.9');
      expect(parsePublicIp('<html>'), isNull);
      expect(parsePublicIp(''), isNull);
    });
  });

  // ---- apiKeysStore + mappingClient.test.ts ----------------------------------
  group('API providers', () {
    test('merge adds missing defaults without touching edits, keeping custom providers last', () {
      final stored = [
        const ApiProviderDef(id: 'custom', name: 'Mine'),
        ApiProviderDef(id: 'google', name: 'Renamed', services: [
          ApiServiceDef(id: 'maps', name: 'Maps', keys: [key('k1', 'secret')]),
        ]),
      ];
      final r = mergeDefaultProviders(stored);
      expect(r.changed, isTrue);
      expect(r.list.first.id, 'google');
      expect(r.list.first.name, 'Renamed');
      expect(r.list.first.services.first.keys.single.value, 'secret');
      expect(r.list.first.services.map((s) => s.id), containsAll(['maps', 'places', 'roads']));
      expect(r.list.last.id, 'custom');
      expect(mergeDefaultProviders(r.list).changed, isFalse);
    });

    test('JSON round-trip keeps unknown fields and omits unset optionals', () {
      final p = parseProviders([
        {
          'id': 'p',
          'name': 'P',
          'extraField': 1,
          'services': [
            {
              'id': 's',
              'name': 'S',
              'keys': [
                {'id': 'k', 'label': 'K', 'value': 'v', 'useCount': 2, 'failedCount': 1, 'note': 'x'},
              ],
            },
          ],
        },
      ]);
      final json = providersToJson(p).single;
      expect(json['extraField'], 1);
      final k = (json['services'] as List).single['keys'].single as Map;
      expect(k['note'], 'x');
      expect(k.containsKey('disabled'), isFalse);
      expect(k['useCount'], 2);
    });

    test('mutations', () {
      var list = addProvider(const [], ' Yandex ', id: 'p1');
      expect(list.single.category, 'Custom');
      expect(list.single.name, 'Yandex');
      list = addService(list, 'p1', 'Geo', description: ' ', id: 's1');
      expect(list.single.services.single.description, isNull);
      list = addKey(list, 'p1', 's1', '', ' abc ', id: 'k1');
      expect(list.single.services.single.keys.single.label, 'Key 1');
      expect(list.single.services.single.keys.single.value, 'abc');
      list = reportKeyUsage(list, 'p1', 's1', 'k1', false, now: DateTime.fromMillisecondsSinceEpoch(1000));
      list = reportKeyUsage(list, 'p1', 's1', 'k1', true, now: DateTime.fromMillisecondsSinceEpoch(2000));
      final k = list.single.services.single.keys.single;
      expect((k.useCount, k.failedCount, k.lastUsedAt, k.lastFailedAt), (1, 1, 2000, 1000));
      list = updateKey(list, 'p1', 's1', 'k1', (x) => x.copyWith(disabled: true));
      expect(list.single.services.single.keys.single.isDisabled, isTrue);
      list = removeKey(list, 'p1', 's1', 'k1');
      expect(list.single.services.single.keys, isEmpty);
      list = removeService(list, 'p1', 's1');
      expect(list.single.services, isEmpty);
      expect(removeProvider(list, 'p1'), isEmpty);
      expect(genApiId('key'), matches(RegExp(r'^key_[0-9a-z]+_[0-9a-z]{5}$')));
    });

    test('rotation order: fewest failures, then least used; disabled/empty skipped', () {
      final s = ApiServiceDef(id: 's', name: 'S', keys: [
        key('worst', 'k-worst', failed: 3),
        key('busy', 'k-busy', used: 10),
        key('off', 'k-off', disabled: true),
        key('empty', '  '),
        key('best', 'k-best', used: 1),
      ]);
      expect(rotationOrder(s).map((k) => k.id), ['best', 'busy', 'worst']);
      expect(pickNextKey(s)!.id, 'best');
      expect(pickNextKey(ApiServiceDef(id: 's', name: 'S', keys: [key('off', 'x', disabled: true)])), isNull);
    });
  });

  group('runKeyRotation (mappingClient)', () {
    Future<String> fb() async => 'fb';

    test('no service → fallback', () async {
      var called = false;
      final r = await runKeyRotation<String>(
          service: null, perform: (_) async { called = true; return (ok: true, value: 'x'); }, fallback: fb);
      expect(r, 'fb');
      expect(called, isFalse);
    });

    test('keyless service is invoked once with an empty key, falling back on failure', () async {
      const s = ApiServiceDef(id: 'geocoding', name: 'Geocoding');
      final keys = <String>[];
      expect(await runKeyRotation<String>(service: s, perform: (k) async { keys.add(k); return (ok: true, value: 'via-$k'); }, fallback: fb), 'via-');
      expect(keys, ['']);
      expect(await runKeyRotation<String>(service: s, perform: (_) async => (ok: false, value: 'bad'), fallback: fb), 'fb');
    });

    test('rotates on failure and reports both attempts', () async {
      final s = ApiServiceDef(id: 'g', name: 'G', keys: [key('a', 'key-a'), key('b', 'key-b')]);
      final reports = <(String, bool)>[];
      final r = await runKeyRotation<String>(
        service: s,
        perform: (k) async => k == 'key-a' ? (ok: false, value: '') : (ok: true, value: 'ok-b'),
        fallback: fb,
        report: (id, ok) async => reports.add((id, ok)),
      );
      expect(r, 'ok-b');
      expect(reports, [('a', false), ('b', true)]);
    });

    test('tries keys in health order', () async {
      final s = ApiServiceDef(id: 'g', name: 'G', keys: [
        key('worst', 'k-worst', failed: 3),
        key('busy', 'k-busy', used: 10),
        key('best', 'k-best', used: 1),
      ]);
      final tried = <String>[];
      await runKeyRotation<String>(service: s, perform: (k) async { tried.add(k); return (ok: false, value: ''); }, fallback: fb);
      expect(tried, ['k-best', 'k-busy', 'k-worst']);
    });

    test('returns the last non-ok value when every key fails with output', () async {
      final s = ApiServiceDef(id: 'g', name: 'G', keys: [key('a', 'key-a')]);
      expect(await runKeyRotation<String>(service: s, perform: (_) async => (ok: false, value: 'partial-result'), fallback: fb),
          'partial-result');
    });

    test('falls back when every key throws, reporting each failure', () async {
      final s = ApiServiceDef(id: 'g', name: 'G', keys: [key('a', 'key-a'), key('b', 'key-b')]);
      final reports = <(String, bool)>[];
      final r = await runKeyRotation<String>(
        service: s,
        perform: (_) async => throw Exception('network down'),
        fallback: fb,
        report: (id, ok) async => reports.add((id, ok)),
      );
      expect(r, 'fb');
      expect(reports, [('a', false), ('b', false)]);
    });
  });

  group('maskSecret', () {
    test('shows only the last 4 characters', () {
      expect(maskSecret('AIzaSyEXAMPLEKEY1234'), '••••1234');
      expect(maskSecret('short'), '••••');
      expect(maskSecret(''), '(empty)');
      expect(maskSecret('AIzaSyEXAMPLEKEY1234'), isNot(contains('AIza')));
    });
  });

  // ---- elifeApiStore -----------------------------------------------------------
  group('Elife config', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    test('normalize overlays defaults, keeps unknown fields and caps activity', () {
      final c = normalizeElife({
        'clientId': 'abc',
        'custom': true,
        'activity': List.generate(30, (i) => {'id': '$i'}),
      });
      expect(c['tokenUrl'], 'https://api.elifetransfer.com/oauth/token');
      expect(c['clientId'], 'abc');
      expect(c['custom'], isTrue);
      expect((c['activity'] as List).length, elifeActivityCap);
      expect(normalizeElife(null)['status'], 'unknown');
    });

    test('enable/disable logs an event and disabling sets status', () {
      final off = setElifeEnabled(normalizeElife({'status': 'connected', 'enabled': true}), false, now: now);
      expect(off['status'], 'disabled');
      final e = elifeActivity(off).first;
      expect((e.kind, e.ok, e.message, e.at), ('disable', true, 'Integration disabled', now.millisecondsSinceEpoch));
      final on = setElifeEnabled(off, true, now: now);
      expect(on['status'], 'disabled');
      expect(elifeActivity(on).length, 2);
    });

    test('config patch logs only with a message', () {
      final base = normalizeElife(null);
      expect(elifeActivity(applyElifePatch(base, {'baseUrl': 'x'})), isEmpty);
      final logged = applyElifePatch(base, {'baseUrl': 'x'}, logMessage: 'Changed', now: now);
      expect(logged['baseUrl'], 'x');
      expect(elifeActivity(logged).single.kind, 'config');
    });

    test('preflight, status mapping and test outcomes', () {
      expect(elifePreflight(normalizeElife(null))!.message, 'Client ID and Client Secret are required.');
      expect(elifePreflight(normalizeElife({'clientId': 'a', 'clientSecret': 'b', 'tokenUrl': ' '}))!.message,
          'Token URL is not configured.');
      expect(elifePreflight(normalizeElife({'clientId': 'a', 'clientSecret': 'b'})), isNull);
      expect(elifeResultForStatus(200).ok, isTrue);
      expect(elifeResultForStatus(401).message, 'Token request failed (HTTP 401).');

      final failed = applyElifeTest(normalizeElife(null), elifeResultForStatus(401), now: now);
      expect((failed['status'], failed['lastError'], failed['lastCheckedAt']),
          ('error', 'Token request failed (HTTP 401).', now.millisecondsSinceEpoch));
      final ok = applyElifeTest(failed, elifeResultForStatus(200), now: now);
      expect(ok['status'], 'connected');
      expect(ok.containsKey('lastError'), isFalse);
      expect(elifeActivity(ok).first.status, 200);
      expect(clearElifeActivity(ok)['activity'], isEmpty);
    });

    test('display status and time ago', () {
      expect(elifeDisplayStatus({'enabled': false, 'status': 'connected'}), 'disabled');
      expect(elifeStatusLabel(elifeDisplayStatus({'enabled': true, 'status': 'unknown'})), 'Not tested');
      final t = now.millisecondsSinceEpoch;
      expect(timeAgo(t - 30 * 1000, now: now), '30s ago');
      expect(timeAgo(t - 5 * 60000, now: now), '5m ago');
      expect(timeAgo(t - 3 * 3600000, now: now), '3h ago');
      expect(timeAgo(t - 2 * 86400000, now: now), '2d ago');
    });
  });

  // ---- fareProviderStore / fareAiStats ------------------------------------------
  group('Fare AI config', () {
    test('defaults', () {
      final c = normalizeFareAi(null);
      expect((c.serviceEnabled, c.provider, c.retryAfterValue, c.retryAfterUnit), (true, 'gemini', 1, 'hour'));
      expect(c.models['claude'], 'claude-3-5-haiku-latest');
      expect(c.keys.keys, containsAll(fareAiProviderIds));
    });

    test('tolerant parse: bad provider/retry, key filtering, legacy fields', () {
      final c = normalizeFareAi({
        'provider': 'nope',
        'retryAfterValue': 2.7,
        'retryAfterUnit': 'week',
        'models': {'grok': '  '},
        'grokModel': 'grok-legacy',
        'geminiKey': ' legacy-key ',
        'keys': {
          'chatgpt': [
            {'id': 'k1', 'label': 'Main', 'key': 'sk-1', 'enabled': false},
            {'id': 'k2', 'label': 'No key'},
          ],
        },
      });
      expect(c.provider, 'gemini');
      expect(c.retryAfterValue, 2);
      expect(c.retryAfterUnit, 'hour');
      expect(c.models['grok'], 'grok-legacy');
      expect(c.keysFor('gemini').single.key, 'legacy-key');
      expect(c.keysFor('gemini').single.label, 'Key 1');
      expect(c.keysFor('chatgpt').single.id, 'k1');
      expect(c.keysFor('chatgpt').single.enabled, isFalse);
      expect(c.activeKeyCount('chatgpt'), 0);
    });

    test('JSON round trip', () {
      final c = normalizeFareAi(null).withKeys('groq', [FareAiKey.create(id: 'g1', label: 'L', key: 'gsk')]);
      final back = normalizeFareAi(c.toJson());
      expect(back.keysFor('groq').single.id, 'g1');
      expect(back.toJson(), c.toJson());
    });

    test('retry policy and parsing', () {
      expect(retryPolicyMs(2, 'hour'), 2 * 3600000);
      expect(retryPolicyMs(1, 'day'), 86400000);
      expect(retryPolicyMs(1, 'month'), 30 * 86400000);
      expect(retryPolicyMs(0, 'hour'), 3600000);
      expect(parseRetryValue('12a'), 12);
      expect(parseRetryValue(''), 1);
      expect(parseRetryValue('0'), 1);
      expect(retryLabel(normalizeFareAi({'retryAfterValue': 3, 'retryAfterUnit': 'day'})), '3 days');
    });

    test('cooldown and relative time', () {
      final now = DateTime.utc(2026, 1, 1, 12);
      expect(isCoolingDown(null, now: now), isFalse);
      expect(isCoolingDown('2026-01-01T13:00:00Z', now: now), isTrue);
      expect(isCoolingDown('2026-01-01T11:00:00Z', now: now), isFalse);
      expect(formatRelative(null), '—');
      expect(formatRelative('2026-01-01T12:30:00Z', now: now), 'in 30m');
      expect(formatRelative('2026-01-01T09:00:00Z', now: now), '3h ago');
      expect(formatRelative('2026-01-01T12:00:10Z', now: now), 'just now');
    });

    test('labels, summary and tolls', () {
      expect(fareAiProviderLabel('claude'), 'Claude (Anthropic)');
      expect(fareAiProviderLabel('other'), 'other');
      expect(fareAiProviderLabel(''), '—');
      expect(responseSummary([{'success': true}, {'success': false}]), (total: 2, passed: 1, failed: 1));
      expect(tollHeadline({'toll_count': 0}), isNull);
      expect(tollHeadline({'toll_count': 2, 'toll_total': 5.5}), 'Tolls: 2 booths · 5.5 total');
      expect(tollHeadline({'tolls': [{'charge': 1}]}), 'Tolls: 1 booth');
    });
  });

  // ---- backend diagnostics -----------------------------------------------------
  group('backend diagnostics', () {
    test('host, ref and masked anon key', () {
      expect(backendHost('https://abcd.supabase.co/'), 'abcd.supabase.co');
      expect(projectRef('https://abcd.supabase.co'), 'abcd');
      expect(projectRef(''), '');
      expect(maskAnonKey(''), '(not set)');
      final masked = maskAnonKey('eyJhbGciOiJIUzI1NiJ9.payload.signature');
      expect(masked, 'eyJhbGciOi…');
    });

    test('jwtRole reads the role claim without verifying', () {
      // {"role":"anon"} base64url-encoded, no padding.
      expect(jwtRole('x.eyJyb2xlIjoiYW5vbiJ9.y'), 'anon');
      expect(jwtRole('not-a-jwt'), isNull);
    });

    test('health message', () {
      expect(describeHealth(200), (ok: true, message: 'Reachable (HTTP 200)'));
      expect(describeHealth(503).ok, isFalse);
    });
  });

  group('module', () {
    test('owns no settings categories and every path is under /admin/m/', () {
      expect(securityOwnedCategories, isEmpty);
      for (final e in securityEntries) {
        expect(e.path, startsWith('/admin/m/'));
        expect(e.pages.first, startsWith('admin-'));
      }
    });
  });
}
