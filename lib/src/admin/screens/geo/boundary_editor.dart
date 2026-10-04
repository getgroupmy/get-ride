import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../data/geo_service.dart';
import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';
import 'geo_data.dart';
import 'geo_logic.dart';

/// OpenStreetMap tiles shared by the geography map editors (same tiles as
/// `RideMap`).
List<Widget> osmBaseLayers(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return [
    TileLayer(
      urlTemplate: dark
          ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png'
          : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      subdomains: const ['a', 'b', 'c', 'd'],
      userAgentPackageName: 'my.getgroup.get_ride',
      retinaMode: dark && RetinaMode.isHighDensity(context),
    ),
  ];
}

const _osmAttribution = RichAttributionWidget(
  attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
);

enum _DrawMode { off, draw, edit }

/// Geofence editor (Expo "Boundary" sheet): fetch a polygon from OSM, type a
/// bounding box, or draw / edit vertices by tapping the map.
class BoundaryEditorPage extends ConsumerStatefulWidget {
  const BoundaryEditorPage({
    super.key,
    required this.title,
    required this.query,
    required this.canEdit,
    required this.onSave,
    this.initial,
    this.near,
    this.reverseFirst = false,
    this.onClear,
  });

  final String title;

  /// Geocoder query (and subtitle), e.g. "Selangor, Malaysia".
  final String query;
  final bool canEdit;
  final BoundaryShape? initial;

  /// Bias / reverse-lookup point (airports use their assigned place).
  final LatLng? near;
  final bool reverseFirst;
  final Future<void> Function(BoundaryShape shape) onSave;

  /// Removes the stored boundary; null when nothing is stored.
  final Future<void> Function()? onClear;

  static Future<void> open(BuildContext context, BoundaryEditorPage page) =>
      Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => page));

  @override
  ConsumerState<BoundaryEditorPage> createState() => _BoundaryEditorPageState();
}

class _BoundaryEditorPageState extends ConsumerState<BoundaryEditorPage> {
  final _map = MapController();
  bool _ready = false;
  late BoundaryShape? _boundary = widget.initial;
  late bool _hasStored = widget.onClear != null;
  _DrawMode _mode = _DrawMode.off;
  List<LatLng> _draft = [];
  int? _selected;
  bool _busy = false;
  final _n = TextEditingController(), _s = TextEditingController(), _e = TextEditingController(), _w = TextEditingController();

  @override
  void initState() {
    super.initState();
    _syncBBox();
  }

  @override
  void dispose() {
    for (final c in [_n, _s, _e, _w]) {
      c.dispose();
    }
    super.dispose();
  }

  void _syncBBox() {
    final b = _boundary?.bbox;
    _n.text = b == null ? '' : '${b.north}';
    _s.text = b == null ? '' : '${b.south}';
    _e.text = b == null ? '' : '${b.east}';
    _w.text = b == null ? '' : '${b.west}';
  }

  void _setBoundary(BoundaryShape? b) {
    setState(() => _boundary = b);
    _syncBBox();
    _fit();
  }

  void _fit() {
    if (!_ready) return;
    final b = _boundary;
    if (b != null) {
      final bb = b.bbox;
      if (bb.north == bb.south && bb.east == bb.west) {
        _map.move(bb.center, 14);
      } else {
        _map.fitCamera(CameraFit.bounds(
          bounds: LatLngBounds(LatLng(bb.south, bb.west), LatLng(bb.north, bb.east)),
          padding: const EdgeInsets.all(32),
        ));
      }
    } else if (widget.near != null) {
      _map.move(widget.near!, 13);
    }
  }

  void _onTap(LatLng p) {
    if (!widget.canEdit) return;
    if (_mode == _DrawMode.draw) {
      setState(() => _draft = [..._draft, p]);
    } else if (_mode == _DrawMode.edit && _selected != null) {
      setState(() => _draft = [for (var i = 0; i < _draft.length; i++) i == _selected ? p : _draft[i]]);
    }
  }

