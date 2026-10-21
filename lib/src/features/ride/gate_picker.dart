// The rider's gate picker (migrations 0249 and 0258), for airports and for
// places with a boundary alike: the place's boundary shaded on a map, each
// gate a small lettered ring dot, a fixed pickup pin in the middle with the
// gate's name over it, and under the map a wheel of the gates (a wheel of
// groups beside it when the place has terminals). Scrolling the wheel flies
// the map to that gate; tapping a dot turns the wheel to it. "Done" chooses
// the gate; "Any gate" is there unless the place says riders must pick one.
//
// On the home map the chosen gate shows as a callout over the pin
// ([GateCallout]) that opens the picker again, and the boundary and gate dots
// stay drawn ([gateAreaLayers]).
//
// On an iPhone the map is Apple's own (a native view under the app's
// layers). Two rules keep the panel under it on screen there:
// - the map is clipped square (ClipRect), never rounded: a rounded clip on a
//   native view makes Flutter clip everything drawn after the view to that
//   rounded shape, which took the whole panel away (TestFlight 167);
// - the panel is painted before the map (a bottom-up column), so nothing
//   drawn after the native view lies outside it.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/airport_queue.dart';
import '../../core/gate_snap.dart';
import '../../widgets/map_tiles.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/ride_map.dart';
import 'airport_door_sheet.dart' show AirportGuideViewer;

/// What the rider chose: a gate, or any gate ([door] null).
class GatePick {
  const GatePick(this.door);
  final AirportDoor? door;
}

/// How close the picker's map comes (about street level), on opening and
/// whenever the wheel turns to a gate.
const gatePickerZoom = 17.75;

/// The most of the sheet the panel under the map takes; it scrolls past
/// that (large text, a guide), so the map always keeps the rest.
const gatePickerPanelShare = 0.62;

/// Opens the picker; answers the choice, or null when it was closed.
Future<GatePick?> showGatePicker(
  BuildContext context, {
  required String placeName,
  required List<AirportDoor> gates,
  List<List<LatLng>> rings = const [],
  String? selectedId,
  bool required = false,
  AirportSide side = AirportSide.pick,
  bool guides = false,
  List<Marker> cars = const [],
  Widget? typeIcon,
}) => showAppSheet<GatePick>(
  id: 'ride.gate_picker',
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  enableDrag: false,
  backgroundColor: Colors.transparent,
  builder: (c) => SizedBox(
    height: MediaQuery.sizeOf(c).height,
    child: GatePickerSheet(
      placeName: placeName,
      gates: gates,
      rings: rings,
      selectedId: selectedId,
      required: required,
      side: side,
      guides: guides,
      cars: cars,
      typeIcon: typeIcon,
      onDone: (p) => Navigator.of(c).pop(p),
      onClose: () => Navigator.of(c).pop(),
    ),
  ),
);

class GatePickerSheet extends StatefulWidget {
  const GatePickerSheet({
    super.key,
    required this.placeName,
    required this.gates,
    required this.onDone,
    required this.onClose,
    this.rings = const [],
    this.selectedId,
    this.required = false,
    this.side = AirportSide.pick,
    this.guides = false,
    this.cars = const [],
    this.tiles = true,
    this.typeIcon,
  });

  /// The place type's icon (0264), before the place's name.
  final Widget? typeIcon;

  final String placeName;
  final List<AirportDoor> gates;
  final List<List<LatLng>> rings;
  final String? selectedId;

  /// The place says riders must pick a gate: no "Any gate".
  final bool required;
  final AirportSide side;

  /// Show a pickup gate's guide link (the place's guide switch).
  final bool guides;

  /// Nearby cars, drawn on the map as on the home map.
  final List<Marker> cars;

  /// The map's tiles (off in tests).
  final bool tiles;
  final ValueChanged<GatePick> onDone;
  final VoidCallback onClose;

  @override
  State<GatePickerSheet> createState() => _GatePickerSheetState();
}

class _GatePickerSheetState extends State<GatePickerSheet> with SingleTickerProviderStateMixin {
  static const _extent = 58.0;

