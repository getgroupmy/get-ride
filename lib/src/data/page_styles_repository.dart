import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/page_styles.dart';
import '../providers.dart';
import 'app_display_repository.dart' show appSettingsReadTimeout;
import 'live_tables.dart';

/// Admin → Settings → App Page Settings: every surface's values (public read
/// of the `page_style:` rows of `app_settings`). Live: an admin's save
/// re-reads them on every open app. Unreachable keeps what this session (or,
/// at launch, this device) last read; nothing read is the app's own look.
final pageStylesProvider = FutureProvider<PageStyles>((ref) async {
  ref.watchLive('app_settings');
  try {
    final rows = await ref
        .watch(supabaseProvider)
        .from('app_settings')
        .select('key, value')
        .like('key', 'page_style:%')
        .timeout(appSettingsReadTimeout);
    final styles = _last = PageStyles.fromRows(List<Map<String, dynamic>>.from(rows));
    unawaited(_keep(styles));
    return styles;
  } catch (_) {
    return _last ?? decodePageStyles(await _kept()) ?? PageStyles.none;
  }
});

PageStyles? _last;
const _keptKey = 'page_styles_v1';

Future<String?> _kept() async {
  try {
    return (await SharedPreferences.getInstance()).getString(_keptKey);
  } catch (_) {
    return null;
  }
}

Future<void> _keep(PageStyles s) async {
  try {
    await (await SharedPreferences.getInstance()).setString(_keptKey, jsonEncode(s.values));
  } catch (_) {}
}

/// [PageStyles] kept on the device, or null for nothing readable. Pure.
PageStyles? decodePageStyles(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final j = jsonDecode(raw);
    if (j is! Map) return null;
    return PageStyles({
      for (final e in j.entries)
        if (e.value is Map) '${e.key}': Map<String, Object?>.from(e.value as Map),
    });
  } catch (_) {
    return null;
  }
}

/// Admin: saves [surface]'s values; none left removes its row (back to the
/// app-wide values and the app's own look).
Future<void> savePageStyle(SupabaseClient db, String surface, Map<String, Object?> values) async {
  final key = pageStyleKey(surface);
  if (values.isEmpty) {
    await db.from('app_settings').delete().eq('key', key);
    return;
  }
  await db.from('app_settings').upsert({
    'key': key,
    'value': values,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  }, onConflict: 'key');
}
