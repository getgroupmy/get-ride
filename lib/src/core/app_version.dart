// Admin → Settings → App Version: which builds must update before they may
// be used, and which are only told a newer one exists. Pure, so the rules
// are tested without a database or a platform.

/// One `app-version-setting` row.
class AppVersionRule {
  const AppVersionRule({
    required this.platform,
    required this.latest,
    this.minVersion,
    this.forceUpdate = false,
    this.storeUrl,
  });

  /// Free text from the admin form ("iOS", "Android", "All"…).
  final String platform;

  /// The newest published version.
  final String latest;

  /// Builds older than this must update.
  final String? minVersion;

  /// Every build older than [latest] must update.
  final bool forceUpdate;

  /// Where the update button sends the user; see [updateStoreUrl].
  final String? storeUrl;

  /// Null when the row has no usable latest version: a half-filled row must
  /// never be what locks a driver out of the app.
  static AppVersionRule? fromValues(Map<String, dynamic> values) {
    String? text(String key) {
      final v = '${values[key] ?? ''}'.trim();
      return v.isEmpty ? null : v;
    }

    final latest = text('version');
    if (latest == null || parseVersion(latest) == null) return null;
    final min = text('minVersion');
    final force = values['forceUpdate'];
    return AppVersionRule(
      platform: text('platform') ?? '',
      latest: latest,
      minVersion: min != null && parseVersion(min) != null ? min : null,
      forceUpdate: force == true || force == 'true',
      storeUrl: text('storeUrl'),
    );
  }
}

/// `1.4.3`, `v1.4`, `1.4.3+12` or `1.4.3-beta` → `[1, 4, 3]`; the build
/// number and any pre-release tag are not part of the comparison. Null for
/// anything that does not start with a number.
List<int>? parseVersion(String raw) {
  var s = raw.trim().toLowerCase();
  if (s.startsWith('v')) s = s.substring(1);
  s = s.split(RegExp(r'[+\-\s]')).first;
  if (s.isEmpty) return null;
  final parts = <int>[];
  for (final p in s.split('.')) {
    final n = int.tryParse(p);
    if (n == null) return parts.isEmpty ? null : parts;
    parts.add(n);
  }
  return parts;
}

/// Negative when [a] is older than [b], zero when equal (missing parts count
/// as 0, so `1.4` == `1.4.0`), positive when newer. Unparseable versions
/// compare equal, so they never trigger an update.
int compareVersions(String a, String b) {
  final x = parseVersion(a), y = parseVersion(b);
  if (x == null || y == null) return 0;
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// The platform a row names, normalised: `ios`, `android`, `all`, or the
/// lower-cased text for anything else (`windows`, `macos`…).
String rulePlatform(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty || s == '*' || s == 'all' || s == 'both' || (s.contains('ios') && s.contains('android'))) return 'all';
  if (s.contains('ios') || s.contains('iphone') || s.contains('ipad') || s == 'apple') return 'ios';
  if (s.contains('android') || s.contains('huawei')) return 'android';
  return s;
}

enum UpdateKind { none, optional, required }

class UpdateVerdict {
  const UpdateVerdict(this.kind, {this.latest, this.storeUrl});
  const UpdateVerdict.none() : this(UpdateKind.none);

  final UpdateKind kind;
  final String? latest;
  final String? storeUrl;
}

/// What this build must do. [platform] is `ios`, `android`, `web`,
/// `windows`… A row for this platform wins over an "All" row; the web build
/// is always the latest one, so it is never asked to update.
UpdateVerdict resolveUpdate(List<AppVersionRule> rules, {required String platform, required String current}) {
  if (platform == 'web' || parseVersion(current) == null) return const UpdateVerdict.none();
  AppVersionRule? rule;
  for (final r in rules) {
    if (rulePlatform(r.platform) == platform) {
      rule = r;
      break;
    }
  }
  rule ??= rules.where((r) => rulePlatform(r.platform) == 'all').firstOrNull;
  if (rule == null || compareVersions(current, rule.latest) >= 0) {
    // Already on (or past) the latest; a min version above latest is an
    // admin typo, not a reason to lock everyone out.
    return const UpdateVerdict.none();
  }
  final belowMin = rule.minVersion != null && compareVersions(current, rule.minVersion!) < 0;
  final url = updateStoreUrl(platform, rule.storeUrl);
  return UpdateVerdict(
    rule.forceUpdate || belowMin ? UpdateKind.required : UpdateKind.optional,
    latest: rule.latest,
    storeUrl: url,
  );
}

/// The app's Android package (`android/app/build.gradle.kts`).
const androidPackage = 'com.taxxee.teksi';

/// The app's App Store listing. Unlike the Play address it can't be derived
/// from the bundle id (App Store pages are per-app numbers), so it is fixed
/// here.
const iosAppStoreUrl = 'https://apps.apple.com/my/app/teksi-bid-agree-ride/id6457262236';

/// The row's own link when it is a web/store link, else the app's own
/// listing: the Play page on Android, the App Store page on iOS.
String? updateStoreUrl(String platform, String? configured) {
  final c = configured?.trim() ?? '';
  final scheme = Uri.tryParse(c)?.scheme.toLowerCase() ?? '';
  if (c.isNotEmpty && !c.contains(' ') && const {'https', 'http', 'market', 'itms-apps'}.contains(scheme)) return c;
  if (platform == 'android') return 'https://play.google.com/store/apps/details?id=$androidPackage';
  if (platform == 'ios') return iosAppStoreUrl;
  return null;
}