  late final List<GateGroup> _groups = gateGroups(widget.gates);
  late final (int, int) _start = gateIndex(_groups, _startId());
  late int _group = _start.$1;
  late int _index = _start.$2;
  late final FixedExtentScrollController _groupWheel = FixedExtentScrollController(initialItem: _group);
  late FixedExtentScrollController _gateWheel = FixedExtentScrollController(initialItem: _index);
  final _map = MapController();
  late final _fly = AnimationController(vsync: this, duration: const Duration(milliseconds: 350));
  Animation<LatLng>? _flight;
  Animation<double>? _flightZoom;
  bool _mapReady = false;
  AirportDoor? _guide;

  AirportDoor? _firstWithPoint() => widget.gates.where((g) => doorPoint(g) != null).firstOrNull ?? widget.gates.firstOrNull;

  /// The gate to open on: the one chosen before when it is still listed,
  /// else the first with a point.
  String? _startId() {
    final id = widget.selectedId;
    if (id != null && widget.gates.any((g) => g.id == id)) return id;
    return _firstWithPoint()?.id;
  }

  /// The gates of the group on the wheel (none when the place has none).
  List<AirportDoor> get _gatesHere =>
      _groups.isEmpty ? const <AirportDoor>[] : _groups[_group.clamp(0, _groups.length - 1)].gates;

  AirportDoor? get _selected {
    final gates = _gatesHere;
    return gates.isEmpty ? null : gates[_index.clamp(0, gates.length - 1)];
  }

