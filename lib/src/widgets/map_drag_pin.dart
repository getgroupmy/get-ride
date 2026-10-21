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
  State<MapDragPin> createState() => MapDragPinState();
}

class MapDragPinState extends State<MapDragPin> with TickerProviderStateMixin {
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

  /// The map gliding under the lifted pin ([runTo]).
  late final AnimationController _run = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  /// The pin's point on the map widget while it is off the map; null when
  /// it is down.
  Offset? _at;
  int _pointers = 0;

  @override
  void initState() {
    super.initState();
    _events = widget.controller.mapEventStream.listen(_onEvent);
    _run.addListener(_onRun);
  }

  @override
  void didUpdateWidget(covariant MapDragPin oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _events?.cancel();
      _events = widget.controller.mapEventStream.listen(_onEvent);
    }
    // Switched off mid-drag (a destination was set): put it back unmoved.
    if (!widget.enabled && _at != null) {
      _quiet?.cancel();
      _run.stop();
      _lift.value = 0;
      _at = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onMoving?.call(false));
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    _quiet?.cancel();
    _run.dispose();
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

  /// Where the pin lifts from: where it stands, if that is in view; else
  /// the middle of the map above the sheet when it is all the way down,
  /// where the map keeps it ([MapBottomInset.focusOffset]).
  Offset _startAt(MapCamera camera) {
    final size = camera.nonRotatedSize;
    final visible = Size(size.width, (size.height - MapBottomInset.of(context)).clamp(1, size.height));
    final pin = widget.pin;
    if (pin != null) {
      final p = camera.latLngToScreenOffset(pin);
      if (p.dx >= 0 && p.dx <= visible.width && p.dy >= pickupPinHeight && p.dy <= visible.height) return p;
    }
    return size.center(MapBottomInset.focusOffset(context));
  }

  /// Lifts the pin and drops it on [at] (the recenter button putting the
  /// pickup on the rider's fix): the same float and bounce as a drag, with
  /// [MapDragPin.onDropped] told [at] when it lands. Call it once the camera
  /// is where it will stay.
  void dropAt(LatLng at) {
    if (!widget.enabled || !mounted) return;
    _quiet?.cancel();
    final p = widget.controller.camera.latLngToScreenOffset(at);
    final lifting = _at == null;
    setState(() => _at = p);
    if (lifting) widget.onMoving?.call(true);
    _lift.forward();
    // Up, a moment in the air, then down onto the fix.
    _quiet = Timer(_lift.duration! + widget.settle, () {
      if (mounted && _at == p) _land(at);
    });
  }

  /// Lifts the pin from [from], where it was dropped, and carries it on to
  /// [to] while the map glides under it ([zoom] at the end, [to] kept at
  /// [offset] from the map's centre, as [MapController.move]), then drops it
  /// there with [MapDragPin.onDropped] told [to]: the pickup running on to
  /// the nearest gate of the place it was dropped in (0258). False when the
  /// pin can't move now (off, or the map not drawn yet).
  bool runTo(LatLng from, LatLng to, {required double zoom, Offset offset = Offset.zero}) {
    if (!widget.enabled || !mounted) return false;
    final MapCamera camera;
    try {
      camera = widget.controller.camera;
    } catch (_) {
      return false;
    }
    _quiet?.cancel();
    final focus = camera.nonRotatedSize.center(offset);
    final pin = camera.latLngToScreenOffset(from);
    // From the point under the pin's resting place now, so the glide starts
    // where the map is.
    _glide = (
      from: camera.screenOffsetToLatLng(focus),
      to: to,
      fromZoom: camera.zoom,
      toZoom: zoom,
      offset: offset,
      pin: pin,
      focus: focus,
    );
    final lifting = _at == null;
    setState(() => _at = pin);
    if (lifting) widget.onMoving?.call(true);
    _lift.forward();
    _run.forward(from: 0).then((_) {
      if (!mounted) return;
      _quiet = Timer(widget.settle, () {
        if (mounted && _at == focus) _land(to);
      });
    });
    return true;
  }

  /// The glide [runTo] is making: the map's point under [focus] from
  /// [from] to [to], and the pin from [pin] to [focus].
  ({LatLng from, LatLng to, double fromZoom, double toZoom, Offset offset, Offset pin, Offset focus})? _glide;

  void _onRun() {
    final g = _glide;
    if (g == null || !mounted) return;
    final t = Curves.easeInOut.transform(_run.value);
    try {
      widget.controller.move(
        LatLng(
          g.from.latitude + (g.to.latitude - g.from.latitude) * t,
          g.from.longitude + (g.to.longitude - g.from.longitude) * t,
        ),
        g.fromZoom + (g.toZoom - g.fromZoom) * t,
        offset: g.offset,
      );
    } catch (_) {}
    setState(() => _at = t >= 1 ? g.focus : Offset.lerp(g.pin, g.focus, t));
  }

  void _armDrop() {
    _quiet?.cancel();
    _quiet = Timer(widget.settle, _drop);
  }

  void _drop() {
    final at = _at;
    // Still held down: the drop waits for the finger to come off.
    if (!mounted || at == null || _pointers > 0) return;
    _land(widget.controller.camera.screenOffsetToLatLng(at));
  }

  void _land(LatLng point) {
    widget.onDropped(point);
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
          onPointerDown: (_) {
            _pointers++;
            // A finger on the map takes over from a glide ([runTo]).
            if (_run.isAnimating) _run.stop();
          },
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
