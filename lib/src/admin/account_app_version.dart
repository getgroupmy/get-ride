// The app version an account last opened GET.ride with (profiles.app_version,
// recorded at every launch and sign-in since 1.4.6, migration 0176), as the
// admin Users list and detail show it. Pure.
import '../core/app_version.dart';

String _platform(String p) => switch (p.trim().toLowerCase()) {
  'ios' => 'iOS',
  'android' => 'Android',
  '' => '',
  final o => o[0].toUpperCase() + o.substring(1),
};

String _ago(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 60) return d.inDays == 1 ? '1 day ago' : '${d.inDays} days ago';
  return '${(d.inDays / 30).floor()} months ago';
}

/// "1.4.6", or null when the account has none recorded (an older build, or
/// it hasn't opened the app since 1.4.6).
String? accountAppVersionShort(Map<String, dynamic> u) {
  final v = '${u['app_version'] ?? ''}'.trim();
  return v.isEmpty ? null : v;
}

/// "Android 1.4.6 (12) · 3 h ago", or "Not recorded".
String accountAppVersion(Map<String, dynamic> u, {DateTime? now}) {
  final v = accountAppVersionShort(u);
  if (v == null) return 'Not recorded (before 1.4.6)';
  final build = '${u['app_build'] ?? ''}'.trim();
  final head = [
    _platform('${u['app_platform'] ?? ''}'),
    build.isEmpty ? v : '$v ($build)',
  ].where((s) => s.isNotEmpty).join(' ');
  final at = DateTime.tryParse('${u['app_version_at'] ?? ''}');
  return at == null ? head : '$head · ${_ago(at.toUtc(), (now ?? DateTime.now()).toUtc())}';
}

/// Whether the account's recorded version is older than [latest] (an admin's
/// App updates latest for its platform). False when either is unknown.
bool accountAppBehind(Map<String, dynamic> u, Map<String, String> latest) {
  final v = accountAppVersionShort(u);
  final l = latest['${u['app_platform'] ?? ''}'.trim().toLowerCase()];
  return v != null && l != null && compareVersions(v, l) < 0;
}
