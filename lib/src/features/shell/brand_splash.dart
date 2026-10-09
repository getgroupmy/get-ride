import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_branding.dart';
import '../../data/branding_cache.dart';
import '../../widgets/net_image.dart';

/// Holds the app behind the splash for what is left of [splashHold] since the
/// process started, then shows it (iAkauntan's `SplashGate`). In the Android
/// and iOS apps only; elsewhere this is its child and nothing else.
///
/// The app is not built until the splash is done, so nothing it asks for on
/// its first screen (a location prompt, a restored ride) appears over it.
class SplashGate extends StatefulWidget {
  const SplashGate({super.key, required this.child, this.cached, this.live, this.held, this.now});

  final Widget child;

  /// The branding the last launch cached, so the picture paints at once.
  final CachedBranding? cached;

  /// The branding fetched by this launch, which wins once it arrives — so a
  /// fresh install, with nothing cached, still shows the admin's picture.
  final ValueListenable<AppBranding?>? live;

  /// Whether this surface holds a splash; null asks [splashHeld]. For tests.
  final bool? held;

  /// The clock; null is [DateTime.now]. For tests.
  final DateTime Function()? now;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  bool _done = false;

  @override
  void initState() {
    super.initState();
    final held = widget.held ?? splashHeld(isWeb: kIsWeb, platform: defaultTargetPlatform);
    final left = held ? splashRemaining((widget.now ?? DateTime.now)()) : Duration.zero;
    if (left == Duration.zero) {
      _done = true;
      return;
    }
    Future<void>.delayed(left, () {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final live = widget.live;
    if (live == null) return SplashView(cached: widget.cached, dark: dark);
    return ValueListenableBuilder<AppBranding?>(
      valueListenable: live,
      builder: (_, latest, _) => SplashView(cached: widget.cached, latest: latest, dark: dark),
    );
  }
}

/// The splash itself: the admin's picture, else "GET." in the brand blue,
/// on white or black or the admin's backgrounds.
class SplashView extends StatelessWidget {
  const SplashView({super.key, this.cached, this.latest, required this.dark});

  final CachedBranding? cached;
  final AppBranding? latest;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final branding = latest ?? cached?.branding;
    final name = Text(
      splashWordmark,
      key: const ValueKey('splash-wordmark'),
      textAlign: TextAlign.center,
      style: TextStyle(
        color: splashInk(dark: dark, branding: branding),
        fontSize: 40,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
      ),
    );
    Widget fallback(BuildContext _, Object _, StackTrace? _) => name;

    final url = branding?.splashImageUrl;
    final bytes = cached?.imageBytes;
    final Widget picture;
    if (url == null) {
      picture = name;
    } else if (bytes != null && url == cached?.branding.splashImageUrl) {
      picture = Image.memory(bytes, key: const ValueKey('splash-image'), height: 120, errorBuilder: fallback);
    } else {
      picture = Image.network(url, key: const ValueKey('splash-image'), height: 120, frameBuilder: boneUntilPainted(width: 120, height: 120), errorBuilder: fallback);
    }
    return Container(
      key: const ValueKey('splash'),
      color: splashBackground(dark: dark, branding: branding),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: picture,
    );
  }
}
