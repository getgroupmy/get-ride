import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../admin/screens/security/ip_access_logic.dart';
import '../admin/screens/security/security_data.dart';
import '../core/session_telemetry.dart' show launchIp;
import 'live_tables.dart';

/// What a blacklisted device is told (Expo `phone-auth` / `ride-confirm`).
const serviceNotAvailable = 'Service Not Available';

/// Whether this device's public IP is on the admin's blacklist
/// (`ip_access_rules`, Expo `IpAccessContext`). Resolved once per app run;
/// any failure (offline, no providers, query refused) fails open, as in Expo.
///
/// Expo's other use of the rules, letting a whitelisted IP skip the admin
/// PIN, is deliberately not ported: an IP address is not a credential.
/// The IP ip-lookup already found this launch (session rows) is reused.
final deviceBlockedProvider = FutureProvider<bool>((ref) async {
  ref.watchLive('ip_access_rules');
  try {
    final ip = launchIp.value?.publicIp ?? await lookupPublicIp();
    if (ip == null) return false;
    final type = await ref.read(securityRepositoryProvider).evaluateIp(ip);
    return type == IpListType.blacklist;
  } catch (_) {
    return false;
  }
});

/// How long a tap waits for a device check still under way.
const deviceCheckTapWait = Duration(milliseconds: 1500);

/// [check], or false (fail open) when it fails or takes longer than [wait]:
/// the check started when the screen opened, and the server checks again.
Future<bool> deviceBlockedWithin(Future<bool> check, {Duration wait = deviceCheckTapWait}) =>
    check.timeout(wait, onTimeout: () => false).catchError((Object _) => false);
