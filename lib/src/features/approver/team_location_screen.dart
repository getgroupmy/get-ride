// Team Location (migration 0406): an approver's God View of the team they
// cover. A live map of where their people are, from approver_team_snapshot —
// the same rows and models God View uses, but scoped server-side to exactly
// the approver's team. Admin-only God View actions (suspend, reveal phone,
// push, open admin profile) are not here; per-person locate actions (ping,
// Live now, trail) land in a later slice.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../admin/screens/god_view_screen.dart' show godViewStatusColor;
import '../../core/god_view.dart';
import '../../data/approver_inbox_repository.dart';
import '../../widgets/map_tiles.dart';
import '../../widgets/page_style_host.dart';

/// Kuala Lumpur — a fallback centre before the first fix lands.
const _fallbackCentre = LatLng(3.139, 101.687);

class TeamLocationScreen extends ConsumerStatefulWidget {
  const TeamLocationScreen({super.key});

  @override
  ConsumerState<TeamLocationScreen> createState() => _TeamLocationScreenState();
}

class _TeamLocationScreenState extends ConsumerState<TeamLocationScreen> {
  final _map = MapController();
  Timer? _poll;
  GodViewSnapshot? _snap;
  Object? _error;
  bool _fitted = false;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_load()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final snap = await ref.read(approverInboxRepositoryProvider).teamLocation();
      if (!mounted) return;
      setState(() {
        _snap = snap;
        _error = null;
      });
      if (!_fitted && snap.people.isNotEmpty) {
        _fitted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _fit() {
    final people = _snap?.people ?? const <GodViewPerson>[];
    if (!mounted || !_mapReady || people.isEmpty) return;
    final pts = [for (final p in people) LatLng(p.lat, p.lng)];
    try {
      if (pts.length == 1) {
        _map.move(pts.first, 14);
      } else {
        _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(56)));
      }
    } catch (_) {}
  }

  void _openPerson(GodViewPerson p) {
    unawaited(showAppSheet<void>(
      id: 'approver.team-location-person',
      context: context,
      builder: (_) => _PersonSheet(person: p),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final b = t.brightness;
    final cs = t.colorScheme;
    final snap = _snap;
    final people = snap?.people ?? const <GodViewPerson>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Team Location'),
        actions: [
          IconButton(
            key: const ValueKey('team-location-fit'),
            tooltip: 'Fit the team',
            icon: const Icon(Icons.fit_screen_outlined),
            onPressed: people.isEmpty ? null : _fit,
          ),
          IconButton(
            key: const ValueKey('team-location-refresh'),
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => unawaited(_load()),
          ),
        ],
      ),
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: people.isNotEmpty ? LatLng(people.first.lat, people.first.lng) : _fallbackCentre,
            initialZoom: 11,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              keyboardOptions: mapKeyboardOptions,
            ),
            onMapReady: () {
              _mapReady = true;
              _fit();
            },
          ),
          children: [
            baseTileLayer(context),
            MarkerLayer(markers: [
              for (final p in people)
                Marker(
                  key: ValueKey('team-location-marker-${p.id}'),
                  point: LatLng(p.lat, p.lng),
                  width: 40,
                  height: 40,
                  child: _Dot(person: p, color: godViewStatusColor(p.status, b), ring: cs.surface, onTap: () => _openPerson(p)),
                ),
            ]),
          ],
        ),
        if (snap != null)
          Positioned(
            top: 8 + MediaQuery.viewPaddingOf(context).top,
            left: 0,
            right: 0,
            child: _StatsStrip(snap: snap),
          ),
        if (snap == null && _error == null)
          const Center(child: CircularProgressIndicator()),
        if (_error != null && snap == null)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _error.toString().contains('42501')
                    ? "You don't have Team Location."
                    : "Couldn't load the team's location. Pull to refresh.",
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.error),
              ),
            ),
          ),
        if (snap != null && people.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No one on your team is on the map right now.',
                textAlign: TextAlign.center,
                style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ),
      ]),
    );
  }
}

/// A status-coloured dot for a person on the map.
class _Dot extends StatelessWidget {
  const _Dot({required this.person, required this.color, required this.ring, required this.onTap});
  final GodViewPerson person;
  final Color color;
  final Color ring;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final on = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : const Color(0xFF05121C);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: ring, width: 2.5),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 1))],
        ),
        alignment: Alignment.center,
        child: Icon(person.isPartner ? Icons.directions_car : Icons.person, size: 18, color: on),
      ),
    );
  }
}

/// The scrollable count chips over the map (Online partners · Free · …).
class _StatsStrip extends StatelessWidget {
  const _StatsStrip({required this.snap});
  final GodViewSnapshot snap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final stats = godViewStats(snap.counts)..removeWhere((s) => s.value == 0 && !s.alarm);
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _Chip(label: 'On the map', value: snap.total, cs: cs, strong: true),
          if (snap.counts.sos > 0) _Chip(label: 'SOS', value: snap.counts.sos, cs: cs, alarm: true),
          for (final s in stats) _Chip(label: s.label, value: s.value, cs: cs, alarm: s.alarm),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.value, required this.cs, this.alarm = false, this.strong = false});
  final String label;
  final int value;
  final ColorScheme cs;
  final bool alarm;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final bg = alarm ? cs.errorContainer : (strong ? cs.secondaryContainer : cs.surfaceContainerHighest);
    final fg = alarm ? cs.onErrorContainer : (strong ? cs.onSecondaryContainer : cs.onSurface);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: bg,
        elevation: 1,
        borderRadius: BorderRadius.circular(99),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('$value', style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: fg, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

/// The tap sheet for a person: who they are and what they are doing.
class _PersonSheet extends StatelessWidget {
  const _PersonSheet({required this.person});
  final GodViewPerson person;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final color = godViewStatusColor(person.status, t.brightness);
    final updated = person.updatedAt;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(backgroundColor: color, child: Text(person.initials, style: const TextStyle(color: Colors.white))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(person.displayName, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text(person.vehicleLine, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            Chip(
              avatar: CircleAvatar(backgroundColor: color, radius: 6),
              label: Text(person.status.label),
              visualDensity: VisualDensity.compact,
            ),
            if ((person.area ?? '').trim().isNotEmpty)
              Chip(label: Text(person.area!.trim()), visualDensity: VisualDensity.compact),
          ]),
          if (updated != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Last seen ${_ago(updated)}',
                style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
        ]),
      ),
    );
  }
}

String _ago(DateTime at) {
  final d = DateTime.now().difference(at);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}
