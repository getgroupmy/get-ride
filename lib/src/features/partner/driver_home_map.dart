import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../widgets/map_recenter.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/map_type_button.dart';
import '../../widgets/ride_map.dart';

/// The driver's home map (Expo `partner-ehailing`): where they are and,
/// while online, where each open request is waiting, with its fare. Tapping
/// a pin opens that request in [onSelect].
///
/// It opens at street level ([driverHomeZoom]) on the driver.
class DriverHomeMap extends ConsumerStatefulWidget {
  const DriverHomeMap({super.key, required this.me, required this.requests, this.onSelect});

  final LatLng? me;

  /// The requests to pin (those on the driver's queue).
  final List<RideRequest> requests;
  final void Function(RideRequest)? onSelect;

  @override
  ConsumerState<DriverHomeMap> createState() => _DriverHomeMapState();
}

/// Street level: the roads and buildings around the driver.
const driverHomeZoom = 18.0;

class _DriverHomeMapState extends ConsumerState<DriverHomeMap> {
  final _map = MapController();

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.me, requests = widget.requests, onSelect = widget.onSelect;
    final t = Theme.of(context);
    final pickups = [
      for (final r in requests)
        if (r.pickupLat != null && r.pickupLng != null) LatLng(r.pickupLat!, r.pickupLng!),
    ];
    final map = RideMap(
      controller: _map,
      me: me,
      pointZoom: driverHomeZoom,
      framed: pickups,
      satellite: ref.watch(mapSatelliteProvider),
      extraMarkers: [
        for (final r in requests)
          if (r.pickupLat != null && r.pickupLng != null)
            Marker(
              point: LatLng(r.pickupLat!, r.pickupLng!),
              width: 110,
              height: 34,
              child: GestureDetector(
                key: ValueKey('map-request-${r.id}'),
                onTap: onSelect == null ? null : () => onSelect(r),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: t.colorScheme.primary,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.hail, size: 14, color: t.colorScheme.onPrimary),
                        const SizedBox(width: 4),
                        Text(
                          formatMoney(r.effectiveFare, r.currency),
                          style: TextStyle(color: t.colorScheme.onPrimary, fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
    return Stack(
      children: [
        map,
        // Bottom right, above the sheet, as on the trip maps.
        MapBottomInset.listen(
          context,
          (inset) => Positioned(
            right: 12,
            bottom: mapAttributionClearance + inset,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Expo's driver map recenters on the driver.
              RecenterButton(onPressed: me == null ? null : () => recenterMap(_map, me, zoom: driverHomeZoom)),
              const SizedBox(height: 8),
              const MapTypeButton(),
            ]),
          ),
        ),
      ],
    );
  }
}