  @override
  void initState() {
    super.initState();
    _fly.addListener(() {
      final f = _flight;
      if (f == null || !_mapReady) return;
      try {
        _map.move(f.value, _flightZoom?.value ?? _map.camera.zoom);
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _fly.dispose();
    _groupWheel.dispose();
    _gateWheel.dispose();
    super.dispose();
  }

  /// The map glides so [door] sits under the pin, back in to street level
  /// if the rider had zoomed out.
  void _flyTo(AirportDoor? door) {
    final to = door == null ? null : doorPoint(door);
    if (to == null || !_mapReady) return;
    LatLng from;
    double zoom;
    try {
      from = _map.camera.center;
      zoom = _map.camera.zoom;
    } catch (_) {
      return;
    }
    final curve = CurvedAnimation(parent: _fly, curve: Curves.easeInOut);
    _flight = LatLngTween(begin: from, end: to).animate(curve);
    _flightZoom = Tween<double>(begin: zoom, end: math.max(zoom, gatePickerZoom)).animate(curve);
    _fly.forward(from: 0);
  }

  void _onGroup(int g) {
    if (g == _group) return;
    HapticFeedback.selectionClick();
    setState(() {
      _group = g;
      _index = 0;
      _gateWheel.dispose();
      _gateWheel = FixedExtentScrollController();
    });
    _flyTo(_selected);
  }

  void _onGate(int i) {
    if (i == _index) return;
    HapticFeedback.selectionClick();
    setState(() => _index = i);
    _flyTo(_selected);
  }

  /// A dot tapped on the map: the wheels turn to it.
  void _tapGate(AirportDoor door) {
    final (g, i) = gateIndex(_groups, door.id);
    HapticFeedback.selectionClick();
    if (g != _group) {
      setState(() {
        _group = g;
        _index = i;
        _gateWheel.dispose();
        _gateWheel = FixedExtentScrollController(initialItem: i);
      });
      if (_groupWheel.hasClients) {
        _groupWheel.animateToItem(g, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    } else {
      setState(() => _index = i);
      if (_gateWheel.hasClients) {
        _gateWheel.animateToItem(i, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    }
    _flyTo(door);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final selected = _selected;
    final guide = _guide;
    final pickup = widget.side == AirportSide.pick;
    final letters = {for (var i = 0; i < widget.gates.length; i++) widget.gates[i].id: gateLetter(i)};
    final start = (selected == null ? null : doorPoint(selected)) ??
        widget.gates.map(doorPoint).nonNulls.firstOrNull ??
        (widget.rings.isNotEmpty && widget.rings.first.isNotEmpty ? widget.rings.first.first : const LatLng(3.139, 101.6869));

    final map = Stack(
      children: [
        Positioned.fill(
          child: FlutterMap(
            key: const ValueKey('gate-picker-map'),
            mapController: _map,
            options: MapOptions(
              initialCenter: start,
              initialZoom: gatePickerZoom,
              onMapReady: () => _mapReady = true,
            ),
            children: [
              if (widget.tiles) baseTileLayer(context),
              ...gateAreaLayers(
                context,
                // Only the outline the chosen gate is in.
                rings: ringsAround(widget.rings, (selected == null ? null : doorPoint(selected)) ?? start),
                gates: widget.gates,
                selectedId: selected?.id,
                letters: letters,
                onTapGate: _tapGate,
                cars: widget.cars,
              ),
            ],
          ),
        ),
        // The fixed pickup pin, the gate's name over it (its text grows
        // with the phone's text size only so far, so it stays on the map).
        Positioned.fill(
          child: IgnorePointer(
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: Align(
                child: FractionalTranslation(
                  translation: const Offset(0, -0.5),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 240),
                        child: Container(
                          key: const ValueKey('gate-picker-chip'),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: scheme.inverseSurface,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            selected?.name ?? 'Any gate',
                            textAlign: TextAlign.center,
                            softWrap: true,
                            style: t.textTheme.labelLarge?.copyWith(color: scheme.onInverseSurface),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      const PickupPin(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 12,
          left: 12,
          child: IconButton.filledTonal(
            key: const ValueKey('gate-picker-back'),
            tooltip: 'Back',
            onPressed: widget.onClose,
            icon: const Icon(Icons.arrow_back),
          ),
        ),
      ],
    );

    Widget wheel(
      Key key,
      FixedExtentScrollController c,
      List<String> labels,
      ValueChanged<int> onChanged,
    ) => Stack(
      children: [
        Center(
          child: Container(
            height: _extent,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, box) => ListWheelScrollView.useDelegate(
            key: key,
            controller: c,
            itemExtent: _extent,
            diameterRatio: 2.4,
            overAndUnderCenterOpacity: 0.4,
            physics: const FixedExtentScrollPhysics(),
            onSelectedItemChanged: onChanged,
            childDelegate: ListWheelChildBuilderDelegate(
              childCount: labels.length,
              builder: (_, i) => SizedBox(
                height: _extent,
                child: Center(
                  // A long name wraps, and shrinks rather than being cut.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: (box.maxWidth - 32).clamp(80, 600)),
                      child: Text(
                        labels[i],
                        key: ValueKey('${(key as ValueKey).value}-$i'),
                        textAlign: TextAlign.center,
                        style: t.textTheme.titleMedium,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );

    final gatesHere = _gatesHere;
    final panel = Material(
      key: const ValueKey('gate-picker-panel'),
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: guide != null
              ? SingleChildScrollView(
                  child: AirportGuideViewer(
                    door: guide,
                    onBack: () => setState(() => _guide = null),
                    onPickHere: () => setState(() => _guide = null),
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 48),
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (widget.typeIcon case final icon?) ...[icon, const SizedBox(width: 8)],
                              Flexible(
                                child: Text(
                                  widget.placeName,
                                  key: const ValueKey('gate-picker-title'),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton.filledTonal(
                          key: const ValueKey('gate-picker-close'),
                          tooltip: 'Close',
                          onPressed: widget.onClose,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    Text(
                      pickup ? 'Where should the driver pick you up?' : 'Which gate are you going to?',
                      textAlign: TextAlign.center,
                      style: t.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    // The wheel scrolls under the title and over Done when
                    // the text is large, so those always show.
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (widget.gates.isEmpty)
                              Padding(
                                key: const ValueKey('gate-picker-empty'),
                                padding: const EdgeInsets.symmetric(vertical: 24),
                                child: Text(
                                  'No gates listed here yet.',
                                  textAlign: TextAlign.center,
                                  style: t.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                                ),
                              )
                            else
                              SizedBox(
                                height: _extent * 3,
                                child: Row(
                                  children: [
                                    if (_groups.length > 1)
                                      Expanded(
                                        child: wheel(
                                          const ValueKey('gate-picker-groups'),
                                          _groupWheel,
                                          [for (final g in _groups) g.name],
                                          _onGroup,
                                        ),
                                      ),
                                    Expanded(
                                      child: wheel(
                                        ValueKey('gate-picker-gates-$_group'),
                                        _gateWheel,
                                        [for (final g in gatesHere) g.name],
                                        _onGate,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            if (pickup && widget.guides && selected != null && guideLinkLabel(selected) != null)
                              TextButton(
                                key: const ValueKey('gate-picker-guide'),
                                onPressed: () => setState(() => _guide = selected),
                                child: Text(guideLinkLabel(selected)!),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      key: const ValueKey('gate-picker-done'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: selected == null ? null : () => widget.onDone(GatePick(selected)),
                      child: const Text('Done'),
                    ),
                    // With no gates listed there is nothing else to choose.
                    if (!widget.required || widget.gates.isEmpty)
                      TextButton(
                        key: const ValueKey('gate-picker-any'),
                        onPressed: () => widget.onDone(const GatePick(null)),
                        child: const Text('Any gate'),
                      ),
                  ],
                ),
        ),
      ),
    );

    // Bottom-up, so the panel is painted before the map (see the top).
    return LayoutBuilder(
      builder: (context, box) => Column(
        verticalDirection: VerticalDirection.up,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: box.maxHeight.isFinite ? box.maxHeight * gatePickerPanelShare : double.infinity,
            ),
            child: panel,
          ),
          Expanded(child: ClipRect(key: const ValueKey('gate-picker-map-clip'), child: map)),
        ],
      ),
    );
  }
}

/// Animates between two points.
class LatLngTween extends Tween<LatLng> {
  LatLngTween({required LatLng begin, required LatLng end}) : super(begin: begin, end: end);

  @override
  LatLng lerp(double t) => LatLng(
    begin!.latitude + (end!.latitude - begin!.latitude) * t,
    begin!.longitude + (end!.longitude - begin!.longitude) * t,
  );
}

/// The boundary shaded in the theme's accent with a thin dashed outline,
/// the cars, and each gate as a small lettered ring dot (the [selectedId]
/// one filled and larger); [onTapGate] makes the dots tappable.
List<Widget> gateAreaLayers(
  BuildContext context, {
  required List<List<LatLng>> rings,
  required List<AirportDoor> gates,
  String? selectedId,
  Map<String, String> letters = const {},
  ValueChanged<AirportDoor>? onTapGate,
  List<Marker> cars = const [],
}) {
  final scheme = Theme.of(context).colorScheme;
  return [
    PolygonLayer(
      polygons: [
        for (final r in rings)
          if (r.length >= 3)
            Polygon(
              points: r,
              color: scheme.primary.withValues(alpha: 0.14),
              borderColor: scheme.primary,
              borderStrokeWidth: 1.5,
              pattern: StrokePattern.dashed(segments: const [8, 5]),
            ),
      ],
    ),
    if (cars.isNotEmpty) MarkerLayer(markers: cars),
    MarkerLayer(
      markers: [
        for (final g in gates)
          if (doorPoint(g) case final at?)
            Marker(
              point: at,
              width: 44,
              height: 44,
              child: GestureDetector(
                key: ValueKey('gate-dot-${g.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: onTapGate == null ? null : () => onTapGate(g),
                child: Center(child: GateDot(letter: letters[g.id] ?? '', selected: g.id == selectedId)),
              ),
            ),
      ],
    ),
  ];
}

/// A gate on the map: a ring with its letter; filled and larger when chosen.
class GateDot extends StatelessWidget {
  const GateDot({super.key, required this.letter, this.selected = false});
  final String letter;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = selected ? 26.0 : 18.0;
    return Semantics(
      selected: selected,
      label: 'Gate $letter',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? scheme.primary : scheme.surface,
          border: Border.all(color: scheme.primary, width: selected ? 3 : 2.5),
          boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
        ),
        child: Text(
          letter,
          style: TextStyle(
            fontSize: selected ? 12 : 9,
            fontWeight: FontWeight.w700,
            color: selected ? scheme.onPrimary : scheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Over the pickup pin once a gate is chosen: "Pickup point" over the
/// gate's name, with a chevron; tapping it opens the picker again.
class GateCallout extends StatelessWidget {
  const GateCallout({super.key, required this.name, required this.onTap, this.label = 'Pickup point', this.leading});
  final String name;
  final String label;
  final VoidCallback onTap;

  /// The place type's icon (0264), before the words.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    return Material(
      key: const ValueKey('gate-callout'),
      color: scheme.surface,
      elevation: 4,
      shadowColor: Colors.black45,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260, minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leading case final l?) ...[l, const SizedBox(width: 10)],
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: t.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                      Text(
                        name,
                        softWrap: true,
                        style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
