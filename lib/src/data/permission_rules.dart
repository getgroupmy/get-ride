// Admin → App Settings → Permissions (migration 0196): which checks riders
// (before the home map) and partners (before going online) are held to, and
// whether Settings shows the Permissions card. Live: an admin's change
// applies at once.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_permissions.dart';
import '../providers.dart';
import 'live_tables.dart';

/// The rules; everything enforced and the card shown when they can't be read
/// (a database before 0196, no signal).
final permissionRulesProvider = FutureProvider<PermissionRules>((ref) async {
  ref.watchLive('app_settings');
  try {
    return PermissionRules.fromJson(await ref.watch(supabaseProvider).rpc('permission_rules'));
  } catch (_) {
    return PermissionRules.defaults;
  }
});

/// Saves the admin's rules (admins only, set_permission_rules) and answers
/// what the server now holds.
Future<PermissionRules> savePermissionRules(SupabaseClient db, PermissionRules rules) async =>
    PermissionRules.fromJson(await db.rpc('set_permission_rules', params: {'p_rules': rules.toJson()}));
