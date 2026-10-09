// Choosing a place on the map (inDrive's): the map moves under a flag fixed
// in the middle, a label over the flag names the spot once the map has
// settled (a spinner while it is being looked up), and Done hands the place
// back. Used by "Choose on map", the map button in the address fields, and
// saving a place.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../data/geo_service.dart';
import '../../providers.dart';
import '../../widgets/map_recenter.dart';
import '../../widgets/map_tiles.dart';
import '../../widgets/map_type_button.dart';

/// Opens the picker at [start] (else [me]); the place chosen, or null.
Future<Place?> pickPlaceOnMap(BuildContext context, {LatLng? start, LatLng? me}) => Navigator.of(context).push<Place>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => MapPlacePicker(start: start, me: me),
  ),
);

class MapPlacePicker extends ConsumerStatefulWidget {
  const MapPlacePicker({super.key, this.start, this.me});

  final LatLng? start;

  /// The rider's position, for the recenter button.
  final LatLng? me;

  /// How long the map must be still before the spot is looked up.
  static const settle = Duration(milliseconds: 350);

  @override
  ConsumerState<MapPlacePicker> createState() => _MapPlacePickerState();
}

class _MapPlacePickerState extends ConsumerState<MapPlacePicker> {
  final _map = MapController();
  late LatLng _centre = widget.start ?? widget.me ?? defaultCenter;
  Place? _place;
  bool _moving = false;
  bool _looking = true;
  Timer? _settle;
  int _lookup = 0;

  @override
  void initState() {
    super.initState();
    _lookUp(_centre);
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  void _onEvent(MapEvent e) {
    if (e is MapEventMove || e is MapEventMoveStart || e is MapEventFlingAnimation || e is MapEventDoubleTapZoom) {
      _centre = e.camera.center;
      if (!_moving || !_looking) {
        setState(() {
          _moving = true;
          _looking = true;
        });
      }
    }
    _settle?.cancel();
    _settle = Timer(MapPlacePicker.settle, () {
      if (!mounted) return;
      setState(() => _moving = false);
      _lookUp(_map.camera.center);
    });
  }

  Future<void> _lookUp(LatLng p) async {
    final n = ++_lookup;
    setState(() => _looking = true);
    Place? place;
    try {
      place = await ref.read(geoServiceProvider).reverse(p);
    } catch (_) {
      place = null;
    }
    if (!mounted || n != _lookup) return;
    setState(() {
      _looking = false;
      // Unnamed, the spot is still a place: its coordinates.
      _place =
          place ??
          Place(name: '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}', address: '', point: p);
    });
  }

  void _recenter() {
    final me = widget.me;
    if (me == null) return;
    try {
      _map.move(me, 17);
    } catch (_) {}
    _onEvent(MapEventMove(camera: _map.camera, oldCamera: _map.camera, source: MapEventSource.mapController));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final fill = dark ? Colors.white : const Color(0xFF111111);
    final ink = dark ? Colors.black : Colors.white;
    final ready = !_moving && !_looking && _place != null;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              key: const ValueKey('map-picker-map'),
              mapController: _map,
              options: MapOptions(
                initialCenter: _centre,
                initialZoom: 17,
                onMapEvent: _onEvent,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
              ),
              children: [
                baseTileLayer(context, satellite: ref.watch(mapSatelliteProvider)),
                if (widget.me != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: widget.me!,
                        width: 20,
                        height: 20,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0xFF2D7FF9),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                            boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
                          ),
                        ),
                      ),
                    ],
                  ),
                const RichAttributionWidget(
                  alignment: AttributionAlignment.bottomLeft,
                  attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
                ),
              ],
            ),
          ),
          // The flag on the middle of the map, its stem's foot on the point,
          // and the label over it.
          IgnorePointer(
            child: Center(
              child: Transform.translate(
                offset: Offset(0, -_PickerPin.height / 2 + (_moving ? -10 : 0)),
                child: _PickerPin(fill: fill, ink: ink, place: _moving ? null : _place, looking: _looking || _moving),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Material(
                color: t.colorScheme.surface,
                shape: const CircleBorder(),
                elevation: 3,
                child: IconButton(
                  key: const ValueKey('map-picker-back'),
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 96,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const MapTypeButton(),
                  const SizedBox(height: 8),
                  RecenterButton(onPressed: widget.me == null ? null : _recenter),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              child: FilledButton(
                key: const ValueKey('map-picker-done'),
                onPressed: ready ? () => Navigator.pop(context, _place) : null,
                child: const Text('Done', style: TextStyle(fontSize: 18)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The label (the place's name, or a spinner while it is looked up) over
/// a flag in a rounded square, on a stem whose foot is the point.
class _PickerPin extends StatelessWidget {
  const _PickerPin({required this.fill, required this.ink, required this.place, required this.looking});

  final Color fill, ink;
  final Place? place;
  final bool looking;

  static const _label = 46.0, _gap = 10.0, _badge = 48.0, _stem = 16.0;
  static const height = _label + _gap + _badge + _stem;

  @override
  Widget build(BuildContext context) {
    final name = place?.name;
    return SizedBox(
      height: height,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: _label,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: Container(
                key: ValueKey(looking ? 'looking' : name),
                constraints: const BoxConstraints(minWidth: _label, maxWidth: 280),
                padding: EdgeInsets.symmetric(horizontal: looking ? 0 : 18),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
                ),
                child: looking
                    ? SizedBox.square(
                        key: const ValueKey('map-picker-looking'),
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 3, color: ink),
                      )
                    : Text(
                        name ?? '',
                        key: const ValueKey('map-picker-name'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: ink, fontSize: 17, fontWeight: FontWeight.w600),
                      ),
              ),
            ),
          ),
          const SizedBox(height: _gap),
          Container(
            width: _badge,
            height: _badge,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(_badge * 0.28),
              boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
            ),
            child: Icon(Icons.flag, color: ink, size: 28),
          ),
          Container(width: 3, height: _stem, color: fill),
        ],
      ),
    );
  }
}
