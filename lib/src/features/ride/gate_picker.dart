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

/// How close the picker's map comes (about street level).
const gatePickerZoom = 18.0;

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
  });

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
  late int _group = gateIndex(_groups, widget.selectedId ?? _firstWithPoint()?.id).$1;
  late int _index = gateIndex(_groups, widget.selectedId ?? _firstWithPoint()?.id).$2;
  late final FixedExtentScrollController _groupWheel = FixedExtentScrollController(initialItem: _group);
  late FixedExtentScrollController _gateWheel = FixedExtentScrollController(initialItem: _index);
  final _map = MapController();
  late final _fly = AnimationController(vsync: this, duration: const Duration(milliseconds: 350));
  Animation<LatLng>? _flight;
  bool _mapReady = false;
  AirportDoor? _guide;

  AirportDoor? _firstWithPoint() => widget.gates.where((g) => doorPoint(g) != null).firstOrNull ?? widget.gates.firstOrNull;

  AirportDoor? get _selected {
    if (_groups.isEmpty) return null;
    final gates = _groups[_group.clamp(0, _groups.length - 1)].gates;
    return gates.isEmpty ? null : gates[_index.clamp(0, gates.length - 1)];
  }

  @override
  void initState() {
    super.initState();
    _fly.addListener(() {
      final f = _flight;
      if (f == null || !_mapReady) return;
      try {
        _map.move(f.value, _map.camera.zoom);
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

  /// The map glides so [door] sits under the pin.
  void _flyTo(AirportDoor? door) {
    final to = door == null ? null : doorPoint(door);
    if (to == null || !_mapReady) return;
    LatLng from;
    try {
      from = _map.camera.center;
    } catch (_) {
      return;
    }
    _flight = LatLngTween(begin: from, end: to).animate(CurvedAnimation(parent: _fly, curve: Curves.easeInOut));
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
                rings: widget.rings,
                gates: widget.gates,
                selectedId: selected?.id,
                letters: letters,
                onTapGate: _tapGate,
                cars: widget.cars,
              ),
            ],
          ),
        ),
        // The fixed pickup pin, the gate's name over it.
        Positioned.fill(
          child: IgnorePointer(
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

    final gatesHere = _groups.isEmpty ? const <AirportDoor>[] : _groups[_group].gates;
    final panel = Material(
      color: scheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: guide != null
              ? AirportGuideViewer(
                  door: guide,
                  onBack: () => setState(() => _guide = null),
                  onPickHere: () => setState(() => _guide = null),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 48),
                        Expanded(
                          child: Text(
                            widget.placeName,
                            key: const ValueKey('gate-picker-title'),
                            textAlign: TextAlign.center,
                            style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
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
                    const SizedBox(height: 8),
                    FilledButton(
                      key: const ValueKey('gate-picker-done'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: selected == null ? null : () => widget.onDone(GatePick(selected)),
                      child: const Text('Done'),
                    ),
                    if (!widget.required)
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

    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: map,
          ),
        ),
        panel,
      ],
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
  const GateCallout({super.key, required this.name, required this.onTap, this.label = 'Pickup point'});
  final String name;
  final String label;
  final VoidCallback onTap;

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
