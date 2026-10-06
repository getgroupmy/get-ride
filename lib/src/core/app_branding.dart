/// The admin-set splash (Admin → Settings → Splash Screen, the `app_branding`
/// row), as the app shows it at launch (Expo `BrandingContext` +
/// `SplashScreenComponent`). Pure: parsing, the cached copy, and the colour.
library;

import 'dart:ui' show Color;

import '../admin/screens/meterapp/site_logic.dart' show defaultSplashBgColor, hexToColor;

class AppBranding {
  const AppBranding({this.splashImageUrl, this.splashBgColor = defaultSplashBgColor});

  final String? splashImageUrl;
  final String splashBgColor;

  /// The `app_branding` row; null or blank fields fall back to the defaults.
  static AppBranding fromRow(Map<String, dynamic>? row) {
    String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    return AppBranding(
      splashImageUrl: s(row?['splash_image_url']),
      splashBgColor: s(row?['splash_bg_color']) ?? defaultSplashBgColor,
    );
  }

  Map<String, dynamic> toJson() => {'splash_image_url': splashImageUrl, 'splash_bg_color': splashBgColor};

  /// Like Expo, there is no splash without an image: a bare colour would only
  /// delay the app.
  bool get showsSplash => splashImageUrl != null && splashImageUrl!.startsWith('http');

  Color get background => hexToColor(splashBgColor) ?? hexToColor(defaultSplashBgColor)!;

  @override
  bool operator ==(Object other) =>
      other is AppBranding && other.splashImageUrl == splashImageUrl && other.splashBgColor == splashBgColor;

  @override
  int get hashCode => Object.hash(splashImageUrl, splashBgColor);
}

/// How long the splash stays up before it fades, and the fade.
const splashHold = Duration(milliseconds: 1500);
const splashFade = Duration(milliseconds: 350);
