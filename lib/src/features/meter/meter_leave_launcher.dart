import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// What the leave-the-meter popup does to the device (Expo `utils/appExit.ts`
/// and the `Linking.openURL` half of `meterLeave.ts`). A seam so tests can
/// see what the popup asked for without leaving the test.
class MeterLeaveLauncher {
  const MeterLeaveLauncher();

  /// `ios` | `android` | `web` | … — what `describeMeterExit` and
  /// `resolveMeterLeave` are asked about. Huawei is reported as Android: the
  /// app has no manufacturer lookup, so a card's AppGallery page isn't used.
  String get os {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios',
      TargetPlatform.android => 'android',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }

  /// Only Android lets an app close itself (by decision, see
  /// `describeMeterExit`).
  bool get canExit => os == 'android';

  /// Closes the app; the driver stays signed in.
  Future<void> exit() => SystemNavigator.pop();

  /// Opens a dispatch app or store page. False when nothing on the device
  /// took it — overwhelmingly, the app isn't installed.
  ///
  /// An Android package link (`intent://#Intent;package=…;end`, the way into
  /// an app without knowing its scheme) is started as that package's launcher
  /// activity: url_launcher only sends a VIEW intent, which nothing answers
  /// for an `intent:` link.
  Future<bool> open(String url) async {
    final package = RegExp(r'^intent:.*[#;]package=([^;]+)').firstMatch(url)?.group(1);
    if (package != null) {
      if (os != 'android') return false;
      try {
        await AndroidIntent(
          action: 'android.intent.action.MAIN',
          category: 'android.intent.category.LAUNCHER',
          package: package,
        ).launch();
        return true;
      } catch (_) {
        return false;
      }
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}

final meterLeaveLauncherProvider = Provider<MeterLeaveLauncher>((_) => const MeterLeaveLauncher());
