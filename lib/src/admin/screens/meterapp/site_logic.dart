/// Pure helpers for the App Settings (site), Splash and App Icon screens,
/// ported from the Expo `admin-settings-site.tsx` / `admin-settings-splash.tsx`.
library;

import 'dart:ui' show Color;

final _hexRe = RegExp(r'^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})$');

bool isValidHex(String v) => _hexRe.hasMatch(v.trim());

/// `#RGB` / `#RRGGBB` as an opaque colour, or null when invalid.
Color? hexToColor(String v) {
  final t = v.trim();
  if (!isValidHex(t)) return null;
  var h = t.substring(1);
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  return Color(0xFF000000 | int.parse(h, radix: 16));
}

bool isValidLatLng(String lat, String lng) {
  final la = double.tryParse(lat.trim());
  final lo = double.tryParse(lng.trim());
  if (la == null || lo == null || !la.isFinite || !lo.isFinite) return false;
  return la >= -90 && la <= 90 && lo >= -180 && lo <= 180;
}

/// Device-local key the Expo site screen saves under.
const siteSettingsStorageKey = 'app-settings-v1';

const paletteFields = [
  ('accent', 'Accent'),
  ('accentDark', 'Accent Dark'),
  ('background', 'Background'),
  ('text', 'Text'),
  ('textSecondary', 'Text Secondary'),
  ('border', 'Border'),
  ('success', 'Success'),
  ('warning', 'Warning'),
  ('error', 'Error'),
];

const defaultLightPalette = {
  'accent': '#2dabe2',
  'accentDark': '#238baf',
  'background': '#FFFFFF',
  'text': '#111827',
  'textSecondary': '#6B7280',
  'border': '#E5E7EB',
  'success': '#10B981',
  'warning': '#F59E0B',
  'error': '#EF4444',
};

const defaultDarkPalette = {
  'accent': '#2dabe2',
  'accentDark': '#238baf',
  'background': '#000000',
  'text': '#FFFFFF',
  'textSecondary': '#9CA3AF',
  'border': '#374151',
  'success': '#10B981',
  'warning': '#F59E0B',
  'error': '#EF4444',
};

Map<String, dynamic> defaultSiteSettings() => {
      'light': {...defaultLightPalette},
      'dark': {...defaultDarkPalette},
      'appIconUri': null,
      'splashIconUri': null,
      'splashBgColor': '#FFFFFF',
      'startLat': '3.139003',
      'startLng': '101.686855',
    };

/// Stored JSON merged over the defaults, as the Expo screen loads it.
Map<String, dynamic> mergeSiteSettings(Object? raw) {
  final p = raw is Map ? raw : const {};
  final d = defaultSiteSettings();
  Map<String, String> palette(Object? v, Map<String, String> base) => {
        ...base,
        if (v is Map)
          for (final e in v.entries)
            if (e.value is String) '${e.key}': e.value as String,
      };
  return {
    'light': palette(p['light'], defaultLightPalette),
    'dark': palette(p['dark'], defaultDarkPalette),
    'appIconUri': p['appIconUri'] is String ? p['appIconUri'] : null,
    'splashIconUri': p['splashIconUri'] is String ? p['splashIconUri'] : null,
    'splashBgColor': p['splashBgColor'] is String ? p['splashBgColor'] : d['splashBgColor'],
    'startLat': p['startLat'] is String ? p['startLat'] : d['startLat'],
    'startLng': p['startLng'] is String ? p['startLng'] : d['startLng'],
  };
}

/// First problem with the settings, or null (the Expo `validate`).
String? validateSiteSettings(Map<String, dynamic> s) {
  for (final (mode, name) in [('light', 'Light'), ('dark', 'Dark')]) {
    final p = (s[mode] as Map?) ?? const {};
    for (final (key, label) in paletteFields) {
      if (!isValidHex('${p[key] ?? ''}')) return 'Invalid $name $label color';
    }
  }
  if (!isValidHex('${s['splashBgColor'] ?? ''}')) return 'Invalid splash background color';
  if (!isValidLatLng('${s['startLat'] ?? ''}', '${s['startLng'] ?? ''}')) return 'Invalid start latitude/longitude';
  return null;
}

// --- Branding (app_branding) ------------------------------------------------

const brandingTable = 'app_branding';
const brandingRowId = 'global';
const brandingBucket = 'app-branding';
const defaultSplashBgColor = '#2dabe2';
const splashPresetColors = ['#2dabe2', '#000000', '#FFFFFF', '#0EA5E9', '#22C55E', '#F59E0B', '#8B5CF6', '#EF4444'];

/// Storage path for an uploaded branding image (`<kind>-<ms>.<ext>`).
String brandingPath(String kind, String ext, DateTime now) => '$kind-${now.millisecondsSinceEpoch}.$ext';
