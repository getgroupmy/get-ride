import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/road_info.dart';
import '../data/road_info_service.dart';

/// Traffic signals (OSM `highway=traffic_signals`) as small lights on the
/// map, from [trafficSignalsMinZoom] in. A child of a [FlutterMap]: it reads
/// the camera and asks for the grid squares it newly shows.
class TrafficSignalsLayer extends StatefulWidget {
  const TrafficSignalsLayer({super.key, this.service});

  /// Null is [RoadInfoService.shared].
  final RoadInfoService? service;

  @override
  State<TrafficSignalsLayer> createState() => _TrafficSignalsLayerState();
}

class _TrafficSignalsLayerState extends State<TrafficSignalsLayer> {
  final _signals = <LatLng>{};
  String? _asked;

  RoadInfoService get _service => widget.service ?? RoadInfoService.shared;

  void _fetch(MapCamera camera) {
    if (camera.zoom < trafficSignalsMinZoom) return;
    final b = camera.visibleBounds;
    final key = tilesFor(south: b.south, west: b.west, north: b.north, east: b.east).join('|');
    if (key == _asked) return;
    _asked = key;
    _service.trafficSignals(south: b.south, west: b.west, north: b.north, east: b.east).then((found) {
      if (!mounted || found.isEmpty) return;
      final before = _signals.length;
      _signals.addAll(found);
      if (_signals.length != before) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    _fetch(camera);
    if (camera.zoom < trafficSignalsMinZoom || _signals.isEmpty) return const SizedBox.shrink();
    final b = camera.visibleBounds;
    return MarkerLayer(
      rotate: true,
      markers: [
        for (final p in _signals)
          if (b.contains(p)) Marker(point: p, width: 14, height: 22, child: const TrafficLightIcon()),
      ],
    );
  }
}

/// A small traffic light: three lamps in a dark housing.
class TrafficLightIcon extends StatelessWidget {
  const TrafficLightIcon({super.key});

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('traffic-signal'),
    padding: const EdgeInsets.symmetric(vertical: 2),
    decoration: BoxDecoration(
      color: const Color(0xFF222222),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: Colors.white, width: 1),
      boxShadow: const [BoxShadow(blurRadius: 2, color: Colors.black38)],
    ),
    child: const Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [_Lamp(Color(0xFFEF4444)), _Lamp(Color(0xFFF59E0B)), _Lamp(Color(0xFF22C55E))],
    ),
  );
}

class _Lamp extends StatelessWidget {
  const _Lamp(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 4.5,
    height: 4.5,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// How far the car has to move before the road under it is asked again.
const speedLimitRecheckMetres = 25.0;

/// The speed limit of the road at [at], as a round sign: the tagged
/// `maxspeed` in a red ring; where none is tagged, the road class and the
/// speed it stands for, marked as an estimate. Nothing while [at] is null or
/// OSM has no car road there.
class SpeedLimitBadge extends StatefulWidget {
  const SpeedLimitBadge({super.key, required this.at, this.service});
  final LatLng? at;

  /// Null is [RoadInfoService.shared].
  final RoadInfoService? service;

  @override
  State<SpeedLimitBadge> createState() => _SpeedLimitBadgeState();
}

class _SpeedLimitBadgeState extends State<SpeedLimitBadge> {
  RoadInfo? _road;
  LatLng? _askedAt;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _maybeAsk();
  }

  @override
  void didUpdateWidget(covariant SpeedLimitBadge old) {
    super.didUpdateWidget(old);
    _maybeAsk();
  }

  void _maybeAsk() {
    final at = widget.at;
    if (at == null) return;
    final last = _askedAt;
    if (last != null && const Distance()(last, at) < speedLimitRecheckMetres) return;
    _askedAt = at;
    final seq = ++_seq;
    (widget.service ?? RoadInfoService.shared).roadAt(at).then((road) {
      if (mounted && seq == _seq && road != null) setState(() => _road = road);
    });
  }

  @override
  Widget build(BuildContext context) {
    final road = _road;
    if (widget.at == null || road == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    return Semantics(
      label: road.estimated
          ? '${road.roadClass.label}, about ${road.speedKmh} km/h'
          : 'Speed limit ${road.speedKmh} km/h',
      child: Column(
        key: const ValueKey('speed-limit'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: road.estimated ? const Color(0xFF9CA3AF) : const Color(0xFFDC2626), width: 5),
              boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
            ),
            child: Text(
              '${road.speedKmh}',
              key: const ValueKey('speed-limit-value'),
              style: TextStyle(
                color: road.estimated ? const Color(0xFF6B7280) : Colors.black,
                fontSize: road.speedKmh >= 100 ? 14 : 17,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF262626) : Colors.white,
              borderRadius: BorderRadius.circular(6),
              boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
            ),
            child: Text(
              road.estimated ? '${road.roadClass.label} · est.' : road.roadClass.label,
              key: const ValueKey('speed-limit-road'),
              style: t.textTheme.labelSmall?.copyWith(fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}
