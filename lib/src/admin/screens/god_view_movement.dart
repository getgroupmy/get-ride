// God View → Movement: the panel under a person's details (last 24 hours or
// a chosen day, hour boxes, km, points, stops) and the trail drawn on the
// map. Data from GodViewRepository.trail (migration 0278).
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/god_view_trail.dart';
import '../../widgets/busy.dart';

/// What the panel is showing.
class GodViewMovementState {
  const GodViewMovementState({
    required this.personId,
    this.day,
    this.hours = const {},
    this.trail,
    this.loading = false,
    this.error,
  });

  final String personId;

  /// The calendar day (Malaysia), or null for the last 24 hours.
  final DateTime? day;

  /// Hours (0..23) to show; empty for all of them.
  final Set<int> hours;
  final GodViewTrail? trail;
  final bool loading;
  final Object? error;

  List<TrailPoint> get shown => trailInHours(trail?.points ?? const [], hours);

  GodViewMovementState copyWith({
    DateTime? Function()? day,
    Set<int>? hours,
    GodViewTrail? Function()? trail,
    bool? loading,
    Object? Function()? error,
  }) =>
      GodViewMovementState(
        personId: personId,
        day: day == null ? this.day : day(),
        hours: hours ?? this.hours,
        trail: trail == null ? this.trail : trail(),
        loading: loading ?? this.loading,
        error: error == null ? this.error : error(),
      );
}

/// The trail's colours: lighter earlier, darker later.
({Color early, Color late, Color stop}) trailColors(Brightness b) => b == Brightness.dark
    ? (early: const Color(0xFF2B5F80), late: const Color(0xFF4CC0FF), stop: const Color(0xFFF2B25C))
    : (early: const Color(0xFF9CC9E6), late: const Color(0xFF0C7AB8), stop: const Color(0xFFA86400));

/// The map layers for [points]: the line (dashed over quiet gaps), the
/// stops, the start and the latest point.
List<Widget> godViewTrailLayers(List<TrailPoint> points, Brightness b, Color ring) {
  if (points.isEmpty) return const [];
  final c = trailColors(b);
  final segments = trailSegments(points);
  final stops = trailStops(points);
  final first = points.first.at;
  final span = points.last.at.difference(first).inSeconds.clamp(1, 1 << 31);
  Color at(DateTime t) => Color.lerp(c.early, c.late, t.difference(first).inSeconds / span)!;
  return [
    PolylineLayer(key: const ValueKey('god-view-trail'), polylines: [
      for (final s in segments)
        Polyline(
          points: [for (final p in s.points) LatLng(p.lat, p.lng)],
          color: at(s.points.last.at).withValues(alpha: s.gap ? 0.6 : 0.95),
          strokeWidth: s.gap ? 3 : 4,
          pattern: s.gap ? StrokePattern.dashed(segments: const [6, 8]) : const StrokePattern.solid(),
        ),
    ]),
    MarkerLayer(markers: [
      for (final s in stops)
        Marker(
          point: LatLng(s.at.lat, s.at.lng),
          width: 16,
          height: 16,
          child: Tooltip(
            message: 'Stopped ${trailClock(s.at.at)}, ${trailDuration(s.until.difference(s.at.at))}',
            child: Container(
              decoration: BoxDecoration(color: c.stop, shape: BoxShape.circle, border: Border.all(color: ring, width: 2)),
            ),
          ),
        ),
      Marker(
        key: const ValueKey('god-view-trail-start'),
        point: LatLng(points.first.lat, points.first.lng),
        width: 14,
        height: 14,
        child: Container(decoration: BoxDecoration(color: c.early, shape: BoxShape.circle, border: Border.all(color: ring, width: 2))),
      ),
      Marker(
        key: const ValueKey('god-view-trail-end'),
        point: LatLng(points.last.lat, points.last.lng),
        width: 18,
        height: 18,
        child: Container(decoration: BoxDecoration(color: c.late, shape: BoxShape.circle, border: Border.all(color: ring, width: 3))),
      ),
    ]),
  ];
}

/// The Movement section of the details panel.
class GodViewMovementPanel extends StatelessWidget {
  const GodViewMovementPanel({
    super.key,
    required this.state,
    required this.onLast24,
    required this.onPickDay,
    required this.onHours,
    required this.onRetry,
  });

