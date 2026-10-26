import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../core/fare.dart';
import '../../core/home_layout.dart' show homeSearchDefaultText;
import '../../core/home_sections.dart';
import '../../data/geo_service.dart';
import '../../widgets/common.dart' show inkOn, mutedTextColor;
import '../../core/media_assets.dart' show isMediaRef;
import '../../widgets/media_image.dart';
import '../../widgets/net_image.dart';
import '../../widgets/scroll_fade.dart';
import '../../core/page_styles.dart' show homeSurface;
import '../../core/smart_address.dart' show placeSubtitle;
import '../../widgets/page_style_host.dart';

/// Whether [uri] is a picture that loads over the network (and so shows a
/// skeleton first): an address, or a Media Gallery upload (`media:<id>`).
/// Pure.
bool loadsOverNetwork(String? uri) => uri != null && (uri.startsWith('http') || isMediaRef(uri));

/// A stored picture: an http(s) or `data:` URL. [onSettled] runs once the
/// picture is painted or has fallen back to [fallback], after the frame.
Widget uriImage(
  String? uri, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.contain,
  Alignment alignment = Alignment.center,
  Widget? fallback,
  VoidCallback? onSettled,
}) {
  void settled() {
    if (onSettled != null) WidgetsBinding.instance.addPostFrameCallback((_) => onSettled());
  }

  final none = fallback ?? SizedBox(width: width, height: height);
  if (uri == null) return none;
  // A Media Gallery upload: looked up, then loaded (a skeleton meanwhile).
  if (isMediaRef(uri)) {
    return MediaImage(
      uri,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      fallback: none,
      onSettled: onSettled,
    );
  }
  if (uri.startsWith('data:')) {
    try {
      return Image.memory(
        base64Decode(uri.split(',').last),
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        errorBuilder: (_, _, _) => none,
      );
    } catch (_) {
      return none;
    }
  }
  if (uri.startsWith('http')) {
    final bone = boneUntilPainted(width: width, height: height);
    return Image.network(
      uri,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      frameBuilder: (context, child, frame, synchronous) {
        if (synchronous || frame != null) settled();
        return bone(context, child, frame, synchronous);
      },
      errorBuilder: (_, _, _) {
        settled();
        return none;
      },
    );
  }
  return none;
}

