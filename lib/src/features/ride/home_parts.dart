import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/fare.dart';
import '../../core/home_sections.dart';
import '../../data/geo_service.dart';

/// A stored picture: an http(s) or `data:` URL.
Widget uriImage(String? uri, {double? width, double? height, BoxFit fit = BoxFit.contain, Widget? fallback}) {
  final none = fallback ?? SizedBox(width: width, height: height);
  if (uri == null) return none;
  if (uri.startsWith('data:')) {
    try {
      return Image.memory(
        base64Decode(uri.split(',').last),
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, _, _) => none,
      );
    } catch (_) {
      return none;
    }
  }
  if (uri.startsWith('http')) {
    return Image.network(uri, width: width, height: height, fit: fit, errorBuilder: (_, _, _) => none);
  }
  return none;
}

/// The vehicle-type bar (Expo `rideTypes`): one card per bookable service,
/// the selected one wider, with an "i" for its description.
class VehicleTypeBar extends StatelessWidget {
  const VehicleTypeBar({super.key, required this.services, required this.selected, required this.onSelect});

  final List<RideService> services;
  final RideService selected;
  final ValueChanged<RideService> onSelect;

  void _info(BuildContext context, RideService s) => showModalBottomSheet<void>(
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
    final t = Theme.of(context);
    return SizedBox(
      height: 72,
      child: ListView.separated(
        key: const ValueKey('vehicle-type-bar'),
        scrollDirection: Axis.horizontal,
        itemCount: services.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final s = services[i];
          final on = s.name == selected.name;
          final fg = on ? Colors.white : t.colorScheme.onSurface;
          return AnimatedContainer(
            key: ValueKey('vehicle-type-${s.name}'),
            duration: const Duration(milliseconds: 200),
            width: on ? 104 : 76,
            decoration: BoxDecoration(
              color: on ? const Color(0xFF2A4A6B) : t.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onSelect(s),
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        uriImage(
                          s.image,
                          width: 48,
                          height: 28,
                          fallback: Icon(Icons.directions_car, size: 26, color: fg),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(
                                s.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: fg),
                              ),
                            ),
                            const SizedBox(width: 3),
                            Icon(Icons.person, size: 11, color: on ? Colors.white70 : t.colorScheme.onSurfaceVariant),
                            Text(
                              '${s.seats}',
                              style: TextStyle(
                                fontSize: 11,
                                color: on ? Colors.white70 : t.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (on)
                    Positioned(
                      top: 2,
                      right: 2,
                      child: InkWell(
                        key: ValueKey('vehicle-info-${s.name}'),
                        onTap: () => _info(context, s),
                        child: Container(
                          width: 18,
                          height: 18,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFF7BB8E8)),
                          ),
                          child: const Text(
                            'i',
                            style: TextStyle(fontSize: 11, color: Colors.white, fontStyle: FontStyle.italic),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// "Where to & for how much?" (Expo `searchBar`).
class HomeSearchPill extends StatelessWidget {
  const HomeSearchPill({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        key: const ValueKey('home-search'),
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(
            children: [
              const Icon(Icons.search, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Where to & for how much?',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
          subtitle: Text(p.address, maxLines: 1, overflow: TextOverflow.ellipsis),
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

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: 160, maxWidth: MediaQuery.sizeOf(context).width * 0.85),
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(12),
        color: t.colorScheme.surface,
        child: InkWell(
          key: const ValueKey('pickup-pill'),
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Pickup point', style: t.textTheme.labelSmall),
                      Text(
                        place?.name ?? 'Set pickup location',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.titleSmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right),
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
