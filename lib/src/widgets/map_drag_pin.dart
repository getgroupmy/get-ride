import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'map_sheet_layout.dart';
import 'ride_map.dart';

/// Camera moves the app makes itself, which never pick a pin up.
const _programmatic = {
  MapEventSource.mapController,
  MapEventSource.fitCamera,
  MapEventSource.custom,
  MapEventSource.nonRotatedSizeChange,
};

/// A pin set by dragging the map under it (the home screen's pickup).
///
/// When the map is moved by hand, the pin is lifted off the map where it
/// stood (or in the middle of the part a sheet leaves showing, when it was
/// off screen) and floats there while the map slides beneath it. When the
/// fingers are off and the map has stopped for [settle], it drops with a
/// bounce, and the point under it is handed to [onDropped].
///
/// [onMoving] is true from the lift until the pin has landed: the map's own
/// pickup marker (and the box above it) hides meanwhile, and the drop lands
/// exactly where that marker is drawn, so it takes over without a jump.
class MapDragPin extends StatefulWidget {
  const MapDragPin({
    super.key,
    required this.controller,
    required this.child,
    required this.pin,
    required this.onDropped,
    this.onMoving,
    this.enabled = true,
    this.settle = const Duration(milliseconds: 200),
  });

  final MapController controller;

  /// The map.
  final Widget child;

  /// Where the pin stands now; null for none yet.
  final LatLng? pin;
  final ValueChanged<LatLng> onDropped;
  final ValueChanged<bool>? onMoving;
  final bool enabled;
  final Duration settle;

  /// How far the pin floats above its point while the map moves.
  static const lift = 25.0;

  @override
  State<MapDragPin> createState() => _MapDragPinState();
}

class _MapDragPinState extends State<MapDragPin> with SingleTickerProviderStateMixin {
  late final AnimationController _lift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    reverseDuration: const Duration(milliseconds: 500),
  );
  late final Animation<double> _height = CurvedAnimation(
    parent: _lift,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.bounceOut,
  );
  StreamSubscription<MapEvent>? _events;
  Timer? _quiet;

  /// The pin's point on the map widget while it is off the map; null when
  /// it is down.
  Offset? _at;
  int _pointers = 0;

  @override
  void initState() {
    super.initState();
    _events = widget.controller.mapEventStream.listen(_onEvent);
  }

  @override
  void didUpdateWidget(covariant MapDragPin old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      _events?.cancel();
      _events = widget.controller.mapEventStream.listen(_onEvent);
    }
    // Switched off mid-drag (a destination was set): put it back unmoved.
    if (!widget.enabled && _at != null) {
      _quiet?.cancel();
      _lift.value = 0;
      _at = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onMoving?.call(false));
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    _quiet?.cancel();
    _lift.dispose();
    super.dispose();
  }

  void _onEvent(MapEvent e) {
    if (!widget.enabled || !mounted || e is! MapEventWithMove || _programmatic.contains(e.source)) return;
    if (_at == null) {
      final at = _startAt(e.oldCamera);
      setState(() => _at = at);
      widget.onMoving?.call(true);
    }
    _lift.forward();
    _armDrop();
  }

  /// Where the pin lifts from: where it stands, if that is in view.
  Offset _startAt(MapCamera camera) {
    final size = camera.nonRotatedSize;
    final visible = Size(size.width, (size.height - MapBottomInset.of(context)).clamp(1, size.height));
    final pin = widget.pin;
    if (pin != null) {
      final p = camera.latLngToScreenOffset(pin);
      if (p.dx >= 0 && p.dx <= visible.width && p.dy >= pickupPinHeight && p.dy <= visible.height) return p;
    }
    return visible.center(Offset.zero);
  }

  void _armDrop() {
    _quiet?.cancel();
    _quiet = Timer(widget.settle, _drop);
  }

  void _drop() {
    final at = _at;
    // Still held down: the drop waits for the finger to come off.
    if (!mounted || at == null || _pointers > 0) return;
    widget.onDropped(widget.controller.camera.screenOffsetToLatLng(at));
    _lift.reverse().then((_) {
      if (!mounted || _lift.value != 0) return;
      setState(() => _at = null);
      widget.onMoving?.call(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final at = _at;
    return Stack(
      children: [
        Listener(
          onPointerDown: (_) => _pointers++,
          onPointerUp: (_) => _release(),
          onPointerCancel: (_) => _release(),
          child: widget.child,
        ),
        if (at != null)
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _height,
              builder: (context, _) {
                final up = _height.value;
                return Stack(
                  children: [
                    // The spot it will land on, darker the higher it floats.
                    Positioned(
                      left: at.dx - 7,
                      top: at.dy - 3,
                      width: 14,
                      height: 6,
                      child: Opacity(
                        opacity: up.clamp(0.0, 1.0),
                        child: const DecoratedBox(
                          key: ValueKey('drag-pin-shadow'),
                          decoration: BoxDecoration(
                            color: Colors.black38,
                            borderRadius: BorderRadius.all(Radius.elliptical(7, 3)),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      key: const ValueKey('drag-pin'),
                      left: at.dx - pickupPinHead / 2,
                      top: at.dy - pickupPinHeight - up * MapDragPin.lift,
                      width: pickupPinHead,
                      height: pickupPinHeight,
                      child: PickupPin(elevation: up.clamp(0.0, 1.0)),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }

  void _release() {
    if (_pointers > 0) _pointers--;
    if (_at != null && _pointers == 0) _armDrop();
  }
}