  final GodViewMovementState state;
  final VoidCallback onLast24;
  final VoidCallback onPickDay;
  final ValueChanged<Set<int>> onHours;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 12);
    final trail = state.trail;
    final shown = state.shown;
    final has = trailHoursWithData(trail?.points ?? const []);
    final stops = trailStops(shown);
    final d = state.day;
    return Column(key: const ValueKey('god-view-movement'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        ChoiceChip(
          key: const ValueKey('god-view-trail-24h'),
          label: const Text('Last 24 h'),
          selected: d == null,
          onSelected: (_) => onLast24(),
        ),
        ChoiceChip(
          key: const ValueKey('god-view-trail-day'),
          avatar: const Icon(Icons.calendar_month_outlined, size: 16),
          label: Text(d == null ? 'Pick a day' : '${d.day}/${d.month}/${d.year}'),
          selected: d != null,
          onSelected: (_) => onPickDay(),
        ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: Text('Hours (tap to choose, tap again to clear)', style: muted)),
        if (state.hours.isNotEmpty)
          TextButton(
            key: const ValueKey('god-view-trail-all-hours'),
            onPressed: () => onHours(const {}),
            child: const Text('All hours'),
          ),
      ]),
      GridView.count(
        crossAxisCount: 12,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 3,
        crossAxisSpacing: 3,
        childAspectRatio: 1.25,
        children: [
          for (var h = 0; h < 24; h++)
            _HourBox(
              hour: h,
              selected: state.hours.contains(h),
              hasData: has.contains(h),
              onTap: () => onHours(state.hours.contains(h) ? ({...state.hours}..remove(h)) : {...state.hours, h}),
            ),
        ],
      ),
      const SizedBox(height: 10),
      if (state.loading)
        const LinearProgressIndicator()
      else if (state.error != null)
        Row(children: [
          Expanded(child: Text('Movement not loaded: ${state.error}', style: TextStyle(color: t.colorScheme.error))),
          BusyButton.text(onPressed: onRetry, child: const Text('Retry')),
        ])
      else if (trail != null) ...[
        Row(children: [
          _Stat(key: const ValueKey('god-view-trail-km'), value: trailKm(shown).toStringAsFixed(1), label: 'km moved'),
          const SizedBox(width: 6),
          _Stat(key: const ValueKey('god-view-trail-points'), value: '${shown.length}', label: 'location points'),
          const SizedBox(width: 6),
          _Stat(key: const ValueKey('god-view-trail-stops'), value: '${stops.length}', label: 'stops (5 min+)'),
        ]),
        if (trail.thinned) ...[
          const SizedBox(height: 4),
          Text('${trail.total} points on the server; every few are drawn.', style: muted),
        ],
        const SizedBox(height: 8),
        if (shown.isEmpty)
          Text(
            trail.points.isEmpty ? 'No movement recorded in this time.' : 'No movement in the chosen hours.',
            key: const ValueKey('god-view-trail-empty'),
          )
        else ...[
          Text('Stops', style: t.textTheme.labelLarge),
          const SizedBox(height: 4),
          if (stops.isEmpty) Text('No stops of 5 minutes or more.', style: muted),
          for (final s in stops)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                SizedBox(width: 92, child: Text('${trailClock(s.at.at)}–${trailClock(s.until)}')),
                Expanded(
                  child: Text('${s.at.lat.toStringAsFixed(5)}, ${s.at.lng.toStringAsFixed(5)}', style: muted),
                ),
                Text(trailDuration(s.until.difference(s.at.at))),
              ]),
            ),
        ],
        const SizedBox(height: 6),
        Text(
          'Points come from the phone: every few seconds while the app is open, about every minute or 200 m '
          'in the background. A dashed line means the phone sent nothing for 20 minutes or more.',
          style: muted,
        ),
      ],
    ]);
  }
}

class _HourBox extends StatelessWidget {
  const _HourBox({required this.hour, required this.selected, required this.hasData, required this.onTap});
  final int hour;
  final bool selected;
  final bool hasData;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final fg = selected ? t.colorScheme.onPrimary : t.colorScheme.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      label: '${hour.toString().padLeft(2, '0')}:00${hasData ? '' : ', no points'}',
      child: Material(
        key: ValueKey('god-view-trail-hour-$hour'),
        color: selected ? t.colorScheme.primary : t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Center(
            child: Text(
              hour.toString().padLeft(2, '0'),
              style: TextStyle(
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: hasData || selected ? fg : fg.withValues(alpha: 0.4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({super.key, required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          Text(label, style: TextStyle(fontSize: 11, color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
