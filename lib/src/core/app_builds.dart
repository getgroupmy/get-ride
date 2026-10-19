// The latest build of this app for installing directly: what the
// `app-install` edge function says about the `ios-latest` / `android-latest`
// GitHub releases the release workflows publish, and the links built from it
// (Admin → App Release, and the public getride.my/install/<platform> page).
//
// Android has one APK per processor (64-bit arm64-v8a, 32-bit armeabi-v7a)
// beside the universal one: a phone is handed its own ([AppBuild.forDevice]),
// 64-bit unless it says it is a 32-bit-only phone, and the universal APK
// when its split was not published.
import 'ride_share.dart';

/// The 64-bit Android ABI: nearly every phone, and the default.
const abiArm64 = 'arm64-v8a';

/// The 32-bit Android ABI: older phones that can't run 64-bit apps.
const abiArm32 = 'armeabi-v7a';

/// The APK that runs on every processor.
const abiUniversal = 'universal';

/// One installable Android APK.
class AppApk {
  const AppApk({required this.abi, required this.url, this.size});

  /// [abiArm64], [abiArm32] or [abiUniversal] (or another ABI app-install names).
  final String abi;
  final String url;
  final int? size;

  /// The file's name, from its address (`getride-arm64-v8a.apk`).
  String get fileName {
    final last = Uri.tryParse(url)?.pathSegments.lastOrNull ?? '';
    return last.endsWith('.apk') ? last : 'getride.apk';
  }
}

/// The ABI whose APK a phone should get, from the ABIs it reports (best
/// first, as Android's `supportedAbis`). Nothing known: 64-bit. An x86 phone
/// (or emulator) with no ARM ABI gets the universal APK.
String wantedApkAbi(List<String> deviceAbis) {
  final abis = deviceAbis.map((a) => a.trim().toLowerCase()).toList();
  if (abis.contains(abiArm64)) return abiArm64;
  if (abis.contains(abiArm32) || abis.contains('armeabi')) return abiArm32;
  if (abis.isNotEmpty && abis.any((a) => a.startsWith('x86'))) return abiUniversal;
  return abiArm64;
}

/// The APK for a phone reporting [deviceAbis]: its own split, else the
/// universal APK, else (a phone that said nothing, or one that also runs
/// it) another split. Null when none fits.
AppApk? pickApk(List<AppApk> apks, List<String> deviceAbis) {
  AppApk? by(String abi) => apks.where((a) => a.abi == abi).firstOrNull;
  final abis = deviceAbis.map((a) => a.trim().toLowerCase()).toSet();
  final want = wantedApkAbi(deviceAbis);
  final own = by(want) ?? by(abiUniversal);
  if (own != null) return own;
  for (final a in apks) {
    if (abis.isEmpty || abis.contains(a.abi)) return a;
  }
  return null;
}

/// The app-install query for [platform]: Android always names the processor
/// to hand out ([wantedApkAbi], 64-bit when [deviceAbis] can't tell), since a
/// request without `abi` gets the universal APK (what old clients get).
Map<String, String> appInstallQuery(String platform, List<String> deviceAbis) => {
  'platform': platform,
  if (platform == 'android') 'abi': wantedApkAbi(deviceAbis),
};

