import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/airport_areas.dart';
import '../../core/place_gates.dart';
import '../../data/app_display_repository.dart';
import '../../data/geo_service.dart';
import '../../data/place_gates_repository.dart';
import '../../core/saved_places.dart';
import '../../data/saved_places_repository.dart';
import '../../providers.dart';
import 'map_place_picker.dart';
import 'saved_place_form.dart';

/// Result of the place picker: either a concrete place or a request to drop
/// a pin on the map.
class PlacePick {
  const PlacePick.place(Place this.place, {this.entrance = ''}) : pickOnMap = false;
  const PlacePick.onMap() : place = null, entrance = '', pickOnMap = true;
  final Place? place;
  final bool pickOnMap;

  /// A saved place's entrance ("Gate B"); empty for none.
  final String entrance;
}

/// What the sheet is for: a trip's end (inDrive's "Enter your route", with
/// Suggested and Saved), or just an address (saving a place).
enum PlaceSearchMode { route, address }

Future<PlacePick?> showPlaceSearch(
  BuildContext context, {
  required String title,
  LatLng? near,
  Place? current,
  GateUsage? usage,
  Place? from,
  PlaceSearchMode mode = PlaceSearchMode.route,
}) {
  final wide = MediaQuery.sizeOf(context).width >= 720;
  final body = _PlaceSearch(title: title, near: near, current: current, usage: usage, from: from, mode: mode);
  if (wide) {
    return showDialog<PlacePick>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680), child: body),
      ),
    );
  }
  return showModalBottomSheet<PlacePick>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(heightFactor: 0.92, child: body),
  );
}

class _PlaceSearch extends ConsumerStatefulWidget {
  const _PlaceSearch({
    required this.title,
    this.near,
    this.current,
    this.usage,
    this.from,
    this.mode = PlaceSearchMode.route,
  });
  final String title;
  final LatLng? near;
  final Place? current;

  /// Whether this is a pickup or a drop-off, so only gates open for it show.
  final GateUsage? usage;

  /// Where the trip starts, shown above the field ("From").
  final Place? from;
  final PlaceSearchMode mode;

  @override
  ConsumerState<_PlaceSearch> createState() => _PlaceSearchState();
}

