// The version this build really is, read from the platform at launch
// (pubspec's `version:`, as the stores see it). The update gate compares it
// with Admin → App Settings → App updates, and every launch records it.
import 'package:package_info_plus/package_info_plus.dart';

import '../config.dart';
import 'app_version.dart';

class InstalledApp {
  InstalledApp._();

  /// `1.4.6`; [AppConfig.appVersion] until [load] has read the platform's.
  static String version = AppConfig.appVersion;

  /// The build number (`+1` in pubspec), when the platform gives one.
  static String? build;

  /// Reads the installed version. Never throws: a platform that can't say
  /// keeps the compiled-in one.
  static Future<void> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (parseVersion(info.version) != null) version = info.version;
      build = info.buildNumber.trim().isEmpty ? null : info.buildNumber.trim();
    } catch (_) {}
  }
}
