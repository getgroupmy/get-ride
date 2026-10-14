// Admin → App Settings → App updates: the latest and minimum version for the
// iOS and Android apps, one Force update switch over both, and which
// versions accounts are on (profiles.app_version, migration 0176). Saves the
// same `app-version-setting` rows the App Version page lists, which the
// apps' update gate reads (core/app_version.dart). Pure.
import '../../../core/app_version.dart';
import '../../admin_categories.g.dart';
import '../../admin_settings_models.dart';

/// The `app-version-setting` category.
final appVersionCategory = crudCategories.firstWhere((c) => c.key == 'app-version-setting');

/// The platforms the card edits, in order.
const appUpdatePlatforms = ['ios', 'android'];

String appUpdatePlatformLabel(String platform) => switch (platform) {
  'ios' => 'iOS',
  'android' => 'Android',
  '' => 'Unknown',
  _ => platform[0].toUpperCase() + platform.substring(1),
};

/// The row the apps on [platform] read: its own row, else none (an "All" row
/// is left to the App Version page).
SettingEntry? appUpdateRowFor(List<SettingEntry> rows, String platform) {
  for (final r in rows) {
    if (rulePlatform('${r.values['platform'] ?? ''}') == platform) return r;
  }
  return null;
}

/// Whether Force update is on: any of the two platforms' rows forces it.
bool forceUpdateOn(List<SettingEntry> rows) {
  for (final p in appUpdatePlatforms) {
    final f = appUpdateRowFor(rows, p)?.values['forceUpdate'];
    if (f == true || f == 'true') return true;
  }
  return false;
}

/// What is wrong with a platform's versions, or null when they can be
/// saved. [latest] is required; [min] may be blank, never above [latest].
String? appUpdateProblem(String latest, String min) {
  final l = latest.trim(), m = min.trim();
  if (l.isEmpty) return 'Enter the latest version, e.g. 1.4.6.';
  if (parseVersion(l) == null) return 'Write the version as numbers, e.g. 1.4.6.';
  if (m.isEmpty) return null;
  if (parseVersion(m) == null) return 'Write the minimum as numbers, e.g. 1.4.5.';
  if (compareVersions(m, l) > 0) return "The minimum can't be newer than the latest.";
  return null;
}

/// The row's values after an edit: the other fields (store link, platform
/// name) as they were.
Map<String, dynamic> appUpdateValues(
  Map<String, dynamic>? stored, {
  required String platform,
  required String latest,
  required String min,
  required bool force,
}) => {
  ...?stored,
  'platform': '${stored?['platform'] ?? ''}'.trim().isEmpty ? appUpdatePlatformLabel(platform) : stored!['platform'],
  'version': latest.trim(),
  'minVersion': min.trim(),
  'forceUpdate': force,
};

/// One line of the installed-versions list.
typedef InstalledCount = ({String platform, String version, int accounts, bool behind});

/// Accounts per platform and version, newest version first; [behind] marks
/// versions older than that platform's [latest] (the ones Force update
/// stops). Rows without a recorded version are left out.
List<InstalledCount> installedVersionCounts(List<Map<String, dynamic>> profiles, Map<String, String> latest) {
  final counts = <(String, String), int>{};
  for (final p in profiles) {
    final v = '${p['app_version'] ?? ''}'.trim();
    final platform = '${p['app_platform'] ?? ''}'.trim().toLowerCase();
    if (v.isEmpty || platform.isEmpty) continue;
    counts.update((platform, v), (n) => n + 1, ifAbsent: () => 1);
  }
  final out = [
    for (final e in counts.entries)
      (
        platform: e.key.$1,
        version: e.key.$2,
        accounts: e.value,
        behind: latest[e.key.$1] != null && compareVersions(e.key.$2, latest[e.key.$1]!) < 0,
      ),
  ];
  out.sort((a, b) {
    final p = appUpdatePlatforms.indexOf(a.platform).compareTo(appUpdatePlatforms.indexOf(b.platform));
    if (p != 0) return p;
    return compareVersions(b.version, a.version);
  });
  return out;
}