  void _startDraw() => setState(() {
        _mode = _DrawMode.draw;
        _draft = [];
        _selected = null;
      });

  void _startEdit() {
    final b = _boundary;
    if (b == null || b.coords.isEmpty) {
      showInfo(context, 'Fetch or draw a boundary first, then edit its vertices.');
      return;
    }
    setState(() {
      _mode = _DrawMode.edit;
      _draft = [...b.coords];
      _selected = null;
    });
  }

  void _cancelDraw() => setState(() {
        _mode = _DrawMode.off;
        _draft = [];
        _selected = null;
      });

  void _finish() {
    final shape = boundaryFromDraft(_draft);
    if (shape == null) {
      showInfo(context, 'A polygon requires three or more vertices.');
      return;
    }
    setState(() {
      _mode = _DrawMode.off;
      _draft = [];
      _selected = null;
    });
    _setBoundary(shape);
  }

  Future<void> _fetchOsm() async {
    setState(() => _busy = true);
    final osm = ref.read(osmLookupProvider);
    try {
      var list = <BoundaryCandidate>[];
      if (widget.reverseFirst && widget.near != null) {
        final both = await Future.wait([
          osm.reverseBoundaries(widget.near!),
          osm.boundaries(widget.query, near: widget.near),
        ]);
        list = mergeCandidates(both[0], both[1]);
      } else {
        list = await osm.boundaries(widget.query, near: widget.near);
      }
      if (!mounted) return;
      if (list.isEmpty) {
        showInfo(context, 'OSM returned no results for this query.');
      } else if (list.length == 1) {
        _setBoundary(list.first.shape);
      } else {
        final picked = await _pickCandidate(list);
        if (picked != null) _setBoundary(picked.shape);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _applyBBox() {
    final shape = boundaryFromBBoxInput(_n.text, _s.text, _e.text, _w.text);
    if (shape == null) {
      showInfo(context, 'Enter all four bounds (N, S, E, W).');
      return;
    }
    _setBoundary(shape);
  }

  Future<BoundaryCandidate?> _pickCandidate(List<BoundaryCandidate> initial) {
    var list = initial;
    var exhausted = false;
    var loading = false;
    return showAdminSheet<BoundaryCandidate>(
      context,
      title: 'Select OSM result',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${list.length} matches found', style: Theme.of(ctx).textTheme.bodySmall),
          const SizedBox(height: 8),
          for (final c in list)
            Card(
              child: ListTile(
                title: Text(c.displayName.isEmpty ? '(unnamed)' : c.displayName, maxLines: 2),
                subtitle: Text(
                  '${c.tag.isEmpty ? 'result' : c.tag} · '
                  '${c.shape.polygons != null ? '${c.shape.polygons!.length} poly' : 'bbox'} · ${c.shape.pointCount} pts',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(ctx, c),
              ),
            ),
          const SizedBox(height: 8),
          if (exhausted)
            const Center(child: Text('0 more results'))
          else
            OutlinedButton.icon(
              icon: loading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download),
              label: const Text('More results'),
              onPressed: loading
                  ? null
                  : () async {
                      setSheet(() => loading = true);
                      final nextLimit = (list.length + 10).clamp(1, 50);
                      final fresh =
                          await ref.read(osmLookupProvider).boundaries(widget.query, limit: nextLimit, near: widget.near);
                      final merged = mergeCandidates(list, fresh);
                      setSheet(() {
                        exhausted = merged.length == list.length || nextLimit >= 50;
                        list = merged;
                        loading = false;
                      });
                    },
            ),
        ]),
      ),
    );
  }

