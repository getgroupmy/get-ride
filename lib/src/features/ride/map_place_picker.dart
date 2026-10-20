// Choosing a place on the map (inDrive's): the map moves under a flag fixed
// in the middle, a label over the flag names the spot once the map has
// settled (the last name, greyed, with a small spinner while the new spot
// is looked up), a dot on the ground marks the exact point, and Done hands
// the place back. Used by "Choose on map", the map button in the address fields, and
// saving a place.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../data/geo_service.dart';
import '../../providers.dart';
import '../../widgets/map_recenter.dart';
import '../../widgets/map_credit.dart';
import '../../widgets/map_tiles.dart';
import '../../widgets/map_type_button.dart';
import '../../widgets/page_style_host.dart';

/// Where the phone is now, for "Use my location" (a fake in tests).
final pickerPositionProvider = Provider<Future<LatLng?> Function()>((_) => currentPosition);

/// Opens the picker at [start] (else [me]); the place chosen, or null.
Future<Place?> pickPlaceOnMap(BuildContext context, {LatLng? start, LatLng? me}) => Navigator.of(context).push<Place>(
  AppPageRoute(id: 'map-place-picker.pick-place-on-map',
    fullscreenDialog: true,
    builder: (_) => MapPlacePicker(start: start, me: me),
  ),
);

class MapPlacePicker extends ConsumerStatefulWidget {
  const MapPlacePicker({super.key, this.start, this.me});

  final LatLng? start;

  /// The rider's position: shown as a blue dot, and where "Use my
  /// location" goes when no fresh fix can be had.
  final LatLng? me;

  /// How long the map must be still before the spot is looked up.
  static const settle = Duration(milliseconds: 350);

  /// Under Done while the spot is being named.
  static const findingCaption = 'Finding address…';

  /// When no fix can be had for "Use my location".
  static const noFixMessage = "Can't find your location. Turn location on and try again.";

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
  bool _locating = false;

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

  /// "Use my location": the pin onto a fresh fix (else the position the
  /// picker was opened with), and the spot looked up there.
  Future<void> _useMyLocation() async {
    if (_locating) return;
    setState(() => _locating = true);
    LatLng? here;
    try {
      here = await ref.read(pickerPositionProvider)();
    } catch (_) {
      here = null;
    }
    here ??= widget.me;
    if (!mounted) return;
    setState(() => _locating = false);
    if (here == null) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text(MapPlacePicker.noFixMessage)));
      return;
    }
    recenterMap(_map, here, zoom: 17);
    _onEvent(MapEventMove(camera: _map.camera, oldCamera: _map.camera, source: MapEventSource.mapController));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = mapIsDark(context);
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
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate, keyboardOptions: mapKeyboardOptions),
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
                // Above the Done bar, so its ⓘ can be reached.
                Padding(
                  key: const ValueKey('map-picker-credit'),
                  padding: const EdgeInsets.only(bottom: 80 + _captionHeight),
                  child: MapCreditLayer(satellite: ref.watch(mapSatelliteProvider)),
                ),
              ],
            ),
          ),
          // The dot on the ground at the exact point (it stays put while
          // the flag lifts during a drag).
          IgnorePointer(
            child: Center(child: _GroundDot(fill: fill)),
          ),
          // The flag on the middle of the map, its stem's foot on the point,
          // and the label over it.
          IgnorePointer(
            child: Center(
              child: Transform.translate(
                offset: Offset(0, -_PickerPin.height / 2 + (_moving ? -10 : 0)),
                child: _PickerPin(fill: fill, ink: ink, place: _place, looking: _looking || _moving),
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
            bottom: 96 + _captionHeight,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const MapTypeButton(),
                  const SizedBox(height: 8),
                  _MyLocationButton(locating: _locating, onPressed: _useMyLocation),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    key: const ValueKey('map-picker-done'),
                    onPressed: ready ? () => Navigator.pop(context, _place) : null,
                    child: const Text('Done', style: TextStyle(fontSize: 18)),
                  ),
                  // Why Done is dimmed; the line is always there so Done
                  // does not jump.
                  SizedBox(
                    height: _captionHeight,
                    child: Center(
                      child: AnimatedOpacity(
                        opacity: ready ? 0 : 1,
                        duration: const Duration(milliseconds: 150),
                        child: Semantics(
                          liveRegion: !ready,
                          child: Text(
                            ready ? '' : MapPlacePicker.findingCaption,
                            key: const ValueKey('map-picker-caption'),
                            style: t.textTheme.bodySmall?.copyWith(
                              color: t.colorScheme.onSurface,
                              fontWeight: FontWeight.w600,
                              shadows: [Shadow(blurRadius: 6, color: t.colorScheme.surface)],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The height of the line under Done.
const _captionHeight = 22.0;

/// "Use my location": a small pill with the shared recenter arrow, a
/// spinner while the fix is fetched.
class _MyLocationButton extends StatelessWidget {
  const _MyLocationButton({required this.locating, required this.onPressed});

  final bool locating;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final dark = mapIsDark(context);
    final ink = dark ? Colors.white : const Color(0xFF111111);
    return Semantics(
      button: true,
      label: 'Use my location',
      excludeSemantics: true,
      child: Material(
        key: const ValueKey('map-picker-my-location'),
        color: dark ? RecenterButton.darkFill : RecenterButton.lightFill,
        shape: const StadiumBorder(),
        elevation: 4,
        shadowColor: Colors.black45,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: locating ? null : onPressed,
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 20,
                    child: locating
                        ? Padding(
                            padding: const EdgeInsets.all(2),
                            child: CircularProgressIndicator(strokeWidth: 2, color: ink),
                          )
                        : Icon(Icons.near_me_outlined, size: 20, color: ink),
                  ),
                  const SizedBox(width: 8),
                  Text('Use my location', style: TextStyle(color: ink, fontSize: 14, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The exact point: a small dot with a soft shadow on the ground, under the
/// stem's foot.
class _GroundDot extends StatelessWidget {
  const _GroundDot({required this.fill});

  final Color fill;

  static const size = 10.0;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('map-picker-ground'),
    width: 24,
    height: 12,
    child: Stack(
      alignment: Alignment.center,
      children: [
        // The shadow, flattened onto the ground.
        Container(
          width: 24,
          height: 9,
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.elliptical(12, 4.5)),
            color: Colors.black.withValues(alpha: 0.28),
          ),
        ),
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: fill,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      ],
    ),
  );
}

/// The label (the place's name; the last name greyed with a small spinner
/// while the spot is looked up) over a flag in a rounded square, on a stem
/// whose foot is the point.
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
            child: Container(
              constraints: const BoxConstraints(minWidth: _label, maxWidth: 280),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (looking) ...[
                    SizedBox.square(
                      key: const ValueKey('map-picker-looking'),
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: ink.withValues(alpha: 0.7)),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: AnimatedOpacity(
                      opacity: looking ? 0.55 : 1,
                      duration: const Duration(milliseconds: 150),
                      child: Text(
                        name ?? MapPlacePicker.findingCaption,
                        key: ValueKey(looking ? 'map-picker-name-stale' : 'map-picker-name'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: ink, fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
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
