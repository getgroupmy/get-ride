/// Pure helpers for the read-only Backend diagnostics page (the Flutter take
/// on `expo/app/admin-settings-supabase.tsx`). The backend is fixed at build
/// time (`--dart-define=SUPABASE_URL / SUPABASE_ANON_KEY`), so nothing here
/// edits or stores connection settings.
library;

import 'dart:convert';

/// Host of the configured URL ("" when unparsable).
String backendHost(String url) => Uri.tryParse(url.trim())?.host ?? '';

/// Project ref = first label of a `*.supabase.co` host (Expo `derivedRef`).
String projectRef(String url) {
  final host = backendHost(url);
  if (host.isEmpty) return '';
  return host.split('.').first;
}

/// Shows only a short prefix of the anon key. The anon key is public by
/// design, but there is no reason to put the whole JWT on screen.
String maskAnonKey(String key) {
  final k = key.trim();
  if (k.isEmpty) return '(not set)';
  if (k.length <= 12) return '••••';
  return '${k.substring(0, 10)}…';
}

/// Role claim of a Supabase JWT ("anon", "service_role", …) without
/// verifying it — used only to warn if a build was given the wrong key.
String? jwtRole(String jwt) {
  final parts = jwt.split('.');
  if (parts.length != 3) return null;
  try {
    final decoded = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final claims = jsonDecode(decoded);
    return claims is Map ? claims['role'] as String? : null;
  } catch (_) {
    return null;
  }
}

/// Message for the `/auth/v1/health` probe.
({bool ok, String message}) describeHealth(int status) => status >= 200 && status < 300
    ? (ok: true, message: 'Reachable (HTTP $status)')
    : (ok: false, message: 'Endpoint responded HTTP $status');
