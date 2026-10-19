import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/ride_bidding.dart' show BiddingRegion;
import '../push_area.dart';
import '../../widgets/common.dart' show SegmentLabel;
import '../../widgets/search_select.dart';

/// Picks where a broadcast goes: everywhere, a region from the admin's own
/// Regions (country -> state -> city -> suburb), or a radius around a point
/// picked on the map.
class PushAreaPicker extends StatelessWidget {
  const PushAreaPicker({
    super.key,
    required this.area,
    required this.regions,
    required this.onChanged,
    required this.pickPoint,
  });

  final PushArea area;
  final List<BiddingRegion> regions;
  final ValueChanged<PushArea> onChanged;

  /// Opens the map; the point chosen, or null.
  final Future<LatLng?> Function(LatLng? start) pickPoint;

  static const _radii = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final choices = pushRegionChoices(regions, area);
    Widget dropdown(
      String key,
      String label,
      String value,
      List<String> options,
      ValueChanged<String> pick, {
      bool optional = true,
    }) {
      return SearchableDropdownFormField<String>(
        key: ValueKey('push-area-$key'),
        initialValue: options.contains(value) ? value : '',
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          if (optional)
            DropdownMenuItem(
              value: '',
              child: Text('All of them', style: TextStyle(color: t.hintColor)),
            ),
          if (!optional) const DropdownMenuItem(value: '', child: Text('Choose…')),
          for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
        ],
        onChanged: options.isEmpty ? null : (v) => pick(v ?? ''),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Where', style: t.textTheme.labelLarge),
        const SizedBox(height: 6),
        // Full width, one line each: no "Every-where".
        SegmentedButton<PushAreaKind>(
          key: const ValueKey('push-area-kind'),
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: PushAreaKind.everywhere, label: SegmentLabel('Everywhere'), icon: Icon(Icons.public)),
            ButtonSegment(value: PushAreaKind.region, label: SegmentLabel('Region'), icon: Icon(Icons.map_outlined)),
            ButtonSegment(value: PushAreaKind.radius, label: SegmentLabel('Radius'), icon: Icon(Icons.radar)),
          ],
          selected: {area.kind},
          onSelectionChanged: (v) => onChanged(switch (v.first) {
            PushAreaKind.everywhere => const PushArea.everywhere(),
            PushAreaKind.region => PushArea.region(
              country: choices.countries.length == 1 ? choices.countries.first : '',
            ),
            PushAreaKind.radius => const PushArea.radius(),
          }),
        ),
        if (area.kind == PushAreaKind.region) ...[
          const SizedBox(height: 12),
          if (choices.countries.isEmpty)
            Text('Add countries in Admin > Regions to send by region.', style: t.textTheme.bodySmall)
          else ...[
            dropdown(
              'country',
              'Country',
              area.country,
              choices.countries,
              (v) => onChanged(PushArea.region(country: v)),
              optional: false,
            ),
            if (choices.states.isNotEmpty) ...[
              const SizedBox(height: 8),
              dropdown(
                'state',
                'State',
                area.state,
                choices.states,
                (v) => onChanged(PushArea.region(country: area.country, state: v)),
              ),
            ],
            if (choices.cities.isNotEmpty) ...[
              const SizedBox(height: 8),
              dropdown(
                'city',
                'City',
                area.city,
                choices.cities,
                (v) => onChanged(PushArea.region(country: area.country, state: area.state, city: v)),
              ),
            ],
            if (choices.suburbs.isNotEmpty) ...[
              const SizedBox(height: 8),
              dropdown('suburb', 'Suburb', area.suburb, choices.suburbs, (v) => onChanged(area.copyWith(suburb: v))),
            ],
          ],
        ],
        if (area.kind == PushAreaKind.radius) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  area.lat == null
                      ? 'No point picked yet'
                      : 'Centre ${area.lat!.toStringAsFixed(4)}, ${area.lng!.toStringAsFixed(4)}',
                  style: t.textTheme.bodyMedium,
                ),
              ),
              OutlinedButton.icon(
                key: const ValueKey('push-area-pick'),
                icon: const Icon(Icons.place_outlined),
                label: Text(area.lat == null ? 'Pick on map' : 'Move'),
                onPressed: () async {
                  final p = await pickPoint(area.lat == null ? null : LatLng(area.lat!, area.lng!));
                  if (p != null) onChanged(PushArea.radius(lat: p.latitude, lng: p.longitude, radiusKm: area.radiusKm));
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final km in _radii)
                ChoiceChip(
                  key: ValueKey('push-area-radius-${km.toInt()}'),
                  label: Text('${km.toInt()} km'),
                  selected: area.radiusKm == km,
                  onSelected: (_) => onChanged(area.copyWith(radiusKm: km)),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