/// What a web page can tell of the phone it runs on: the ABIs, best first,
/// or none when it can't say (most Android browsers no longer name the
/// processor). [bitness] / [architecture] are `navigator.userAgentData`'s
/// high-entropy values, when the browser gives them.
List<String> deviceAbisFromUserAgent(String userAgent, {String? bitness, String? architecture}) {
  final ua = userAgent.toLowerCase();
  final arch = architecture?.trim().toLowerCase() ?? '';
  final bits = bitness?.trim() ?? '';
  if (arch == 'arm' || arch.isEmpty) {
    if (bits == '64') return const [abiArm64, abiArm32];
    if (bits == '32' && arch == 'arm') return const [abiArm32];
  }
  if (!ua.contains('android')) return const [];
  if (ua.contains('aarch64') || ua.contains('arm64')) return const [abiArm64, abiArm32];
  // armv8l: a 64-bit processor running a 32-bit system, which can't
  // install 64-bit apps; armv7l / armv6l: a 32-bit phone.
  if (RegExp(r'armv[678]l|armeabi').hasMatch(ua)) return const [abiArm32];
  if (ua.contains('x86_64')) return const ['x86_64'];
  return const [];
}

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
    this.abi,
    this.apks = const [],
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

  /// Android: which APK [downloadUrl] / [installUrl] are ([abiArm64],
  /// [abiArm32] or [abiUniversal]); null from an app-install that predates
  /// the per-processor APKs.
  final String? abi;

  /// Android: every APK published (the splits first, the universal one last).
  final List<AppApk> apks;

  bool get ios => platform == 'ios';

  /// The published APK for [abi], if there is one.
  AppApk? apkFor(String abi) => apks.where((a) => a.abi == abi).firstOrNull;

  /// This build with the APK for a phone reporting [deviceAbis] as the one
  /// to download and install (see [pickApk]); nothing on offer when none of
  /// them runs on it. Unchanged on iPhone, or when app-install listed no APKs.
  AppBuild forDevice(List<String> deviceAbis) {
    if (ios || apks.isEmpty) return this;
    final apk = pickApk(apks, deviceAbis);
    return apk == null ? AppBuild(platform: platform) : withApk(apk);
  }

  /// This build offering [apk].
  AppBuild withApk(AppApk apk) => AppBuild(
    platform: platform,
    available: available,
    version: version,
    build: build,
    size: apk.size ?? (apk.abi == abiUniversal ? size : null),
    installable: installable,
    runNumber: runNumber,
    createdAt: createdAt,
    downloadUrl: apk.url,
    installUrl: installable ? apk.url : installUrl,
    bundleUrl: bundleUrl,
    bundleSize: bundleSize,
    abi: apk.abi,
    apks: apks,
  );

  /// The other processor's APK a person might need instead: the 32-bit one
  /// beside the 64-bit one, and back. Null when there is no such choice.
  AppApk? get otherApk => switch (abi) {
    abiArm64 => apkFor(abiArm32),
    abiArm32 => apkFor(abiArm64),
    _ => null,
  };

  factory AppBuild.fromJson(String platform, Object? json) {
    if (json is! Map) return AppBuild(platform: platform);
    String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    String? https(Object? v) {
      final s = text(v);
      return s != null && (s.startsWith('https://') || s.startsWith('itms-services://')) ? s : null;
    }

    final download = https(json['download_url']);
    final apks = <AppApk>[
      if (platform == 'android' && json['apks'] is List)
        for (final a in json['apks'] as List)
          if (a is Map && text(a['abi']) != null && text(a['url'])?.startsWith('https://') == true)
            AppApk(
              abi: text(a['abi'])!,
              url: text(a['url'])!,
              size: a['size'] is num ? (a['size'] as num).toInt() : null,
            ),
    ];
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
      abi: platform == 'android' ? text(json['abi']) : null,
      apks: apks,
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
  String get fileName {
    if (ios) return 'getride.ipa';
    final picked = abi == null ? null : apkFor(abi!);
    return picked?.fileName ?? 'getride.apk';
  }
}

/// Whether [url] is the universal APK of the rolling `android-latest`
/// release, which an admin may give as the update link (Admin → Settings →
/// App Version, Store Link).
bool isUniversalApkLink(String url) =>
    RegExp(r'^https://github\.com/[^/]+/[^/]+/releases/download/android-latest/getride\.apk$').hasMatch(url.trim());

/// The update link a phone reporting [deviceAbis] opens: when [configured]
/// is the universal APK, the APK for its own processor from [latest] (what
/// app-install says now); otherwise, or when there is nothing better, as
/// configured.
String updateApkLink(String configured, AppBuild latest, List<String> deviceAbis) {
  if (!isUniversalApkLink(configured) || latest.ios || !latest.available || latest.apks.isEmpty) return configured;
  return pickApk(latest.apks, deviceAbis)?.url ?? configured;
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
