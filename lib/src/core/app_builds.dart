// The latest build of this app for installing directly: what the
// `app-install` edge function says about the `ios-latest` / `android-latest`
// GitHub releases the release workflows publish, and the links built from it
// (Admin → App Release, and the public getride.my/install/<platform> page).
import 'ride_share.dart';

/// The two platforms with a downloadable build.
const appBuildPlatforms = ['ios', 'android'];

class AppBuild {
  const AppBuild({
    required this.platform,
    this.available = false,
    this.version,
    this.build,
    this.size,
    this.installable = false,
    this.runNumber,
    this.createdAt,
    this.downloadUrl,
    this.installUrl,
    this.bundleUrl,
    this.bundleSize,
  });

  final String platform;
  final bool available;
  final String? version;
  final String? build;
  final int? size;

  /// A phone can install it from [installUrl]. An iPhone build only when it
  /// is Ad Hoc signed (an App Store IPA downloads, but won't install).
  final bool installable;
  final String? runNumber;
  final DateTime? createdAt;

  /// The .ipa / .apk itself.
  final String? downloadUrl;

  /// What installs it on a phone: the itms-services link, or the APK.
  final String? installUrl;

  /// Android: the App Bundle (.aab) Play takes, for a hand upload. It
  /// installs on no phone, so it is downloaded and never shared.
  final String? bundleUrl;
  final int? bundleSize;

  bool get ios => platform == 'ios';

  factory AppBuild.fromJson(String platform, Object? json) {
    if (json is! Map) return AppBuild(platform: platform);
    String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    String? https(Object? v) {
      final s = text(v);
      return s != null && (s.startsWith('https://') || s.startsWith('itms-services://')) ? s : null;
    }

    final download = https(json['download_url']);
    return AppBuild(
      platform: platform,
      available: json['available'] == true && download != null,
      version: text(json['version']),
      build: text(json['build']),
      size: json['size'] is num ? (json['size'] as num).toInt() : null,
      installable: json['installable'] == true && https(json['install_url']) != null,
      runNumber: text(json['run_number']),
      createdAt: DateTime.tryParse(text(json['created_at']) ?? '')?.toLocal(),
      downloadUrl: download,
      installUrl: https(json['install_url']),
      bundleUrl: platform == 'android' && text(json['bundle_url'])?.startsWith('https://') == true
          ? text(json['bundle_url'])
          : null,
      bundleSize: json['bundle_size'] is num ? (json['bundle_size'] as num).toInt() : null,
    );
  }

  /// "1.4.3 (107)", or as much of it as is known.
  String get label => switch ((version, build)) {
    (final v?, final b?) => '$v ($b)',
    (final v?, null) => v,
    (null, final b?) => 'Build $b',
    _ => 'Latest build',
  };

  /// What the downloaded file is.
  String get fileName => ios ? 'getride.ipa' : 'getride.apk';
}

/// "52.3 MB": a file size as people read it.
String formatBuildSize(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0 ? '$bytes B' : '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

/// The page a tester opens (or scans) to install the latest build.
String appInstallPageUrl(String platform, {String base = rideShareBase}) => '$base/install/$platform';

/// The message sent with an install link.
String appInstallShareText(AppBuild b, {String base = rideShareBase}) =>
    'Install GET.ride ${b.label} for ${b.ios ? 'iPhone' : 'Android'}: ${appInstallPageUrl(b.platform, base: base)}';

/// What the tester needs to know before tapping Install.
String appInstallHint(AppBuild b) {
  if (!b.available) return 'No build has been published for ${b.ios ? 'iPhone' : 'Android'} yet.';
  if (b.ios && !b.installable) {
    return 'This iPhone build is App Store signed: it can be downloaded (for Transporter), '
        "but not installed directly. Use TestFlight, or add an Ad Hoc profile to the release workflow.";
  }
  if (b.ios) {
    return 'Open this page in Safari on the iPhone and tap Install. It only installs on iPhones '
        'registered in the Ad Hoc profile.';
  }
  return 'Open this page on the Android phone and tap Install, then allow installs from your browser '
      'when asked. If GET.ride from Google Play is installed, remove it first: this build is signed differently.';
}
