// God View → Movement: the panel under a person's details (last 24 hours or
// a chosen day, hour boxes, km, points, stops) and the trail drawn on the
// map. Data from GodViewRepository.trail (migration 0278).
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/god_view_trail.dart';
import '../../core/page_styles.dart' show godViewSurface, trailLineStyles;
import '../../widgets/page_style_host.dart' show SurfaceStyle;
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

/// How the trail is drawn: App Page Settings → God View → Movement trail.
class TrailLook {
  const TrailLook({
    required this.early,
    required this.late,
    required this.stop,
    this.fade = true,
    this.width = 4,
    this.style = 0,
    this.followRoads = false,
  });

  /// The colours in light or dark mode, nothing else changed.
  factory TrailLook.defaults(Brightness b) => b == Brightness.dark
      ? const TrailLook(early: Color(0xFF2B5F80), late: Color(0xFF4CC0FF), stop: Color(0xFFF2B25C))
      : const TrailLook(early: Color(0xFF9CC9E6), late: Color(0xFF0C7AB8), stop: Color(0xFFA86400));

  factory TrailLook.of(BuildContext context) {
    final b = Theme.of(context).brightness;
    final d = TrailLook.defaults(b);
    final s = SurfaceStyle.of(context, godViewSurface);
    return TrailLook(
      early: s.color('trailEarly', b) ?? d.early,
      late: s.color('trailLate', b) ?? d.late,
      stop: s.color('trailStop', b) ?? d.stop,
      fade: s.toggle('trailFade'),
      width: s.number('trailWidth'),
      style: s.number('trailStyle').round().clamp(0, trailLineStyles.length - 1),
      followRoads: s.number('trailPath').round() == 1,
    );
  }

  final Color early, late, stop;

  /// Lighter for earlier points; off draws the whole line in [late].
  final bool fade;
  final double width;

  /// An index of [trailLineStyles]: solid, dashed or dotted.
  final int style;

  /// Draw the road between points (a router's route) instead of a straight line.
  final bool followRoads;

  StrokePattern get pattern => switch (style) {
        1 => StrokePattern.dashed(segments: [width * 3, width * 2]),
        2 => StrokePattern.dotted(spacingFactor: 2),
        _ => const StrokePattern.solid(),
      };
}

/// The map layers for [points]: the line (dashed over quiet gaps), the
/// stops, the start and the latest point. [roads] holds, by solid run
/// (in [trailSegments] order, gaps left out), the road to draw instead of
/// straight lines; a run without one is drawn straight.
List<Widget> godViewTrailLayers(
  List<TrailPoint> points,
  TrailLook look,
  Color ring, {
  List<List<LatLng>?> roads = const [],
}) {
  if (points.isEmpty) return const [];
  final segments = trailSegments(points);
  final stops = trailStops(points);
  final first = points.first.at;
  final span = points.last.at.difference(first).inSeconds.clamp(1, 1 << 31);
  Color at(DateTime t) => look.fade ? Color.lerp(look.early, look.late, t.difference(first).inSeconds / span)! : look.late;
  final lines = <Polyline>[];
  var run = 0;
  for (final s in segments) {
    final straight = [for (final p in s.points) LatLng(p.lat, p.lng)];
    if (s.gap) {
      lines.add(Polyline(
        points: straight,
        color: at(s.points.last.at).withValues(alpha: 0.6),
        strokeWidth: (look.width * 0.75).clamp(1, 12),
        pattern: StrokePattern.dashed(segments: const [6, 8]),
      ));
      continue;
    }
    final road = run < roads.length ? roads[run] : null;
    run++;
    lines.add(Polyline(
      points: road ?? straight,
      color: at(s.points.last.at).withValues(alpha: 0.95),
      strokeWidth: look.width,
      pattern: look.pattern,
    ));
  }
  return [
    PolylineLayer(key: const ValueKey('god-view-trail'), polylines: lines),
    MarkerLayer(markers: [
      for (final s in stops)
        Marker(
          point: LatLng(s.at.lat, s.at.lng),
          width: 16,
          height: 16,
          child: Tooltip(
            message: 'Stopped ${trailClock(s.at.at)}, ${trailDuration(s.until.difference(s.at.at))}',
            child: Container(
              decoration: BoxDecoration(color: look.stop, shape: BoxShape.circle, border: Border.all(color: ring, width: 2)),
            ),
          ),
        ),
      Marker(
        key: const ValueKey('god-view-trail-start'),
        point: LatLng(points.first.lat, points.first.lng),
        width: 14,
        height: 14,
        child: Container(
            decoration: BoxDecoration(color: look.fade ? look.early : look.late, shape: BoxShape.circle, border: Border.all(color: ring, width: 2))),
      ),
      Marker(
        key: const ValueKey('god-view-trail-end'),
        point: LatLng(points.last.lat, points.last.lng),
        width: 18,
        height: 18,
        child: Container(decoration: BoxDecoration(color: look.late, shape: BoxShape.circle, border: Border.all(color: ring, width: 3))),
      ),
    ]),
  ];
}

/// Points closer than this to the last one kept are dropped before asking a
/// router for the road between them.
const trailRoadStep = 150.0;

/// Points per router call (the start, up to 23 stops, the end).
const trailRoadChunk = 25;

/// Router calls for one trail at most; runs past it are drawn straight.
const trailRoadCalls = 12;

/// The road for each solid run of [points] ([trailSegments] order, gaps left
/// out): the run thinned to one point every [trailRoadStep] m, sent to
/// [route] [trailRoadChunk] points at a time. Null for a run that needed
/// more calls than were left, or whose route failed.
Future<List<List<LatLng>?>> trailRoads(
  List<TrailPoint> points,
  Future<List<LatLng>?> Function(List<LatLng> points) route,
) async {
  var calls = 0;
  final out = <List<LatLng>?>[];
  for (final s in trailSegments(points)) {
    if (s.gap) continue;
    final kept = <TrailPoint>[];
    for (final p in s.points) {
      if (kept.isEmpty || trailMetres(kept.last, p) >= trailRoadStep) kept.add(p);
    }
    if (kept.last != s.points.last) kept.add(s.points.last);
    if (kept.length < 2) {
      out.add(null);
      continue;
    }
    final need = ((kept.length - 1) / (trailRoadChunk - 1)).ceil();
    if (calls + need > trailRoadCalls) {
      out.add(null);
      continue;
    }
    final road = <LatLng>[];
    var ok = true;
    for (var i = 0; i < kept.length - 1; i += trailRoadChunk - 1) {
      final chunk = kept.sublist(i, (i + trailRoadChunk).clamp(0, kept.length));
      calls++;
      final r = await route([for (final p in chunk) LatLng(p.lat, p.lng)]);
      if (r == null || r.length < 2) {
        ok = false;
        break;
      }
      road.addAll(road.isEmpty ? r : r.skip(1));
    }
    out.add(ok ? road : null);
  }
  return out;
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
