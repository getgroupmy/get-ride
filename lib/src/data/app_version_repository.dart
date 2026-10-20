import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_version.dart';
import '../providers.dart';
import 'live_tables.dart';
import '../core/installed_app.dart';

/// Admin → Settings → App Version rows. Empty when unreadable, which means
/// no update is asked for: an outage must never lock drivers out.
final appVersionRulesProvider = FutureProvider<List<AppVersionRule>>((ref) async {
  ref.watchLive('settings_entries');
  try {
    final rows = await ref
        .watch(supabaseProvider)
        .from('settings_entries')
        .select('values, position')
        .eq('category', 'app-version-setting')
        .order('position', ascending: true).order('created_at', ascending: true);
    return [
      for (final r in rows)
        if (r['values'] is Map) ?AppVersionRule.fromValues(Map<String, dynamic>.from(r['values'] as Map)),
    ];
  } catch (_) {
    return const [];
  }
});

/// `web`, `ios`, `android`, `windows`, `macos`, `linux`.
String currentPlatformKey() => kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase();

/// What this build must do about the admin's App Version rows.
final appUpdateProvider = FutureProvider<UpdateVerdict>((ref) async {
  final rules = await ref.watch(appVersionRulesProvider.future);
  return resolveUpdate(rules, platform: currentPlatformKey(), current: InstalledApp.version);
});

/// Keeps the signed-in account's app version on its profile (migration
/// 0176), for Admin → App Settings → App updates. Best effort: a database
/// without 0176, or no signal, just leaves the last one recorded.
Future<void> recordAppVersion(SupabaseClient db) async {
  if (db.auth.currentUser == null) return;
  try {
    await db.rpc(
      'record_app_version',
      params: {'p_version': InstalledApp.version, 'p_build': InstalledApp.build, 'p_platform': currentPlatformKey()},
    );
  } catch (_) {}
}
