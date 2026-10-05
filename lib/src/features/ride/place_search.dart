import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../data/app_display_repository.dart';
import '../../data/geo_service.dart';
import '../../providers.dart';

/// Result of the place picker: either a concrete place or a request to drop
/// a pin on the map.
class PlacePick {
  const PlacePick.place(Place this.place) : pickOnMap = false;
  const PlacePick.onMap()
      : place = null,
        pickOnMap = true;
  final Place? place;
  final bool pickOnMap;
}

Future<PlacePick?> showPlaceSearch(
  BuildContext context, {
  required String title,
  LatLng? near,
  Place? current,
}) {
  final wide = MediaQuery.sizeOf(context).width >= 720;
  final body = _PlaceSearch(title: title, near: near, current: current);
  if (wide) {
    return showDialog<PlacePick>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640), child: body),
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
  const _PlaceSearch({required this.title, this.near, this.current});
  final String title;
  final LatLng? near;
  final Place? current;

  @override
  ConsumerState<_PlaceSearch> createState() => _PlaceSearchState();
}

class _PlaceSearchState extends ConsumerState<_PlaceSearch> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<Place> _results = [];
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    // Typing hides the recent destinations; clearing shows them again.
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

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(children: [
          Expanded(child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge)),
          IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          controller: _query,
          autofocus: true,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search a place or address',
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : null,
          ),
          onChanged: _onChanged,
        ),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: ListView(children: [
          if (widget.current != null)
            ListTile(
              leading: const Icon(Icons.my_location),
              title: const Text('Current location'),
              subtitle: Text(widget.current!.address, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(context, PlacePick.place(widget.current!)),
            ),
          ListTile(
            leading: const Icon(Icons.push_pin_outlined),
            title: const Text('Choose on map'),
            onTap: () => Navigator.pop(context, const PlacePick.onMap()),
          ),
          const Divider(),
          if (_query.text.trim().isEmpty)
            ...switch (ref.watch(recentPlacesProvider).value ?? const <Place>[]) {
              final List<Place> recent when recent.isNotEmpty => [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text('Recent', style: Theme.of(context).textTheme.titleSmall),
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
          for (final p in _results)
            ListTile(
              leading: const Icon(Icons.place_outlined),
              title: Text(p.name),
              subtitle: Text(p.address, maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(context, PlacePick.place(p)),
            ),
        ]),
      ),
    ]);
  }
}
