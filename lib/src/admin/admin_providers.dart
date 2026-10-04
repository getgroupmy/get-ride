import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'admin_access.dart';
import 'admin_repository.dart';

final adminRepositoryProvider = Provider((ref) => AdminRepository(ref.watch(supabaseProvider)));

/// The signed-in user's admin grants; re-resolved on every auth change.
final adminAccessProvider = FutureProvider<AdminAccess>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return AdminAccess.none;
  try {
    return await ref.watch(adminRepositoryProvider).myAccess();
  } catch (_) {
    return AdminAccess.none;
  }
});

/// Access to one admin module, for gating buttons in its screens.
final moduleAccessProvider = Provider.family<AccessLevel, String>((ref, moduleId) {
  final access = ref.watch(adminAccessProvider).value ?? AdminAccess.none;
  final module = adminModules[moduleId];
  return module == null ? AccessLevel.none : access.levelFor(module.pages);
});