/// The vehicle-type bar while the service catalogue loads: the boxes' shape,
/// shimmering, with no names or icons that would then change.
class VehicleTypeBarSkeleton extends StatelessWidget {
  const VehicleTypeBarSkeleton({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 66,
    child: SkeletonizerConfig(
      data: SkeletonizerConfigData(brightness: Theme.of(context).brightness),
      child: Skeletonizer.zone(
        key: const ValueKey('vehicle-type-bar-skeleton'),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 4,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Bone(width: 30, height: 22, borderRadius: BorderRadius.circular(6)),
                const SizedBox(height: 8),
                Bone.text(words: i.isEven ? 1 : 2, fontSize: 13),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The vehicle-type bar (Expo `rideTypes`): one card per bookable service,
/// the selected one wider, with an "i" for its description. Nothing shows as
/// chosen, and nothing can be chosen, while a card's picture is still a
/// skeleton: the bar comes alive once every picture has painted or fallen
/// back to the car icon (vehicleBarReady).
class VehicleTypeBar extends StatefulWidget {
  const VehicleTypeBar({
    super.key,
    required this.services,
    required this.selected,
    required this.onSelect,
    this.onInfo,
  });

  final List<RideService> services;
  final RideService selected;
  final ValueChanged<RideService> onSelect;

  /// What the "i" opens: the fare details where the home screen knows the
  /// rates; the service's description alone otherwise.
  final ValueChanged<RideService>? onInfo;

  /// The chosen box's fill and its "i" (inDrive's indigo and blue): indigo
  /// with white text on a dark sheet, a light blue with dark text on a light one.
  static const selectedFill = Color(0xFF2B2E8C);
  static const selectedFillLight = Color(0xFFD8EEFB);
  static const infoBlue = Color(0xFF5468FF);

  static Color fillFor(Brightness b) => b == Brightness.dark ? selectedFill : selectedFillLight;

  @override
  State<VehicleTypeBar> createState() => _VehicleTypeBarState();
}

/// Whether every network picture among [images] has [settled] (painted or
/// fallen back); pictures that do not load over the network never wait.
/// Pure.
bool vehicleBarReady(Iterable<String?> images, Set<String> settled) =>
    images.every((u) => !loadsOverNetwork(u) || settled.contains(u));

class _VehicleTypeBarState extends State<VehicleTypeBar> {
  /// The pictures that have painted or fallen back.
  final _settled = <String>{};

  void _settle(String? uri) {
    if (uri == null || !mounted || _settled.contains(uri)) return;
    setState(() => _settled.add(uri));
  }

  List<RideService> get services => widget.services;
  RideService get selected => widget.selected;

  static const infoBlue = VehicleTypeBar.infoBlue;
  static Color fillFor(Brightness b) => VehicleTypeBar.fillFor(b);

  void _info(BuildContext context, RideService s) => showAppSheet<void>(id: 'home.vehicle-description',
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (s.image != null) Center(child: uriImage(s.image, height: 96)),
            const SizedBox(height: 12),
            Text(s.name, style: Theme.of(c).textTheme.titleLarge),
            if (s.description.isNotEmpty) ...[const SizedBox(height: 8), Text(s.description)],
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ready = vehicleBarReady(services.map((s) => s.image), _settled);
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    // App Page Settings → Home → Vehicle bar.
    final style = SurfaceStyle.of(context, homeSurface);
    // The words checked against what they sit on: the map sheet (an admin
    // colour or the theme's) for the others, the chosen card's fill for
    // the chosen one. The seats were the theme's secondary grey as it was,
    // 2.5:1 with an admin's light grey.
    final sheet = style.setColor('mapSheetColor', t.brightness) ?? t.colorScheme.surface;
    final chosenFill = style.color('vehicleSelected', t.brightness) ?? fillFor(t.brightness);
    final onFill = inkOn(chosenFill, preferred: dark ? Colors.white : t.colorScheme.onSurface);
    final ink = inkOn(sheet, preferred: t.colorScheme.onSurface);
    final muted = mutedTextColor(t, background: sheet);
    final radius = BorderRadius.circular(style.number('vehicleRadius'));
    return SizedBox(
      // Taller by as much as the phone's larger text makes the name line.
      height: style.number('vehicleBarHeight') + (MediaQuery.textScalerOf(context).scale(13) - 13) * 1.4,
      // Its far edge fades while there are more vehicles to scroll to (at
      // 317 wide the last was cut to "F…" with no sign the row goes on).
      child: HorizontalScrollFade(
        child: ListView.separated(
        key: const ValueKey('vehicle-type-bar'),
        scrollDirection: Axis.horizontal,
        itemCount: services.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          final s = services[i];
          final on = ready && s.name == selected.name;
          final fg = on ? onFill : ink;
          final seats = on ? onFill : muted;
          // Unchosen boxes are the sheet itself; the chosen one is filled,
          // with the name in full and the seats pushed to its right edge.
          return Material(
            key: ValueKey('vehicle-type-${s.name}'),
            color: on ? chosenFill : Colors.transparent,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: ready ? () => widget.onSelect(s) : null,
              child: Stack(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: IntrinsicWidth(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          // Flush with the name's left edge, as inDrive's.
                          uriImage(
                            s.image,
                            width: style.number('vehicleImageWidth'),
                            height: 26,
                            alignment: Alignment.centerLeft,
                            fallback: Icon(Icons.directions_car, size: 24, color: fg),
                            onSettled: () => _settle(s.image),
                          ),
                          if (on) ...[
                            const Spacer(),
                            const SizedBox(width: 12),
                            // Room for the (i), which stands over the box's corner
                            // (below) so its tap area can be 44 square.
                            SizedBox(width: style.number('infoIconSize')),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(
                            s.name,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: style.number('vehicleNameSize'),
                              fontWeight: FontWeight.w500,
                              color: fg,
                            ),
                          ),
                          on ? const Spacer() : const SizedBox(width: 6),
                          if (on) const SizedBox(width: 12),
                          Icon(Icons.person, size: 13, color: seats),
                          Text('${s.seats}', style: TextStyle(fontSize: 13, color: seats)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // The chosen box's (i): a 44-square tap area in its top corner,
              // named for screen readers and on hover.
              if (on)
                Positioned(
                  top: 0,
                  right: 0,
                  width: 44,
                  height: 44,
                  child: Tooltip(
                    message: 'Fare details',
                    excludeFromSemantics: true,
                    child: Semantics(
                      // Its own node: not merged into the box's button.
                      container: true,
                      button: true,
                      label: 'Fare details for ${s.name}',
                      excludeSemantics: true,
                      child: InkResponse(
                        key: ValueKey('vehicle-info-${s.name}'),
                        radius: 22,
                        onTap: () => widget.onInfo != null ? widget.onInfo!(s) : _info(context, s),
                        child: Align(
                          // Where the icon stood in the row: the box's padding in.
                          alignment: const Alignment(0.4, -0.3),
                          child: Icon(
                            Icons.info_outline,
                            size: style.number('infoIconSize'),
                            color: style.color('infoIcon', t.brightness) ?? infoBlue,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          );
        },
        ),
      ),
    );
  }
}


/// "Where to & for how much?" (Expo `searchBar`).
class HomeSearchPill extends StatelessWidget {
  const HomeSearchPill({super.key, required this.onTap, this.text = homeSearchDefaultText});
  final VoidCallback onTap;

  /// Admin → Display Settings → Home page → Search bar's words.
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // App Page Settings → Home → Search bar.
    final style = SurfaceStyle.of(context, homeSurface);
    final radius = BorderRadius.circular(style.number('searchRadius'));
    return Material(
      color: style.color('searchColor', t.brightness) ?? t.colorScheme.surfaceContainerHighest,
      borderRadius: radius,
      child: InkWell(
        key: const ValueKey('home-search'),
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 18, vertical: style.number('searchPadding')),
          child: Row(
            children: [
              Icon(Icons.search, size: style.number('searchIconSize')),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    fontSize: style.number('searchFontSize'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How many recent places show with the home sheet all the way down.
const homeRecentAtRest = 2;

/// Recent destinations under the search bar (Expo `recentLocations`).
class HomeRecentPlaces extends StatelessWidget {
  const HomeRecentPlaces({super.key, required this.places, required this.onTap});
  final List<Place> places;
  final ValueChanged<Place> onTap;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final p in places)
        ListTile(
          key: ValueKey('home-recent-${p.name}'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.place_outlined),
          title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: switch (placeSubtitle(p.name, p.address)) {
            final a? => Text(a, maxLines: 1, overflow: TextOverflow.ellipsis),
            null => null,
          },
          onTap: () => onTap(p),
        ),
    ],
  );
}

const _boxIcons = <String, IconData>{
  'ShoppingBag': Icons.shopping_bag_outlined,
  'Car': Icons.directions_car_outlined,
  'Building2': Icons.apartment,
  'Package': Icons.inventory_2_outlined,
  'Truck': Icons.local_shipping_outlined,
  'Bike': Icons.pedal_bike,
  'Bus': Icons.directions_bus_outlined,
  'Plane': Icons.flight,
  'MapPin': Icons.place_outlined,
  'Navigation': Icons.navigation_outlined,
  'Clock': Icons.schedule,
  'Bell': Icons.notifications_outlined,
};

/// The five service boxes (Expo `serviceCategories` + `serviceBoxes`): box 0
/// large on the left over box 3, boxes 1, 2 and 4 on the right.
class ServiceBoxesGrid extends StatelessWidget {
  const ServiceBoxesGrid({super.key, required this.boxes, required this.onOpen});
  final List<ServiceBoxView> boxes;
  final ValueChanged<ServiceBoxView> onOpen;

  Widget _box(BuildContext context, ServiceBoxView b, double height) {
    final featured = b.featured;
    return SizedBox(
      height: height,
      child: Material(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: ValueKey('service-box-${b.index}'),
          borderRadius: BorderRadius.circular(18),
          onTap: () => onOpen(b),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Stack(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        b.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (b.badge != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Color(b.badge == 'NEW' ? 0xFFD32F26 : 0xFF5C5C66),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          b.badge!,
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800),
                        ),
                      ),
                  ],
                ),
                Align(
                  alignment: Alignment.bottomRight,
                  child: b.imageUri != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: uriImage(b.imageUri, width: featured ? 84 : 56, height: featured ? 84 : 56),
                        )
                      : isMediaRef(b.iconName)
                      ? MediaIcon(b.iconName, fallback: Icons.apps, size: featured ? 72 : 44, color: Color(b.accent))
                      : Icon(_boxIcons[b.iconName] ?? Icons.apps, size: featured ? 72 : 44, color: Color(b.accent)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (boxes.length < 5) return const SizedBox.shrink();
    return Row(
      key: const ValueKey('service-boxes'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            children: [_box(context, boxes[0], 210), const SizedBox(height: 10), _box(context, boxes[3], 100)],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            children: [
              _box(context, boxes[1], 100),
              const SizedBox(height: 10),
              _box(context, boxes[2], 100),
              const SizedBox(height: 10),
              _box(context, boxes[4], 100),
            ],
          ),
        ),
      ],
    );
  }
}

/// The pickup pill over the map (Expo `addressBar`).
class PickupPill extends StatelessWidget {
  const PickupPill({super.key, required this.place, required this.onTap});
  final Place? place;
  final VoidCallback onTap;

  /// The box (inDrive's): white on a light map, charcoal on a dark one.
  static Color fillFor(Brightness b) => b == Brightness.dark ? const Color(0xFF262626) : Colors.white;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final ink = dark ? Colors.white : const Color(0xFF111111);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.85),
      child: Material(
        elevation: 3,
        shadowColor: Colors.black38,
        borderRadius: BorderRadius.circular(10),
        color: fillFor(t.brightness),
        child: InkWell(
          key: const ValueKey('pickup-pill'),
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Pickup point',
                        style: TextStyle(fontSize: 13, height: 1.25, color: dark ? Colors.white60 : const Color(0xFF7A7A7A)),
                      ),
                      Text(
                        // Large text: the short words, so the pill isn't cut off.
                        place?.name ??
                            (MediaQuery.textScalerOf(context).scale(1) > 1.15 ? 'Set pickup' : 'Set pickup location'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 17, height: 1.3, fontWeight: FontWeight.w600, color: ink),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Icon(Icons.chevron_right, size: 20, color: ink),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Colours of the simulated cars, by the selected service's position.
const _carColors = [Color(0xFF111111), Color(0xFF0F4C81), Color(0xFF1F7A3A), Color(0xFF8B5A00)];

Marker demoCarMarker(DemoCar c, int serviceIndex) => Marker(
  point: LatLng(c.lat, c.lng),
  width: 30,
  height: 30,
  child: Container(
    decoration: BoxDecoration(
      color: _carColors[serviceIndex % _carColors.length],
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2),
      boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
    ),
    child: Transform.rotate(
      angle: c.heading * 3.141592653589793 / 180,
      child: const Icon(Icons.navigation, size: 16, color: Colors.white),
    ),
  ),
);
