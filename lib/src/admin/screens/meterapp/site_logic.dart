/// Pure helpers for Admin → App Settings (`/admin/m/site`): one page for
/// everything every user's app takes from the single `app_branding` row —
/// the app icon, the splash, the theme colours and where maps open.
library;

import 'dart:ui' show Color;

import '../../../core/app_branding.dart';

final _hexRe = RegExp(r'^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})$');

bool isValidHex(String v) => _hexRe.hasMatch(v.trim());

/// `#RGB` / `#RRGGBB` as an opaque colour, or null when invalid.
Color? hexToColor(String v) => brandHexColor(v);

bool isValidLatLng(String lat, String lng) {
  final la = double.tryParse(lat.trim());
  final lo = double.tryParse(lng.trim());
  if (la == null || lo == null || !la.isFinite || !lo.isFinite) return false;
  return la >= -90 && la <= 90 && lo >= -180 && lo <= 180;
}

/// The labels of [themeColorKeys], in the order the page lists them.
const themeColorLabels = {
  'accent': 'Accent',
  'primary': 'Buttons',
  'background': 'Background',
  'text': 'Text',
  'textSecondary': 'Text Secondary',
  'border': 'Border',
  'error': 'Error',
};

/// The page's editable values as text, by field key: `splash.light`,
/// `splash.dark`, `light.<colour>`, `dark.<colour>`, `startLat`, `startLng`.
/// A blank value is "the app's default".
Map<String, String> appSettingsFields(AppBranding b) => {
  'splash.light': b.splashBgLight ?? '',
  'splash.dark': b.splashBgDark ?? '',
  for (final k in themeColorKeys) 'light.$k': b.lightColors[k] ?? '',
  for (final k in themeColorKeys) 'dark.$k': b.darkColors[k] ?? '',
  'startLat': b.startLat?.toString() ?? '',
  'startLng': b.startLng?.toString() ?? '',
};

/// The first problem with [f], or null.
String? validateAppSettings(Map<String, String> f) {
  String v(String k) => (f[k] ?? '').trim();
  for (final (k, label) in [('splash.light', 'light'), ('splash.dark', 'dark')]) {
    if (v(k).isNotEmpty && !isValidHex(v(k))) return 'Invalid $label splash background colour';
  }
  for (final (mode, name) in [('light', 'Light'), ('dark', 'Dark')]) {
    for (final k in themeColorKeys) {
      final c = v('$mode.$k');
      if (c.isNotEmpty && !isValidHex(c)) return 'Invalid $name ${themeColorLabels[k]} colour';
    }
  }
  final lat = v('startLat'), lng = v('startLng');
  if (lat.isEmpty != lng.isEmpty) return 'Enter both the latitude and the longitude, or neither';
  if (lat.isNotEmpty && !isValidLatLng(lat, lng)) return 'Invalid start latitude/longitude';
  return null;
}

/// The `app_branding` columns [f] sets (blanks clear back to the default).
Map<String, dynamic> appSettingsPatch(Map<String, String> f) {
  String? v(String k) {
    final t = (f[k] ?? '').trim();
    return t.isEmpty ? null : t;
  }

  Map<String, String> palette(String mode) => {
    for (final k in themeColorKeys)
      if (v('$mode.$k') != null) k: v('$mode.$k')!,
  };
  final lat = double.tryParse(v('startLat') ?? ''), lng = double.tryParse(v('startLng') ?? '');
  final located = lat != null && lng != null;
  return {
    'splash_bg_light': v('splash.light'),
    'splash_bg_dark': v('splash.dark'),
    'theme': {'light': palette('light'), 'dark': palette('dark')},
    'start_lat': located ? lat : null,
    'start_lng': located ? lng : null,
  };
}

// --- Storage ------------------------------------------------------------------

const brandingTable = 'app_branding';
const brandingRowId = 'global';
const brandingBucket = 'app-branding';
const splashPresetColors = ['#FFFFFF', '#000000', '#2DABE2', '#0EA5E9', '#22C55E', '#F59E0B', '#8B5CF6', '#EF4444'];

/// Storage path for an uploaded branding image (`<kind>-<ms>.<ext>`).
String brandingPath(String kind, String ext, DateTime now) => '$kind-${now.millisecondsSinceEpoch}.$ext';
