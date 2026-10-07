/// The splash the Android and iOS apps hold for a moment at launch, worked
/// the way iAkauntan's is (`core/splash.dart` there): five seconds counted
/// from when the process started, in the apps only, the admin's picture
/// (Admin → Settings → Splash Screen, `app_branding.splash_image_url`) on
/// white — or black in dark mode — falling back to the app's logo and then
/// its name. Pure: every answer here is testable without a widget.
library;

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show TargetPlatform;

class AppBranding {
  const AppBranding({this.splashImageUrl});

  /// The admin's splash picture, or null where none was uploaded.
  final String? splashImageUrl;

  /// The `app_branding` row; a blank or non-web URL counts as none.
  static AppBranding fromRow(Map<String, dynamic>? row) {
    final v = row?['splash_image_url'];
    final url = v is String ? v.trim() : '';
    return AppBranding(splashImageUrl: url.startsWith('http') ? url : null);
  }

  Map<String, dynamic> toJson() => {'splash_image_url': splashImageUrl};

  @override
  bool operator ==(Object other) => other is AppBranding && other.splashImageUrl == splashImageUrl;

  @override
  int get hashCode => splashImageUrl.hashCode;
}

/// How long the splash is held, once.
const splashHold = Duration(seconds: 5);

/// When this process started, near enough: stamped by [markSplashStart] at
/// the top of `main`, before anything slow. A top-level `final` would be
/// initialised lazily on its first read — the first frame, after start-up
/// has already taken its time — and the splash would then run its full five
/// seconds on top of the slowest starts.
DateTime splashStarted = DateTime.now();

void markSplashStart() => splashStarted = DateTime.now();

/// What is left of [splashHold] at [now]; never negative, so a start slow
/// enough to have used it all goes straight to the app.
Duration splashRemaining(DateTime now, {DateTime? started}) {
  final left = splashHold - now.difference(started ?? splashStarted);
  return left.isNegative ? Duration.zero : left;
}

/// The apps hold a splash; the website and desktop builds do not — a browser
/// tab that sits on a logo for five seconds is a tab somebody closes.
bool splashHeld({required bool isWeb, required TargetPlatform platform}) =>
    !isWeb && (platform == TargetPlatform.android || platform == TargetPlatform.iOS);

/// White in light mode and black in dark: what a logo is drawn to sit on.
Color splashBackground({required bool dark}) => dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);

/// The brand blue the splash's "GET." is drawn in where there is no
/// picture: legible on white and on black alike.
Color splashInk({required bool dark}) => const Color(0xFF2DABE2);

/// What the splash shows where nobody uploaded a picture, or it won't load.
const splashWordmark = 'GET.';
