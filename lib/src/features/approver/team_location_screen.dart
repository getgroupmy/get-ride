// Team Location (migrations 0406/0408): an approver's God View of the team
// they cover. A live map of where their people are, from approver_team_snapshot
// — the same rows and models God View uses, but scoped server-side to exactly
// the approver's team. Tapping a person opens the same per-person location
// actions God View has — reveal phone, ping, Live now, movement — which the
// server (0408) lets an approver run on a member they cover, logged to the
// audit log and (for Live now) opening the member's "shared live" notice,
// exactly as God View does. Admin-only God View actions (suspend, open admin
// profile) are not here.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../admin/screens/god_view_screen.dart' show godViewStatusColor;
import '../../core/god_view.dart';
import '../../core/god_view_live.dart';
import '../../core/god_view_trail.dart';
import '../../data/approver_inbox_repository.dart';
import '../../data/god_view_repository.dart';
import '../../widgets/common.dart';
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

  // A member's movement drawn on the map (the trail action).
  GodViewTrail? _trail;
  GodViewPerson? _trailPerson;

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
    final pts = _trail != null && _trail!.points.isNotEmpty
        ? [for (final p in _trail!.points) LatLng(p.lat, p.lng)]
        : [for (final p in (_snap?.people ?? const <GodViewPerson>[])) LatLng(p.lat, p.lng)];
    if (!mounted || !_mapReady || pts.isEmpty) return;
    try {
      if (pts.length == 1) {
        _map.move(pts.first, 14);
      } else {
        _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(56)));
      }
    } catch (_) {}
  }

  void _showTrail(GodViewPerson person, GodViewTrail trail) {
    setState(() {
      _trail = trail;
      _trailPerson = person;
    });
    _fit();
  }

  void _clearTrail() => setState(() {
        _trail = null;
        _trailPerson = null;
      });

  void _openPerson(GodViewPerson p) {
    unawaited(showAppSheet<void>(
      id: 'approver.team-location-person',
      context: context,
      isScrollControlled: true,
      builder: (_) => _PersonSheet(person: p, onTrail: _showTrail),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final b = t.brightness;
    final cs = t.colorScheme;
    final snap = _snap;
    final people = snap?.people ?? const <GodViewPerson>[];
    final trail = _trail;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Team Location'),
        actions: [
          if (trail != null)
            IconButton(
              key: const ValueKey('team-location-clear-trail'),
              tooltip: 'Clear movement',
              icon: const Icon(Icons.timeline),
              onPressed: _clearTrail,
            ),
          IconButton(
            key: const ValueKey('team-location-fit'),
            tooltip: 'Fit the team',
            icon: const Icon(Icons.fit_screen_outlined),
            onPressed: people.isEmpty && trail == null ? null : _fit,
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
            if (trail != null && trail.points.length > 1)
              PolylineLayer(polylines: [
                Polyline(
                  points: [for (final p in trail.points) LatLng(p.lat, p.lng)],
                  strokeWidth: 4,
                  color: cs.primary.withValues(alpha: 0.8),
                ),
              ]),
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
        if (trail != null)
          Positioned(
            bottom: 16 + MediaQuery.viewPaddingOf(context).bottom,
            left: 12,
            right: 12,
            child: _TrailBanner(person: _trailPerson, trail: trail, onClear: _clearTrail),
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
        if (snap != null && people.isEmpty && trail == null)
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

/// The small banner over the map while a member's movement is drawn.
class _TrailBanner extends StatelessWidget {
  const _TrailBanner({required this.person, required this.trail, required this.onClear});
  final GodViewPerson? person;
  final GodViewTrail trail;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final km = trailKm(trail.points);
    return Material(
      color: cs.surface,
      elevation: 3,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(children: [
          Icon(Icons.timeline, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text("${person?.displayName ?? 'Member'} · movement",
                  style: t.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text('${trail.points.length} points · ${km.toStringAsFixed(1)} km',
                  style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ]),
          ),
          TextButton(onPressed: onClear, child: const Text('Clear')),
        ]),
      ),
    );
  }
}

/// The tap sheet for a person: who they are, where, and the location actions
/// an approver may run on a member they cover (0408).
class _PersonSheet extends ConsumerStatefulWidget {
  const _PersonSheet({required this.person, required this.onTrail});
  final GodViewPerson person;
  final void Function(GodViewPerson person, GodViewTrail trail) onTrail;

  @override
  ConsumerState<_PersonSheet> createState() => _PersonSheetState();
}

class _PersonSheetState extends ConsumerState<_PersonSheet> {
  GodViewPerson get _p => widget.person;
  GodViewRepository get _repo => ref.read(godViewRepositoryProvider);

  // Reveal phone.
  bool _revealing = false;
  bool _revealed = false;
  String? _phone;

  // Ping.
  bool _pinging = false;
  GodViewPingStage? _pingStage;
  DateTime? _pingAt;
  Timer? _pingPoll;

  // Live now.
  bool _liveBusy = false;
  int _liveMinutes = godViewLiveChoices[1]; // 15 min
  GodViewLiveSession? _live;
  Duration _skew = Duration.zero;
  Timer? _liveTick;
  Timer? _livePoll;

  // Trail.
  bool _trailBusy = false;

  @override
  void dispose() {
    _pingPoll?.cancel();
    _liveTick?.cancel();
    _livePoll?.cancel();
    super.dispose();
  }

  DateTime get _serverNow => DateTime.now().toUtc().add(_skew);

  Future<void> _reveal() async {
    setState(() => _revealing = true);
    try {
      final phone = await _repo.revealPhone(_p.id);
      if (!mounted) return;
      setState(() {
        _revealed = true;
        _phone = phone;
      });
      if (phone == null && mounted) showInfo(context, 'No phone number on this account.');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _revealing = false);
    }
  }

  Future<void> _call() async {
    final phone = _phone;
    if (phone == null) return;
    final ok = await launchUrl(Uri(scheme: 'tel', path: phone));
    if (!ok && mounted) showInfo(context, "Couldn't open the dialer.");
  }

  Future<void> _ping() async {
    _pingPoll?.cancel();
    setState(() {
      _pinging = true;
      _pingStage = GodViewPingStage.sending;
      _pingAt = null;
    });
    try {
      final res = await _repo.ping(_p.id);
      if (!mounted) return;
      final stage = godViewPingStageOf(res);
      setState(() {
        _pingStage = stage;
        _pingAt = res.retryAt ?? res.sentAt;
      });
      if (stage == GodViewPingStage.waiting && res.sentAt != null) {
        final since = res.sentAt!;
        final deadline = DateTime.now().add(godViewPingWait);
        _pingPoll = Timer.periodic(const Duration(seconds: 4), (timer) async {
          if (!mounted) return timer.cancel();
          try {
            final ans = await _repo.pingAnswer(_p.id, since);
            if (!mounted) return timer.cancel();
            if (ans.answered) {
              timer.cancel();
              setState(() {
                _pingStage = GodViewPingStage.answered;
                _pingAt = ans.at;
              });
            } else if (DateTime.now().isAfter(deadline)) {
              timer.cancel();
              setState(() => _pingStage = GodViewPingStage.noAnswer);
            }
          } catch (_) {/* keep polling */}
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _pingStage = GodViewPingStage.failed);
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _pinging = false);
    }
  }

  void _trackLive(GodViewLiveSession? session, {DateTime? serverNow}) {
    if (serverNow != null) _skew = serverNow.difference(DateTime.now().toUtc());
    setState(() => _live = session);
    final live = session != null && session.stoppedAt == null && _serverNow.isBefore(session.endsAt);
    if (live) {
      _liveTick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (_live == null || !_serverNow.isBefore(_live!.endsAt)) {
          _liveTick?.cancel();
          _liveTick = null;
          setState(() {});
        } else {
          setState(() {});
        }
      });
      _livePoll ??= Timer.periodic(godViewLiveEvery, (_) async {
        if (!mounted) return;
        try {
          final s = await _repo.liveStatus(_p.id);
          if (mounted) _trackLive(s.session, serverNow: s.serverNow);
        } catch (_) {}
      });
    } else {
      _liveTick?.cancel();
      _liveTick = null;
      _livePoll?.cancel();
      _livePoll = null;
    }
  }

  Future<void> _liveStart() async {
    setState(() => _liveBusy = true);
    try {
      final r = await _repo.liveStart(_p.id, _liveMinutes);
      if (!mounted) return;
      if (r.session != null) {
        _trackLive(r.session);
      } else if (r.problem != null) {
        showInfo(context, r.problem!);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _liveBusy = false);
    }
  }

  Future<void> _liveStop() async {
    final s = _live;
    if (s == null) return;
    setState(() => _liveBusy = true);
    try {
      await _repo.liveStop(s.id);
      if (mounted) _trackLive(null);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _liveBusy = false);
    }
  }

  Future<void> _loadTrail() async {
    setState(() => _trailBusy = true);
    try {
      final w = trailWindow(now: DateTime.now());
      final trail = await _repo.trail(_p.id, w.from, w.to);
      if (!mounted) return;
      if (trail.points.isEmpty) {
        showInfo(context, 'No movement recorded in the last 24 hours.');
      } else {
        widget.onTrail(_p, trail);
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _trailBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final color = godViewStatusColor(_p.status, t.brightness);
    final updated = _p.updatedAt;
    final liveStage = godViewLiveStageOf(_live, _serverNow);
    final liveOn = liveStage != GodViewLiveStage.off;
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(backgroundColor: color, child: Text(_p.initials, style: const TextStyle(color: Colors.white))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_p.displayName, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  Text(_p.vehicleLine, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              Chip(
                avatar: CircleAvatar(backgroundColor: color, radius: 6),
                label: Text(_p.status.label),
                visualDensity: VisualDensity.compact,
              ),
              if ((_p.area ?? '').trim().isNotEmpty)
                Chip(label: Text(_p.area!.trim()), visualDensity: VisualDensity.compact),
            ]),
            if (updated != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text('Last seen ${_ago(updated)}',
                    style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ),
            const Divider(height: 28),

            // Reveal phone / call.
            if (!_revealed)
              OutlinedButton.icon(
                key: const ValueKey('team-location-reveal'),
                onPressed: _revealing ? null : _reveal,
                icon: const Icon(Icons.phone_outlined),
                label: Text(_revealing ? 'Revealing…' : 'Reveal phone'),
              )
            else if (_phone != null)
              FilledButton.icon(
                key: const ValueKey('team-location-call'),
                onPressed: _call,
                icon: const Icon(Icons.call),
                label: Text('Call $_phone'),
              ),

            const SizedBox(height: 10),
            // Ping.
            OutlinedButton.icon(
              key: const ValueKey('team-location-ping'),
              onPressed: _pinging ? null : _ping,
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('Ping — ask their phone to report now'),
            ),
            if (_pingStage != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(godViewPingLine(_pingStage!, at: _pingAt, now: DateTime.now()),
                    style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ),

            const SizedBox(height: 10),
            // Live now.
            Row(children: [
              Expanded(
                child: liveOn
                    ? FilledButton.icon(
                        key: const ValueKey('team-location-live-stop'),
                        style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
                        onPressed: _liveBusy ? null : _liveStop,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: Text(godViewLiveStopLabel(_live!.endsAt, _serverNow)),
                      )
                    : OutlinedButton.icon(
                        key: const ValueKey('team-location-live-start'),
                        onPressed: _liveBusy ? null : _liveStart,
                        icon: const Icon(Icons.my_location),
                        label: Text('Live now · ${godViewLiveChoiceLabel(_liveMinutes)}'),
                      ),
              ),
              if (!liveOn)
                PopupMenuButton<int>(
                  key: const ValueKey('team-location-live-minutes'),
                  tooltip: 'How long',
                  icon: const Icon(Icons.timer_outlined),
                  onSelected: (m) => setState(() => _liveMinutes = m),
                  itemBuilder: (_) => [
                    for (final m in godViewLiveChoices)
                      PopupMenuItem(value: m, child: Text(godViewLiveChoiceLabel(m))),
                  ],
                ),
            ]),
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(godViewLiveNowLine(liveStage),
                  style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ),

            const SizedBox(height: 10),
            // Movement (trail).
            OutlinedButton.icon(
              key: const ValueKey('team-location-trail'),
              onPressed: _trailBusy ? null : _loadTrail,
              icon: const Icon(Icons.timeline),
              label: Text(_trailBusy ? 'Loading movement…' : "View today's movement"),
            ),

            const SizedBox(height: 14),
            Text(
              'What you do here is in the audit log, and a live share shows the member a “shared live” notice.',
              style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ]),
        ),
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
