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

/// Admin → Display → Map Layout on the home map. Each applies only once the
/// admin has set it, so a blob without it leaves the map as it is.
class HomeMapLayout {
  const HomeMapLayout({this.recenterBottom, this.mapExtra = 0, this.pinShift = (0, 0), this.pillOffset = 0});

  /// The map type and recenter buttons stand at least this far up from the
  /// bottom of the screen (they still ride above the sheet when it is
  /// higher). Null leaves them on the sheet.
  final double? recenterBottom;

  /// How far the map reaches above the top of the screen: its centre, and
  /// the pin kept there, go up by half of it.
  final double mapExtra;

  /// (right, down) that the pin is kept off its usual place.
  final (double, double) pinShift;

  /// How far the pickup pill above the pin is moved down (negative: up).
  final double pillOffset;

  /// The gap between the pin and the pill above it, which never lets the
  /// pill come down over the pin.
  double get pillGap => math.max(2, 5 - pillOffset);

  static HomeMapLayout fromSettings(Map<String, dynamic> s) {
    double? n(String k) {
      final v = s[k];
      final d = v is num ? v.toDouble() : (v is String ? double.tryParse(v.trim()) : null);
      return d != null && d.isFinite ? d : null;
    }

    return HomeMapLayout(
      recenterBottom: n('recenterButtonBottom'),
      mapExtra: math.max(0, n('mapHeightOffset') ?? 0),
      pinShift: (n('dropPinHorizontalOffset') ?? 0, n('dropPinTopOffset') ?? 0),
      pillOffset: n('addressBarTopOffset') ?? 0,
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
