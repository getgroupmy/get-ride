import 'package:flutter/material.dart';

import '../../core/app_branding.dart';
import '../../data/branding_cache.dart';

/// The admin's splash image on its background colour, laid over the app for
/// [splashHold] after launch and then faded out (Expo `SplashScreenComponent`).
/// The app builds underneath from the first frame, so the splash costs no
/// start-up time. Without a cached image there is no splash at all.
class BrandSplash extends StatefulWidget {
  const BrandSplash({super.key, required this.cached, required this.child, this.hold = splashHold});

  final CachedBranding? cached;
  final Widget child;
  final Duration hold;

  @override
  State<BrandSplash> createState() => _BrandSplashState();
}

class _BrandSplashState extends State<BrandSplash> {
  late bool _visible = widget.cached?.branding.showsSplash ?? false;
  late bool _mounted = _visible;

  @override
  void initState() {
    super.initState();
    if (_visible) {
      Future.delayed(widget.hold, () {
        if (mounted) setState(() => _visible = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cached = widget.cached;
    if (!_mounted || cached == null) return widget.child;
    final b = cached.branding;
    final bytes = cached.imageBytes;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IgnorePointer(
          ignoring: !_visible,
          child: AnimatedOpacity(
            key: const ValueKey('brand-splash'),
            opacity: _visible ? 1 : 0,
            duration: splashFade,
            onEnd: () {
              if (!_visible && mounted) setState(() => _mounted = false);
            },
            child: ColoredBox(
              color: b.background,
              child: Center(
                child: SizedBox.square(
                  dimension: 280,
                  child: bytes != null
                      ? Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true)
                      : Image.network(
                          b.splashImageUrl!,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
