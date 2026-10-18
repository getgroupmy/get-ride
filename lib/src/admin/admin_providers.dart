import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'admin_access.dart';
import 'admin_repository.dart';
import '../data/live_tables.dart';

final adminRepositoryProvider = Provider((ref) => AdminRepository(ref.watch(supabaseProvider)));

/// The signed-in user's admin grants; re-resolved on every auth change and
/// whenever access rules change (in the background: see AdminShell). A
/// re-read that fails keeps the grants this account already had, so a
/// dropped connection never turns an admin away mid-task.
final adminAccessProvider = FutureProvider<AdminAccess>((ref) async {
  ref.watchLive('admin_access');
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return AdminAccess.none;
  try {
    return _lastAccess[uid] = await ref.watch(adminRepositoryProvider).myAccess();
  } catch (_) {
    return _lastAccess[uid] ?? AdminAccess.none;
  }
});

final _lastAccess = <String, AdminAccess>{};

/// Access to one admin module, for gating buttons in its screens.
final moduleAccessProvider = Provider.family<AccessLevel, String>((ref, moduleId) {
  final access = ref.watch(adminAccessProvider).value ?? AdminAccess.none;
  final module = adminModules[moduleId];
  return module == null ? AccessLevel.none : access.levelFor(module.pages);
});

/// Access to specific Expo page keys (ported screens check their own page,
/// plus `admin-settings` for anything on the Settings hub).
final pageAccessProvider = Provider.family<AccessLevel, String>((ref, pageKey) {
  final access = ref.watch(adminAccessProvider).value ?? AdminAccess.none;
  return access.levelFor([pageKey, 'admin-settings']);
});
