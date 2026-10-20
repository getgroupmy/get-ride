// Whether a map is drawn light or dark: the one place every map in the app
// asks (Admin → Settings → Maps → Map appearance, core/map_appearance.dart).
//
// Base layers (Apple's, Google's native and JavaScript maps, MapLibre, the
// raster tiles and their dark versions), the marks and buttons drawn over a
// map that pick their colours to stand out on it, and the status bar over a
// map all go by [mapBrightnessOf], never by the phone's brightness or the
// theme's directly (test/map_brightness_test.dart fails when one does). A
// new map page gets the admin's choice by using these.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/map_appearance.dart';

/// Hands the admin's [MapAppearance] to every map below it; the app puts
/// one over all its routes, fed live from `mapAppearanceProvider`.
class MapAppearanceScope extends InheritedWidget {
  const MapAppearanceScope({super.key, required this.appearance, required super.child});

  final MapAppearance appearance;

  /// The setting over [context]; [MapAppearance.phone] where none is given.
  static MapAppearance of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MapAppearanceScope>()?.appearance ?? MapAppearance.phone;

  @override
  bool updateShouldNotify(MapAppearanceScope oldWidget) => appearance != oldWidget.appearance;
}

/// Whether the maps in [context] are drawn light or dark: the admin's Map
/// appearance applied to the phone's brightness and the app's theme. A
/// widget calling this rebuilds when any of the three changes.
Brightness mapBrightnessOf(BuildContext context) => MapAppearanceScope.of(context).resolve(
  phone: MediaQuery.platformBrightnessOf(context),
  app: Theme.of(context).brightness,
);

/// Whether the maps in [context] are drawn dark ([mapBrightnessOf]).
bool mapIsDark(BuildContext context) => mapBrightnessOf(context) == Brightness.dark;

/// The status bar over a map: light icons over a dark map or over imagery
/// (satellite and hybrid are dark whatever the setting), dark ones over a
/// light map.
SystemUiOverlayStyle mapStatusBarStyle(BuildContext context, {bool imagery = false}) =>
    imagery || mapIsDark(context) ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;

/// Sets the status bar where [child] (a map's base layer) shows under it, by
/// [mapStatusBarStyle]. Inside the page's own region, this one wins where
/// the map shows.
class MapStatusBarRegion extends StatelessWidget {
  const MapStatusBarRegion({super.key, required this.child, this.imagery = false});

  final Widget child;

  /// Satellite or hybrid imagery rather than a drawn map.
  final bool imagery;

  @override
  Widget build(BuildContext context) =>
      AnnotatedRegion<SystemUiOverlayStyle>(value: mapStatusBarStyle(context, imagery: imagery), child: child);
}
