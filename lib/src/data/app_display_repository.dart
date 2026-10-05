import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_display.dart';
import '../providers.dart';

/// The admin display settings the rider app honours (public read of
/// `admin_display_settings`, row `global`). Unreachable or missing means the
/// defaults: the service stays on and sign-up stays open.
final appDisplayProvider = FutureProvider<AppDisplay>((ref) async {
  try {
    final row = await ref
        .watch(supabaseProvider)
        .from('admin_display_settings')
        .select('settings')
        .eq('id', 'global')
        .maybeSingle();
    return AppDisplay.fromSettings(row?['settings']);
  } catch (_) {
    return const AppDisplay();
  }
});