  Future<void> _save() async {
    final b = _boundary;
    if (b == null) return;
    final ok = await runAdminAction(context, () => widget.onSave(b), success: 'Boundary saved');
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _clear() async {
    if (_hasStored && widget.onClear != null) {
      if (!await confirm(context, 'Clear boundary', 'Remove the saved boundary for this area?', ok: 'Clear')) return;
      if (!mounted) return;
      final ok = await runAdminAction(context, widget.onClear!, success: 'Boundary cleared');
      if (!ok) return;
      _hasStored = false;
    }
    _setBoundary(null);
  }

  Widget _mapView(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.primary;
    final b = _boundary;
    final center = b?.bbox.center ?? widget.near ?? defaultCenter;
    return Stack(children: [
      FlutterMap(
        mapController: _map,
        options: MapOptions(
          initialCenter: center,
          initialZoom: b == null ? (widget.near == null ? 6 : 13) : 10,
          onTap: (_, p) => _onTap(p),
          onMapReady: () {
            _ready = true;
            _fit();
          },
        ),
        children: [
          ...osmBaseLayers(context),
          if (b != null && _mode == _DrawMode.off)
            PolygonLayer(polygons: [
              for (final ring in b.rings)
                if (ring.length >= 3)
                  Polygon(
                    points: ring,
                    color: accent.withValues(alpha: 0.2),
                    borderColor: accent,
                    borderStrokeWidth: 2,
                  ),
            ]),
          if (_mode != _DrawMode.off && _draft.length >= 3)
            PolygonLayer(polygons: [
              Polygon(points: _draft, color: accent.withValues(alpha: 0.15), borderColor: accent, borderStrokeWidth: 2),
            ]),
          if (_mode != _DrawMode.off && _draft.length == 2)
            PolylineLayer(polylines: [Polyline(points: _draft, color: accent, strokeWidth: 2)]),
          if (_mode != _DrawMode.off)
            MarkerLayer(markers: [
              for (var i = 0; i < _draft.length; i++)
                Marker(
                  point: _draft[i],
                  width: 28,
                  height: 28,
                  child: GestureDetector(
                    onTap: _mode == _DrawMode.edit ? () => setState(() => _selected = _selected == i ? null : i) : null,
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _selected == i ? scheme.error : accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: Text('${i + 1}', style: TextStyle(color: scheme.onPrimary, fontSize: 11)),
                    ),
                  ),
                ),
            ]),
          _osmAttribution,
        ],
      ),
      if (_mode != _DrawMode.off)
        Positioned(
          top: 8,
          left: 8,
          right: 8,
          child: IgnorePointer(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _mode == _DrawMode.draw
                      ? 'Tap map to add points · ${_draft.length} placed'
                      : _selected == null
                          ? 'Tap a vertex to select it · ${_draft.length} pts'
                          : 'Tap the map to move vertex ${_selected! + 1}, or remove it',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _controls(BuildContext context) {
    final t = Theme.of(context);
    final b = _boundary;
    final edit = widget.canEdit;
    Widget num(String label, TextEditingController c) => Expanded(
          child: TextField(
            controller: c,
            enabled: edit,
            decoration: InputDecoration(labelText: label, isDense: true),
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          ),
        );
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(
        b == null
            ? 'No boundary set'
            : '${b.polygons?.length ?? 1} poly · ${b.pointCount} pts · ${b.source.toUpperCase()}',
        style: t.textTheme.titleSmall,
      ),
      if (b != null && widget.near != null)
        Text(
          boundaryContains(b, widget.near!) ? 'Assigned place is inside the boundary' : 'Assigned place is outside the boundary',
          style: t.textTheme.bodySmall,
        ),
      const SizedBox(height: 12),
      if (edit)
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (_mode == _DrawMode.off) ...[
            OutlinedButton.icon(onPressed: _startDraw, icon: const Icon(Icons.draw_outlined), label: const Text('Draw')),
            OutlinedButton.icon(
              onPressed: b == null ? null : _startEdit,
              icon: const Icon(Icons.open_with),
              label: const Text('Edit polygon'),
            ),
          ] else ...[
            OutlinedButton.icon(onPressed: _cancelDraw, icon: const Icon(Icons.close), label: const Text('Cancel')),
            if (_mode == _DrawMode.draw)
              OutlinedButton.icon(
                onPressed: _draft.isEmpty ? null : () => setState(() => _draft = _draft.sublist(0, _draft.length - 1)),
                icon: const Icon(Icons.undo),
                label: const Text('Undo'),
              ),
            if (_mode == _DrawMode.edit && _selected != null)
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  _draft = [..._draft]..removeAt(_selected!);
                  _selected = null;
                }),
                icon: const Icon(Icons.remove_circle_outline),
                label: const Text('Remove vertex'),
              ),
            FilledButton.icon(
              onPressed: _draft.length < 3 ? null : _finish,
              icon: const Icon(Icons.check),
              label: const Text('Finish'),
            ),
          ],
        ]),
      if (edit) ...[
        const Divider(height: 32),
        Text('Fetch boundary', style: t.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          ActionChip(
            avatar: _busy
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.public, size: 18),
            label: const Text('OSM'),
            onPressed: _busy || _mode != _DrawMode.off ? null : _fetchOsm,
          ),
          ActionChip(
            avatar: const Icon(Icons.crop_square, size: 18),
            label: const Text('BBOX'),
            onPressed: _busy || _mode != _DrawMode.off ? null : _applyBBox,
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [num('North', _n), const SizedBox(width: 8), num('South', _s)]),
        const SizedBox(height: 8),
        Row(children: [num('East', _e), const SizedBox(width: 8), num('West', _w)]),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: (b == null && !_hasStored) ? null : _clear,
              icon: const Icon(Icons.layers_clear),
              label: const Text('Clear'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              onPressed: b == null || _busy || _mode != _DrawMode.off ? null : _save,
              icon: const Icon(Icons.save),
              label: const Text('Save boundary'),
            ),
          ),
        ]),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title),
          Text(widget.query, style: Theme.of(context).textTheme.bodySmall, overflow: TextOverflow.ellipsis),
        ]),
      ),
      body: wide
          ? Row(children: [
              Expanded(child: _mapView(context)),
              SizedBox(width: 380, child: _controls(context)),
            ])
          : Column(children: [
              Expanded(flex: 3, child: _mapView(context)),
              Expanded(flex: 2, child: _controls(context)),
            ]),
    );
  }
}

