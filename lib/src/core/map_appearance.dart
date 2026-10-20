// Admin → Settings → Maps → Map appearance: whether every map in the app is
// drawn light or dark. Kept in `app_settings` under [mapAppearanceSettingKey]
// as {"mode": "phone" | "app" | "light" | "dark"}; a missing or unreadable
// row is [MapAppearance.phone], how Apple's map has always been drawn.
import 'dart:ui' show Brightness;

/// The `app_settings` row holding the setting (public read, live).
const mapAppearanceSettingKey = 'map_appearance';

enum MapAppearance {
  /// Light or dark by the phone's own setting.
  phone('Follow phone'),

  /// Light or dark as the app is drawn (its Settings → Theme).
  app('Follow app theme'),

  /// Always the light map.
  light('Always light'),

  /// Always the dark map.
  dark('Always dark');

  const MapAppearance(this.label);

  /// What the admin picks from.
  final String label;

  /// The stored value ({"mode": …}, or the mode on its own); anything else
  /// is [phone].
  static MapAppearance fromJson(Object? json) {
    final v = json is Map ? json['mode'] : json;
    for (final m in values) {
      if (m.name == v) return m;
    }
    return phone;
  }

  Map<String, Object?> toJson() => {'mode': name};

  /// The map's brightness under this setting, given the phone's and the
  /// app's. Pure.
  Brightness resolve({required Brightness phone, required Brightness app}) => switch (this) {
    MapAppearance.phone => phone,
    MapAppearance.app => app,
    MapAppearance.light => Brightness.light,
    MapAppearance.dark => Brightness.dark,
  };
}
