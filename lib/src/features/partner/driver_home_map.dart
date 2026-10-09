import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../data/models.dart';
import '../../widgets/map_recenter.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/map_type_button.dart';
import '../../widgets/ride_map.dart';
import '../../widgets/road_info_layers.dart';

/// The driver's home map (Expo `partner-ehailing`): where they are and,
/// while online, where each open request is waiting, with its fare. Tapping
/// a pin opens that request in [onSelect].
///
/// It opens at street level ([driverHomeZoom]) on the driver and follows
/// them as they move, keeping them in the middle of the map above the
/// sheet. Moving the map by hand stops the following; the recenter button
/// starts it again.
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

class _DriverHomeMapState extends ConsumerState<DriverHomeMap> with SingleTickerProviderStateMixin {
  final _map = MapController();
  bool _ready = false;
  bool _follow = true;

  /// The camera's glide from where it is to the driver.
  late final _glide = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))
    ..addListener(_glideTick);
  LatLng? _from, _to;
  double _zoom = driverHomeZoom;

  @override
  void dispose() {
    _glide.dispose();
    _map.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DriverHomeMap old) {
    super.didUpdateWidget(old);
    if (widget.me != old.me) WidgetsBinding.instance.addPostFrameCallback((_) => _center());
  }

  /// Where the driver sits: the middle of the map above the sheet.
  Offset get _offset => Offset(0, -MapBottomInset.of(context) / 2);

  /// Glides the camera onto the driver, at the zoom the map is at.
  void _center({bool jump = false}) {
    final me = widget.me;
    if (!mounted || !_follow || !_ready || me == null) return;
    final MapCamera camera;
    try {
      camera = _map.camera;
    } catch (_) {
      return;
    }
    _zoom = camera.zoom;
    if (jump) {
      _map.move(me, _zoom, offset: _offset);
      return;
    }
    _from = _to ?? camera.center;
    _to = me;
    _glide.forward(from: 0);
  }

  void _glideTick() {
    final a = _from, b = _to;
    if (a == null || b == null || !mounted) return;
    final t = Curves.easeInOut.transform(_glide.value);
    try {
      _map.move(
        LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t),
        _zoom,
        offset: _offset,
      );
    } catch (_) {}
  }

  /// A hand on the map: stop following until the recenter button.
  void _onGesture() {
    if (!_follow) return;
    _glide.stop();
    _from = _to = null;
    setState(() => _follow = false);
  }

  void _recenter() {
    setState(() => _follow = true);
    _glide.stop();
    _from = _to = null;
    final me = widget.me;
    if (me == null) return;
    try {
      _map.move(me, driverHomeZoom, offset: _offset);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.me, requests = widget.requests, onSelect = widget.onSelect;
    final t = Theme.of(context);
    final map = RideMap(
      controller: _map,
      me: me,
      pointZoom: driverHomeZoom,
      // The camera follows the driver instead of framing the pins.
      autoFit: false,
      onGesture: _onGesture,
      onReady: () {
        _ready = true;
        _center(jump: true);
      },
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
                          r.fareText(r.effectiveFare),
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
        // The road the driver is on: its limit, or its class as an estimate.
        // Below the page's menu button.
        Positioned(left: 12, top: 84, child: SafeArea(child: SpeedLimitBadge(at: me))),
        // Bottom right, above the sheet, as on the trip maps.
        MapBottomInset.listen(
          context,
          (inset) => Positioned(
            right: 12,
            bottom: mapAttributionClearance + inset,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Map view above recenter on every map.
              const MapTypeButton(),
              const SizedBox(height: 8),
              // Expo's driver map recenters on the driver.
              RecenterButton(onPressed: me == null ? null : _recenter),
            ]),
          ),
        ),
      ],
    );
  }
}
