/// The Expo home-screen parts Admin → Display Settings switches (Expo
/// `app/index.tsx`): which show, the five service boxes and what each does,
/// and the simulated nearby cars. Pure.
library;

import 'dart:math' as math;

import '../admin/screens/meterapp/display_logic.dart';
import 'expo_routes.dart';

/// Which home parts show, read with Expo's defaults (the service boxes and
/// the on-map cars start off).
class HomeSections {
  const HomeSections({
    this.vehicleBar = true,
    this.searchBar = true,
    this.recentPlaces = true,
    this.serviceBoxes = false,
    this.addressBar = true,
    this.newBadge = true,
    this.vehicleMarkers = false,
  });

  final bool vehicleBar;
  final bool searchBar;
  final bool recentPlaces;
  final bool serviceBoxes;
  final bool addressBar;
  final bool newBadge;
  final bool vehicleMarkers;

  static HomeSections fromSettings(Map<String, dynamic> s) {
    bool flag(String k, bool d) {
      final v = s[k];
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final t = v.trim().toLowerCase();
        if (t == 'false' || t == '0' || t == 'off') return false;
        if (t == 'true' || t == '1' || t == 'on') return true;
      }
      return d;
    }

    return HomeSections(
      vehicleBar: flag('rideTypes', true),
      searchBar: flag('searchBar', true),
      recentPlaces: flag('recentLocations', true),
      serviceBoxes: flag('serviceCategories', false),
      addressBar: flag('addressBar', true),
      newBadge: flag('serviceBoxBadge', true),
      // Expo draws them only alongside the vehicle bar, for its selection.
      vehicleMarkers: flag('showVehicleMarkers', false) && flag('rideTypes', true),
    );
  }
}

/// Expo's preset titles and icon accents for boxes 0–4.
const serviceBoxPresets = <(String, int)>[
  ('Groceries\nin 30 min', 0xFF4CAF50),
  ('City rides', 0xFFA8E063),
  ('City to City', 0xFFFFD54F),
  ('Couriers', 0xFFA8E063),
  ('Freight', 0xFFA8E063),
];

class ServiceBoxView {
  const ServiceBoxView({
    required this.index,
    required this.title,
    required this.accent,
    this.iconName,
    this.imageUri,
    this.route,
    this.badge,
  });

  final int index;
  final String title;
  final int accent;
  final String? iconName;
  final String? imageUri;

  /// Where a tap goes in this app; null shows "coming soon".
  final String? route;

  /// 'SOON', 'NEW' or none.
  final String? badge;

  /// Box 0 is the large card.
  bool get featured => index == 0;
}

/// The five boxes as configured. [serviceNames] names the admin services a
/// box can be linked to (by id).
List<ServiceBoxView> serviceBoxViews(
  Map<String, dynamic> settings, {
  Map<String, String> serviceNames = const {},
  bool serviceEnabled = true,
  bool newBadge = true,
}) {
  final boxes = normalizeBoxes(settings['serviceBoxes']);
  return [
    for (var i = 0; i < boxes.length; i++)
      () {
        final b = boxes[i];
        String? str(String k) {
          final v = '${b[k] ?? ''}'.trim();
          return v.isEmpty ? null : v;
        }

        final preset = serviceBoxPresets[i % serviceBoxPresets.length];
        final linked = str('serviceId') == null ? null : serviceNames[str('serviceId')];
        final route = serviceEnabled && b['comingSoon'] != true ? flutterRouteFor(str('route')) : null;
        return ServiceBoxView(
          index: i,
          title: str('name') ?? linked ?? preset.$1,
          accent: preset.$2,
          iconName: str('iconName'),
          imageUri: str('imageUri'),
          route: route,
          badge: route == null ? 'SOON' : (i == 0 && newBadge ? 'NEW' : null),
        );
      }(),
  ];
}

/// "<title> isn't available yet. Please check back later."
String serviceBoxComingSoon(String title) =>
    "${title.replaceAll('\n', ' ')} isn't available yet. Please check back later.";

/// A simulated nearby car (Expo's `showVehicleMarkers`: generated around the
/// pin, not real drivers).
typedef DemoCar = ({double lat, double lng, double heading});

/// How far from the pin the cars roam, in degrees (≈500 m).
const demoCarRadius = 0.0045;

/// [count] cars scattered around [lat]/[lng].
List<DemoCar> spawnDemoCars(double lat, double lng, int count, math.Random rnd) => [
  for (var i = 0; i < count; i++)
    () {
      final a = rnd.nextDouble() * 2 * math.pi;
      final r = demoCarRadius * math.sqrt(rnd.nextDouble());
      return (lat: lat + r * math.sin(a), lng: lng + r * math.cos(a), heading: rnd.nextDouble() * 360);
    }(),
];

/// One second of driving: a small step along the heading, which wanders a
/// little and turns back towards the pin when a car strays past the radius.
DemoCar stepDemoCar(DemoCar c, double lat, double lng, math.Random rnd) {
  var heading = c.heading + (rnd.nextDouble() * 12 - 6);
  final dLat = c.lat - lat, dLng = c.lng - lng;
  if (math.sqrt(dLat * dLat + dLng * dLng) > demoCarRadius) {
    heading = (math.atan2(-dLng, -dLat) * 180 / math.pi) % 360;
  }
  final step = 0.00002 + rnd.nextDouble() * 0.00003;
  final rad = heading * math.pi / 180;
  return (lat: c.lat + step * math.cos(rad), lng: c.lng + step * math.sin(rad), heading: heading % 360);
}

/// How many cars of the [index]th service Expo showed (12, 8, 6, 5, then 4).
int demoCarCount(int index) => const [12, 8, 6, 5].elementAtOrNull(index) ?? 4;