class _PlaceSearchState extends ConsumerState<_PlaceSearch> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<Place> _results = [];
  bool _loading = false;

  /// Suggested (current place, the map, recent) or Saved.
  bool _saved = false;

  bool get _route => widget.mode == PlaceSearchMode.route;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    // Typing hides the lists under the field; clearing shows them again.
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      setState(() => _loading = true);
      try {
        final r = await ref.read(geoServiceProvider).search(q, near: widget.near);
        if (mounted) setState(() => _results = r);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  /// The map picker (inDrive's): the place chosen there, handed straight back.
  Future<void> _onMap() async {
    final p = await pickPlaceOnMap(context, start: widget.current?.point ?? widget.near, me: widget.near);
    if (p != null && mounted) Navigator.pop(context, PlacePick.place(p));
  }

  Future<void> _add(SavedPlaceKind kind) => addSavedPlace(context, kind, near: widget.near);

  /// A search result, with the admin's gates under it when it is a
  /// multi-gate place (Expo `PlaceGatesList`). Where the place requires a
  /// gate, the place itself can't be picked — only one of its gates.
  Widget _result(Place p, GateCatalogue? catalogue) {
    final gated = catalogue == null
        ? null
        : matchGatedPlace(
            places: catalogue.places,
            gates: catalogue.gates,
            point: p.point,
            name: p.name,
            usage: widget.usage,
          );
    final gates = gated?.gates ?? const <GateOption>[];
    final blocked = gated?.blocksPlace ?? false;
    return ListTile(
      key: ValueKey('result-${p.point.latitude},${p.point.longitude}'),
      leading: Icon(gates.isEmpty ? Icons.place_outlined : Icons.door_front_door_outlined),
      title: Text(p.name),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(p.address, maxLines: 2, overflow: TextOverflow.ellipsis),
        if (gates.isNotEmpty) ...[
          if (blocked)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Choose a gate', style: Theme.of(context).textTheme.labelMedium),
            ),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final g in gates)
              ActionChip(
                key: ValueKey('gate-${g.id}'),
                avatar: const Icon(Icons.door_front_door_outlined, size: 16),
                label: Text(g.name),
                onPressed: () => Navigator.pop(context, PlacePick.place(gatePlace(p, gated!, g))),
              ),
          ]),
        ],
      ]),
      onTap: blocked ? null : () => Navigator.pop(context, PlacePick.place(p)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final catalogue = ref.watch(placeGatesProvider).value;
    final typing = _query.text.trim().isNotEmpty;
    final field = t.colorScheme.surfaceContainerHighest;
    return Column(
      children: [
        // The title in the middle, a round close on the right (inDrive's).
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 16, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                key: const ValueKey('place-search-close'),
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        if (_route && widget.from != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Container(
              key: const ValueKey('place-search-from'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(color: field, borderRadius: BorderRadius.circular(14)),
              child: Row(
                children: [
                  const Icon(Icons.emoji_people, size: 26),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('From', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                        Text(
                          widget.from!.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.bodyLarge,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            key: const ValueKey('place-search-field'),
            controller: _query,
            autofocus: true,
            decoration: InputDecoration(
              filled: true,
              fillColor: field,
              prefixIcon: _route ? const Icon(Icons.search) : null,
              labelText: _route ? 'To' : 'Address',
              hintText: 'Search a place or address',
              floatingLabelBehavior: FloatingLabelBehavior.always,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: t.colorScheme.onSurface, width: 2),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: t.colorScheme.onSurface, width: 2),
              ),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  // The map: choose the spot there instead (inDrive's map button).
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Tooltip(
                      message: 'Choose on map',
                      child: Material(
                        color: t.colorScheme.surface,
                        borderRadius: BorderRadius.circular(10),
                        elevation: 1,
                        child: InkWell(
                          key: const ValueKey('place-search-map'),
                          borderRadius: BorderRadius.circular(10),
                          onTap: _onMap,
                          child: const SizedBox.square(
                            dimension: 40,
                            child: Icon(Icons.location_on, color: Color(0xFF2D7FF9), size: 26),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            onChanged: _onChanged,
          ),
        ),
        const SizedBox(height: 12),
        if (_route && !typing)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                _Pill(
                  key: const ValueKey('place-tab-suggested'),
                  label: 'Suggested',
                  on: !_saved,
                  onTap: () => setState(() => _saved = false),
                ),
                const SizedBox(width: 10),
                _Pill(
                  key: const ValueKey('place-tab-saved'),
                  label: 'Saved',
                  on: _saved,
                  onTap: () => setState(() => _saved = true),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            children: [
              if (!typing && _route && _saved) ..._savedList(t),
              if (!typing && _route && !_saved) ..._suggested(t),
              if (typing)
                for (final p in collapseAirports<Place>(
                  _results,
                  ref.watch(airportAreasProvider).value ?? const [],
                  point: (p) => p.point,
                  text: (p) => '${p.name} ${p.address}',
                  airport: (a) => Place(
                    name: a.name,
                    address: a.code.isEmpty ? 'Airport' : '${a.code} · Airport',
                    point: a.centroid,
                  ),
                ))
                  _result(p, catalogue),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _suggested(ThemeData t) => [
    if (widget.current != null)
      ListTile(
        leading: const Icon(Icons.my_location),
        title: const Text('Current location'),
        subtitle: Text(widget.current!.address, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => Navigator.pop(context, PlacePick.place(widget.current!)),
      ),
    // Choosing on the map is the pin button in the search field.
    ...switch (ref.watch(recentPlacesProvider).value ?? const <Place>[]) {
      final List<Place> recent when recent.isNotEmpty => [
        if (widget.current != null) const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text('Recent', style: t.textTheme.titleSmall),
        ),
        for (final p in recent)
          ListTile(
            key: ValueKey('recent-${p.point.latitude},${p.point.longitude}'),
            leading: const Icon(Icons.history),
            title: Text(p.name),
            subtitle: Text(p.address, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.pop(context, PlacePick.place(p)),
          ),
      ],
      _ => const <Widget>[],
    },
  ];

  /// Home (or Add Home), Work (or Add Work), the other places and Another
  /// place, as inDrive's Saved tab.
  List<Widget> _savedList(ThemeData t) {
    if (ref.watch(currentUserIdProvider) == null) {
      return const [ListTile(leading: Icon(Icons.bookmark_border), title: Text('Sign in to save your places'))];
    }
    final v = arrangeSavedPlaces(ref.watch(savedPlacesProvider).value ?? const []);
    Widget saved(SavedPlace p, IconData icon) => ListTile(
      key: ValueKey('saved-${p.kind.name}-${p.id}'),
      leading: Icon(icon, size: 28),
      title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [p.address, if (p.entrance.isNotEmpty) p.entrance].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(savedPlaceDistance(widget.near, p.point), style: t.textTheme.bodyLarge),
          const SizedBox(width: 10),
          IconButton.filledTonal(
            key: ValueKey('saved-edit-${p.id}'),
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => showSavedPlaceForm(context, p, near: widget.near),
          ),
        ],
      ),
      onTap: () => Navigator.pop(context, PlacePick.place(savedPlaceAsPlace(p), entrance: p.entrance)),
    );
    Widget add(String label, IconData icon, SavedPlaceKind kind, Key key) => ListTile(
      key: key,
      leading: Icon(icon, size: 28),
      title: Text(label),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _add(kind),
    );
    return [
      v.home != null
          ? saved(v.home!, Icons.home_outlined)
          : add('Add Home', Icons.home_outlined, SavedPlaceKind.home, const ValueKey('saved-add-home')),
      v.work != null
          ? saved(v.work!, Icons.work_outline)
          : add('Add Work', Icons.work_outline, SavedPlaceKind.work, const ValueKey('saved-add-work')),
      add('Another place', Icons.add, SavedPlaceKind.other, const ValueKey('saved-add-other')),
      for (final p in v.others) saved(p, Icons.bookmark_border),
    ];
  }
}

/// A Suggested / Saved switch: black when on, grey when off (inDrive's).
class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: on ? t.colorScheme.onSurface : t.colorScheme.surfaceContainerHighest,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Text(
            label,
            style: t.textTheme.titleMedium?.copyWith(color: on ? t.colorScheme.surface : t.colorScheme.onSurface),
          ),
        ),
      ),
    );
  }
}
