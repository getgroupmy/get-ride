/// What Admin → App Settings sets for every user (the `app_branding` row),
/// and the splash the Android and iOS apps hold for a moment at launch,
/// worked the way iAkauntan's is (`core/splash.dart` there): five seconds
/// counted from when the process started, in the apps only, the admin's
/// picture on white — or black in dark mode, unless the admin picked other
/// backgrounds — falling back to the app's name. Pure: every answer here is
/// testable without a widget.
library;

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show TargetPlatform, mapEquals;

/// The colours an admin may set for each theme (Admin → App Settings →
/// Theme Colors), each an override of what the app draws by default.
const themeColorKeys = ['accent', 'primary', 'background', 'text', 'textSecondary', 'border', 'error'];

/// The app's colours where the admin set none, for the admin page's hints.
/// Null: worked out from the accent.
const themeColorDefaults = <String, ({String? light, String? dark})>{
  'accent': (light: '#2DABE2', dark: '#2DABE2'),
  'primary': (light: '#111827', dark: '#2DABE2'),
  'background': (light: '#FFFFFF', dark: '#0B0F17'),
  'text': (light: null, dark: null),
  'textSecondary': (light: null, dark: null),
  'border': (light: null, dark: null),
  'error': (light: null, dark: null),
};

final _hex = RegExp(r'^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})$');

/// `#RGB` / `#RRGGBB` as an opaque colour, or null.
Color? brandHexColor(Object? v) {
  final t = v is String ? v.trim() : '';
  if (!_hex.hasMatch(t)) return null;
  var h = t.substring(1);
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  return Color(0xFF000000 | int.parse(h, radix: 16));
}

/// The valid overrides in a stored palette, keys known and values hex.
Map<String, String> _palette(Object? v) => {
  if (v is Map)
    for (final k in themeColorKeys)
      if (brandHexColor(v[k]) != null) k: (v[k] as String).trim(),
};

/// Everything Admin → App Settings sets for every user: the single
/// `app_branding` row (`id = 'global'`), read live by every app.
class AppBranding {
  const AppBranding({
    this.splashImageUrl,
    this.splashBgLight,
    this.splashBgDark,
    this.appIconUrl,
    this.iconChangedAt,
    this.lightColors = const {},
    this.darkColors = const {},
    this.startLat,
    this.startLng,
  });

  /// The admin's splash picture, or null where none was uploaded.
  final String? splashImageUrl;

  /// The splash backgrounds (`#RRGGBB`); null is white / black.
  final String? splashBgLight, splashBgDark;

  /// The admin's app icon, or null for the built-in one.
  final String? appIconUrl;

  /// When the icon was last published (or reset), for the one-time popup.
  final DateTime? iconChangedAt;

  /// Theme colour overrides by [themeColorKeys]; absent keys keep the app's.
  final Map<String, String> lightColors, darkColors;

  /// Where maps open before the user's position is known; null is Kuala Lumpur.
  final double? startLat, startLng;

  /// The `app_branding` row; a blank or non-web URL counts as none, a bad
  /// colour or position as unset. Columns a database lacks read as unset.
  static AppBranding fromRow(Map<String, dynamic>? row) {
    String? url(Object? v) {
      final t = v is String ? v.trim() : '';
      return t.startsWith('http') ? t : null;
    }

    String? hex(Object? v) => brandHexColor(v) == null ? null : (v as String).trim();
    double? toNum(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    final theme = row?['theme'];
    var lat = toNum(row?['start_lat']);
    var lng = toNum(row?['start_lng']);
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180 || (lat == 0 && lng == 0)) {
      lat = lng = null;
    }
    return AppBranding(
      splashImageUrl: url(row?['splash_image_url']),
      splashBgLight: hex(row?['splash_bg_light']),
      splashBgDark: hex(row?['splash_bg_dark']),
      appIconUrl: url(row?['app_icon_url']),
      iconChangedAt: DateTime.tryParse('${row?['icon_changed_at'] ?? ''}'),
      lightColors: _palette(theme is Map ? theme['light'] : null),
      darkColors: _palette(theme is Map ? theme['dark'] : null),
      startLat: lat,
      startLng: lng,
    );
  }

  Map<String, dynamic> toJson() => {
    'splash_image_url': splashImageUrl,
    'splash_bg_light': splashBgLight,
    'splash_bg_dark': splashBgDark,
    'app_icon_url': appIconUrl,
    'icon_changed_at': iconChangedAt?.toUtc().toIso8601String(),
    'theme': {'light': lightColors, 'dark': darkColors},
    'start_lat': startLat,
    'start_lng': startLng,
  };

  /// The colour overrides for one theme.
  Map<String, String> colors({required bool dark}) => dark ? darkColors : lightColors;

  @override
  bool operator ==(Object other) =>
      other is AppBranding &&
      other.splashImageUrl == splashImageUrl &&
      other.splashBgLight == splashBgLight &&
      other.splashBgDark == splashBgDark &&
      other.appIconUrl == appIconUrl &&
      other.iconChangedAt == iconChangedAt &&
      mapEquals(other.lightColors, lightColors) &&
      mapEquals(other.darkColors, darkColors) &&
      other.startLat == startLat &&
      other.startLng == startLng;

  @override
  int get hashCode => Object.hash(
    splashImageUrl,
    splashBgLight,
    splashBgDark,
    appIconUrl,
    iconChangedAt,
    Object.hashAllUnordered(lightColors.entries.map((e) => '${e.key}=${e.value}')),
    Object.hashAllUnordered(darkColors.entries.map((e) => '${e.key}=${e.value}')),
    startLat,
    startLng,
  );
}

/// Whether the icon was changed since this device last showed the popup
/// ([seen]): never on a first sight of the row, so a fresh install is not
/// told about an icon it never saw change.
bool iconChangeUnseen(DateTime? changed, DateTime? seen, {required bool firstLook}) =>
    changed != null && !firstLook && (seen == null || changed.isAfter(seen));

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

/// White in light mode and black in dark, unless the admin chose otherwise
/// ([AppBranding.splashBgLight] / [AppBranding.splashBgDark]).
Color splashBackground({required bool dark, AppBranding? branding}) =>
    brandHexColor(dark ? branding?.splashBgDark : branding?.splashBgLight) ??
    (dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF));

/// The brand blue the splash's "GET." is drawn in where there is no
/// picture: legible on white and on black alike. On a background the admin
/// chose that the blue would vanish into, black or white instead.
Color splashInk({required bool dark, AppBranding? branding}) {
  const blue = Color(0xFF2DABE2);
  final bg = splashBackground(dark: dark, branding: branding);
  final a = blue.computeLuminance(), b = bg.computeLuminance();
  final contrast = (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
  if (contrast >= 2) return blue;
  return b > 0.4 ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
}

/// What the splash shows where nobody uploaded a picture, or it won't load.
const splashWordmark = 'GET.';