/// Full-screen point picker (gate location): tap the map to move the pin.
class PointPickerPage extends StatefulWidget {
  const PointPickerPage({super.key, required this.initial, this.title = 'Pick location'});
  final LatLng initial;
  final String title;

  static Future<LatLng?> open(BuildContext context, LatLng initial, {String title = 'Pick location'}) =>
      Navigator.of(context).push<LatLng>(
        MaterialPageRoute(fullscreenDialog: true, builder: (_) => PointPickerPage(initial: initial, title: title)),
      );

  @override
  State<PointPickerPage> createState() => _PointPickerPageState();
}

class _PointPickerPageState extends State<PointPickerPage> {
  late LatLng _p = widget.initial;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title), actions: [
          TextButton(onPressed: () => Navigator.pop(context, _p), child: const Text('Use this point')),
        ]),
        body: Stack(children: [
          FlutterMap(
            options: MapOptions(initialCenter: _p, initialZoom: 17, onTap: (_, p) => setState(() => _p = p)),
            children: [
              ...osmBaseLayers(context),
              MarkerLayer(markers: [
                Marker(
                  point: _p,
                  width: 40,
                  height: 40,
                  alignment: Alignment.topCenter,
                  child: Icon(Icons.location_on, size: 40, color: Theme.of(context).colorScheme.error),
                ),
              ]),
              _osmAttribution,
            ],
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 24,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Tap the map to place the gate · ${_p.latitude.toStringAsFixed(6)}, ${_p.longitude.toStringAsFixed(6)}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ]),
      );
}
