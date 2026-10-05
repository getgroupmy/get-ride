import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../admin/screens/security/ip_access_logic.dart';
import '../admin/screens/security/security_data.dart';

/// What a blacklisted device is told (Expo `phone-auth` / `ride-confirm`).
const serviceNotAvailable = 'Service Not Available';

/// Whether this device's public IP is on the admin's blacklist
/// (`ip_access_rules`, Expo `IpAccessContext`). Resolved once per app run;
/// any failure (offline, no providers, query refused) fails open, as in Expo.
///
/// Expo's other use of the rules, letting a whitelisted IP skip the admin
/// PIN, is deliberately not ported: an IP address is not a credential.
final deviceBlockedProvider = FutureProvider<bool>((ref) async {
  try {
    final ip = await lookupPublicIp();
    if (ip == null) return false;
    final type = await ref.read(securityRepositoryProvider).evaluateIp(ip);
    return type == IpListType.blacklist;
  } catch (_) {
    return false;
  }
});
