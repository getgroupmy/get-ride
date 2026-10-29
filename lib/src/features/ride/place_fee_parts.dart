// Place fees (migration 0324) as the rider sees them before booking: one
// line per fee ("KLIA kerbside fee (pickup)  RM 5.00", its note in the fare
// details), the label on the map pin, the place's outline on the map (0325),
// and Freight's and Courier's lines and total from the server's quote.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/airport_areas.dart' show AirportArea, ringContains;
import '../../core/gate_snap.dart' show ringsAround;
import '../../core/place_fees.dart';
import '../../data/place_fees_repository.dart';

/// One fee line as shown: its label, the amount formatted, and its note.
typedef PlaceFeeRow = ({String label, String amount, String? note});

List<PlaceFeeRow> placeFeeRows(Iterable<PlaceFeeLine> lines, String Function(double) money) => [
  for (final l in lines) (label: l.label, amount: money(l.amount), note: l.note),
];

/// The fee lines, each "name (end): amount"; with [notes], the admin's note
/// for riders under each.
class PlaceFeeLinesView extends StatelessWidget {
  const PlaceFeeLinesView({super.key, required this.rows, this.notes = false, this.style, this.center = true});

  final List<PlaceFeeRow> rows;
  final bool notes;

  /// Centred (under the fare), else from the start (the fare details).
  final bool center;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final base = style ?? t.textTheme.bodySmall?.copyWith(color: muted);
    return Column(
      key: const ValueKey('place-fee-lines'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        for (final (i, r) in rows.indexed) ...[
          Text(
            '+ ${r.label}: ${r.amount}',
            key: ValueKey('place-fee-line-$i'),
            style: base,
            textAlign: center ? TextAlign.center : TextAlign.start,
          ),
          if (notes && r.note != null)
            Text(
              r.note!,
              key: ValueKey('place-fee-note-$i'),
              style: base?.copyWith(fontStyle: FontStyle.italic, fontSize: (base.fontSize ?? 12) - 1),
              textAlign: center ? TextAlign.center : TextAlign.start,
            ),
        ],
      ],
    );
  }
}

/// The place and its fee over a pin on the map ("KLIA · RM 5.00").
class PlaceFeeMapLabel extends StatelessWidget {
  const PlaceFeeMapLabel({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      key: key ?? const ValueKey('place-fee-map-label'),
      color: t.colorScheme.secondaryContainer,
      elevation: 2,
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.payments_outlined, size: 14, color: t.colorScheme.onSecondaryContainer),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.textTheme.labelMedium?.copyWith(
                  color: t.colorScheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Freight's and Courier's place fees before booking: the server's lines
/// for the trip and what the rider pays with them ([baseTotal] + the
/// fees). Nothing while there are none.
class PlaceFeesSummary extends ConsumerWidget {
  const PlaceFeesSummary({super.key, required this.args, required this.money, required this.baseTotal});

  final PlaceFeesQuoteArgs args;
  final String Function(double) money;

  /// What the rider pays without the place fees.
  final double baseTotal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(placeFeesQuoteProvider(args)).value ?? PlaceFeesQuote.none;
    if (q.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Container(
      key: const ValueKey('place-fees-summary'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, l) in q.lines.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      l.label,
                      key: ValueKey('place-fee-line-$i'),
                      style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(money(l.amount), style: t.textTheme.bodyMedium),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Total with place fees',
                  style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                money(baseTotal + q.total),
                key: const ValueKey('place-fees-total'),
                style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The outlines to draw for a trip's place fees (0325): for each place with
/// a fee in [quote], the piece of its boundary ([areas], the rider's own
/// copy of airport_areas) the pickup, the drop-off or a counted stop is in.
/// None when the admin turned the outline off. At most [max] rings, each
/// once; a stop outside every piece of a place adds nothing.
List<List<LatLng>> placeFeeOutlineRings(
  PlaceFeesQuote quote,
  Iterable<AirportArea> areas, {
  LatLng? pickup,
  LatLng? drop,
  List<LatLng> stops = const [],
  int max = 4,
}) {
  if (quote.isEmpty || !quote.display.showOutline) return const [];
  final byId = {for (final a in areas) a.id: a};
  // Each place with the trip's point(s) it is charged for.
  final spots = <(String, LatLng, bool)>[];
  void add(String? area, LatLng? at, {bool stop = false}) {
    if (area == null || area.isEmpty || at == null) return;
    if (spots.any((x) => x.$1 == area && x.$2 == at)) return;
    spots.add((area, at, stop));
  }

  for (final l in quote.lines) {
    switch (l.end) {
      case 'pick':
        add(l.areaId, pickup);
      case 'drop':
        add(l.areaId, drop);
      case 'stop':
        for (final s in stops) {
          add(l.areaId, s, stop: true);
        }
      default:
        // Either end, charged once: the end that is in it.
        if (quote.pickup?.areaId == l.areaId) {
          add(l.areaId, pickup);
        } else if (quote.drop?.areaId == l.areaId) {
          add(l.areaId, drop);
        } else {
          for (final s in stops) {
            add(l.areaId, s, stop: true);
          }
        }
    }
  }
  final out = <List<LatLng>>[];
  for (final (id, at, stop) in spots) {
    final area = byId[id];
    if (area == null) continue;
    if (stop && !area.rings.any((r) => ringContains(r, at))) continue;
    for (final r in ringsAround(area.rings, at)) {
      if (out.length >= max) return out;
      if (!out.any((o) => identical(o, r))) out.add(r);
    }
  }
  return out;
}

/// The places' outlines: lightly filled, in the theme's accent, under the
/// pins. Nothing for no rings.
List<Widget> placeFeeOutlineLayers(BuildContext context, List<List<LatLng>> rings) {
  if (rings.isEmpty) return const [];
  final scheme = Theme.of(context).colorScheme;
  return [
    PolygonLayer(
      key: const ValueKey('place-fee-outline'),
      polygons: [
        for (final r in rings)
          Polygon(
            points: r,
            color: scheme.primary.withValues(alpha: 0.10),
            borderColor: scheme.primary.withValues(alpha: 0.75),
            borderStrokeWidth: 1.5,
          ),
      ],
    ),
  ];
}
