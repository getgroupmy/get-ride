// Admin → God View (migrations 0270, 0272, 0276): everyone's live position
// and status on one map, with a People list and a Details card. Polls
// god_view_snapshot every 5 s while the page is on screen, for everyone the
// admin may see, not only the map's view: tapping a name zooms in, and the
// list must not shrink to that one person (the server puts SOS and live
// people first when it caps the count). With "Last known" (on by default) everyone else is
// there too, smaller and greyed, where they last were. A sub-admin sees the
// people in their own region (the server's rule). "Ping now" asks a quiet
// phone where it is (0276); Settings holds the ping minutes and how long a
// quiet Always on phone stays Always on.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/app_version.dart' show AppVersionRule;
import '../../core/god_view.dart';
import '../../core/god_view_trail.dart' show trailWindow;
import '../../core/page_styles.dart' show godViewSurface;
import '../../data/app_version_repository.dart' show appVersionRulesProvider;
import '../../data/geo_service.dart' show Place, defaultCenter;
import '../../core/smart_address.dart' show placeAreaLine, placeIcon, shortArea;
import '../../data/god_view_repository.dart';
import '../../providers.dart' show geoServiceProvider;
import '../../widgets/busy.dart';
import '../../widgets/call_number.dart';
import '../../widgets/common.dart';
import '../../widgets/date_boxes.dart' show pickDateFromCalendar;
import '../../widgets/map_credit.dart';
import '../../widgets/map_tiles.dart';
import '../../widgets/page_style_host.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import '../widgets/phone_card.dart';
import 'god_view_movement.dart';
import 'people/partner_live_card.dart' show PartnerLivePill;
import 'people/partner_screens.dart' show partnerLiveProvider;
import 'people_screens.dart' show adminDialerProvider;
import 'safety/safety_incidents_screen.dart' show openSafetyIncidents;

/// A status's colour on the map, the list and the legend, light or dark.
Color godViewStatusColor(GodViewStatus s, Brightness b) {
  final dark = b == Brightness.dark;
  return Color(switch (s) {
    GodViewStatus.free => dark ? 0xFF4FD39B : 0xFF17885E,
    GodViewStatus.pickup => dark ? 0xFFFFB648 : 0xFFC27A00,
    GodViewStatus.trip => dark ? 0xFF7AA6FF : 0xFF2F6FE0,
    GodViewStatus.searching => dark ? 0xFFB88CFF : 0xFF8A4FD8,
    GodViewStatus.ride => dark ? 0xFF4CBCFF : 0xFF0B7FB8,
    GodViewStatus.appOpen => dark ? 0xFF86AEBB : 0xFF5E8C9A,
    GodViewStatus.alwaysOn => dark ? 0xFFB9D84A : 0xFF6A8500,
    GodViewStatus.sos => dark ? 0xFFFF6B76 : 0xFFD32F3B,
    GodViewStatus.notResponding => dark ? 0xFF6B7585 : 0xFF8B95A4,
    GodViewStatus.lastKnown => dark ? 0xFF555E6C : 0xFFA9B1BD,
  });
}

/// The outline a status is drawn with instead of the plain ring: "Online,
/// not responding" is grey with a dark (light, in dark mode) outline.
Color? godViewStatusOutline(GodViewStatus s, Brightness b) => s == GodViewStatus.notResponding
    ? (b == Brightness.dark ? const Color(0xFFD5DAE1) : const Color(0xFF39404B))
    : null;

/// Text or an icon drawn on [c]: white on a dark colour, near-black on a light one.
Color _on(Color c) => ThemeData.estimateBrightnessForColor(c) == Brightness.dark ? Colors.white : const Color(0xFF05121C);

IconData _serviceIcon(GodViewService s) => switch (s) {
  GodViewService.car => Icons.directions_car,
  GodViewService.motorcycle => Icons.two_wheeler,
  GodViewService.freight => Icons.local_shipping,
};

class GodViewScreen extends ConsumerStatefulWidget {
  const GodViewScreen({super.key});

  @override
  ConsumerState<GodViewScreen> createState() => _GodViewScreenState();
}

class _GodViewScreenState extends ConsumerState<GodViewScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  final _map = MapController();
  late final TabController _tabs = TabController(length: 2, vsync: this);
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  final _search = TextEditingController();

  GodViewFilters _filters = const GodViewFilters();
  GodViewSnapshot? _snap;

  /// The People list's "No location" section (0275): fetched on open, on
  /// Refresh and with the search, not with every poll.
  List<GodViewUnlocated> _unlocated = const [];
  bool _noLocationOpen = false;
  Object? _error;
  DateTime? _fetchedAt;

  String? _selectedId;
  GodViewPerson? _selectedLast;
  bool _follow = false;

  /// The Movement trail (0278) for the selected person, when open.
  GodViewMovementState? _move;

  /// "Follow roads" (App Page Settings): the road for each run of the
  /// shown trail, and which trail and hours it was worked out for.
  List<List<LatLng>?> _roads = const [];
  String? _roadsFor;

  /// "Show address": the street address of [_addrFor]'s position.
  String? _addrFor;
  String? _addr;
  Place? _addrPlace;
  bool _addrBusy = false;
  final _phones = <String, String?>{};

  Timer? _poll, _tick, _searchWait, _pingPoll;

  /// "Ping now" on the Details tab: whose, where it stands, and the time the
  /// line names (the answer, or when to try again).
  ({String id, GodViewPingStage stage, DateTime? at})? _ping;
  bool _mapReady = false, _fitted = false, _inFlight = false, _again = false, _resumed = true;

  DateTime _now() => ref.read(godViewClockProvider)();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final every = ref.read(godViewPollProvider);
    if (every != null) {
      _poll = Timer.periodic(every, (_) => _load());
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _visible) setState(() {});
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _loadUnlocated();
    });
  }

  ModalRoute<Object?>? _route;
  bool _tickersOn = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final on = TickerMode.valuesOf(context).enabled;
    if (on && !_tickersOn) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    _tickersOn = on;
    // A pulse only where motion is welcome (and never in a test's settle).
    if (MediaQuery.disableAnimationsOf(context) || ref.read(godViewPollProvider) == null) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final t in [_poll, _tick, _searchWait, _pingPoll]) {
      t?.cancel();
    }
    _tabs.dispose();
    _pulse.dispose();
    _search.dispose();
    _map.dispose();
    super.dispose();
  }

  /// On screen: the app in front, this page the top route, not behind a tab.
  bool get _visible {
    if (!mounted || !_resumed || !_tickersOn) return false;
    return _route?.isCurrent ?? true;
  }

  Future<void> _load() async {
    if (!_visible) return;
    if (_inFlight) {
      _again = true;
      return;
    }
    _inFlight = true;
    try {
      final s = await ref.read(godViewRepositoryProvider).snapshot(
        showOffline: _filters.lastKnown,
        query: _filters.query,
      );
      if (!mounted) return;
      setState(() {
        _snap = s;
        _error = null;
        _fetchedAt = _now();
        final sel = _selectedId == null ? null : s.people.where((p) => p.id == _selectedId).firstOrNull;
        if (sel != null) _selectedLast = sel;
      });
      _afterLoad(s);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      _inFlight = false;
      if (_again && mounted) {
        _again = false;
        unawaited(_load());
      }
    }
  }

  /// Quiet on failure (a database without 0275): the section stays empty.
  Future<void> _loadUnlocated() async {
    final query = _filters.query;
    try {
      final rows = await ref.read(godViewRepositoryProvider).unlocated(query: query);
      if (mounted && _filters.query == query) setState(() => _unlocated = rows);
    } catch (e) {
      debugPrint('[god-view] no-location list not loaded: $e');
    }
  }

  void _refresh() {
    _load();
    _loadUnlocated();
  }

  void _afterLoad(GodViewSnapshot s) {
    if (!_mapReady) return;
    if (_follow && _selectedLast != null) {
      _map.move(LatLng(_selectedLast!.lat, _selectedLast!.lng), _map.camera.zoom);
    } else if (!_fitted && s.people.isNotEmpty) {
      _fitted = true;
      // The live people when there are any; else everyone's last position.
      final live = s.people.where((p) => !p.status.isLastKnown).toList();
      _fitAll(live.isEmpty ? s.people : live);
    }
  }

  void _fitAll(List<GodViewPerson> people) {
    if (!_mapReady || people.isEmpty) return;
    final pts = [for (final p in people) LatLng(p.lat, p.lng)];
    if (pts.length == 1) {
      _map.move(pts.first, 15);
    } else {
      _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(56), maxZoom: 16));
    }
  }

  void _onCamera(MapCamera camera, bool gesture) {
    if (gesture && _follow) setState(() => _follow = false);
  }

  void _setFilters(GodViewFilters f, {bool reload = false}) {
    setState(() => _filters = f);
    if (reload) _load();
  }

  void _onSearch(String q) {
    setState(() => _filters = _filters.copyWith(query: q));
    _searchWait?.cancel();
    _searchWait = Timer(const Duration(milliseconds: 400), _refresh);
  }

  void _select(GodViewPerson p, {bool move = true}) {
    setState(() {
      if (_selectedId != p.id) {
        _move = null;
        _addrFor = null;
        _addr = null;
      }
      _selectedId = p.id;
      _selectedLast = p;
      if (_follow) _follow = false;
    });
    _tabs.animateTo(1);
    if (move && _mapReady) _map.move(LatLng(p.lat, p.lng), math.max(_map.camera.zoom, 14));
  }

  Future<void> _showAddress(GodViewPerson p) async {
    setState(() {
      _addrFor = p.id;
      _addr = null;
      _addrBusy = true;
    });
    String text;
    Place? place;
    try {
      place = await ref.read(geoServiceProvider).reverse(LatLng(p.lat, p.lng));
      text = [place.name, place.address].where((s) => s.trim().isNotEmpty).toSet().join(', ');
      if (text.isEmpty) {
        text = 'No address found for this spot.';
        place = null;
      }
    } catch (e) {
      text = 'Address not found: $e';
    }
    if (!mounted || _addrFor != p.id) return;
    setState(() {
      _addr = text;
      _addrPlace = place;
      _addrBusy = false;
    });
  }

  void _toggleMovement(GodViewPerson p) {
    if (_move?.personId == p.id) {
      setState(() => _move = null);
      return;
    }
    setState(() => _move = GodViewMovementState(personId: p.id));
    _loadTrail();
  }

  Future<void> _loadTrail() async {
    final m = _move;
    if (m == null) return;
    setState(() => _move = m.copyWith(loading: true, error: () => null));
    final w = trailWindow(day: m.day, now: _now());
    try {
      final trail = await ref.read(godViewRepositoryProvider).trail(m.personId, w.from, w.to);
      if (!mounted || _move?.personId != m.personId || _move?.day != m.day) return;
      setState(() => _move = _move!.copyWith(trail: () => trail, loading: false));
      _fitTrail();
    } catch (e) {
      if (!mounted || _move?.personId != m.personId) return;
      setState(() => _move = _move!.copyWith(loading: false, error: () => e));
    }
  }

  String _roadsKey(GodViewMovementState m) =>
      '${m.personId}|${m.day}|${(m.hours.toList()..sort()).join(',')}|${m.trail?.from}|${m.trail?.points.length}';

  /// Works out the roads for the shown trail once per trail and hours.
  void _maybeLoadRoads(TrailLook look) {
    final m = _move;
    if (!look.followRoads || m == null || m.trail == null || m.loading) return;
    final key = _roadsKey(m);
    if (_roadsFor == key || _roadsAsked == key) return;
    _roadsAsked = key;
    final geo = ref.read(geoServiceProvider);
    trailRoads(m.shown, (pts) async {
      final r = await geo.route(pts.first, pts.last, via: pts.sublist(1, pts.length - 1));
      return r.points;
    }).then((roads) {
      if (!mounted || _roadsAsked != key) return;
      setState(() {
        _roads = roads;
        _roadsFor = key;
      });
    }, onError: (Object e) => debugPrint('[god-view] trail roads: $e'));
  }

  String? _roadsAsked;

  void _fitTrail() {
    final pts = _move?.shown ?? const [];
    if (!_mapReady || pts.isEmpty) return;
    if (_follow) setState(() => _follow = false);
    final ll = [for (final p in pts) LatLng(p.lat, p.lng)];
    if (ll.length == 1) {
      _map.move(ll.first, 16);
    } else {
      _map.fitCamera(CameraFit.coordinates(coordinates: ll, padding: const EdgeInsets.all(56), maxZoom: 17));
    }
  }

  Future<void> _pickTrailDay() async {
    final now = _now();
    final picked = await pickDateFromCalendar(
      context,
      initial: _move?.day ?? now.subtract(const Duration(days: 1)),
      firstDate: now.subtract(const Duration(days: 89)),
      lastDate: now,
      helpText: 'Movement on',
    );
    if (picked == null || !mounted || _move == null) return;
    setState(() => _move = _move!.copyWith(day: () => picked, hours: const {}, trail: () => null));
    await _loadTrail();
  }

  Future<String?> _phone(GodViewPerson p) async {
    if (_phones.containsKey(p.id)) return _phones[p.id];
    final phone = await ref.read(godViewRepositoryProvider).revealPhone(p.id);
    if (mounted) setState(() => _phones[p.id] = phone);
    return phone;
  }

  Future<void> _reveal(GodViewPerson p) async {
    try {
      final phone = await _phone(p);
      if (mounted && phone == null) showInfo(context, 'No phone number on this account.');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _call(GodViewPerson p, {bool sms = false}) async {
    try {
      final phone = await _phone(p);
      if (!mounted) return;
      if (phone == null) {
        showInfo(context, 'No phone number on this account.');
        return;
      }
      if (sms) {
        final ok = await ref.read(adminDialerProvider)(Uri(scheme: 'sms', path: phone.replaceAll(RegExp(r'[^+\d]'), '')));
        if (!ok && mounted) showNumberToCopy(context, phone);
      } else {
        await callNumber(context, phone, launcher: ref.read(adminDialerProvider));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _suspend(GodViewPerson p) async {
    final onJob = p.isPartner && p.rideId != null;
    final answer = await showAppDialog<_SuspendAnswer>(
      id: 'god-view.suspend',
      context: context,
      builder: (_) => _SuspendDialog(person: p, onTrip: onJob),
    );
    if (answer == null || !mounted) return;
    var onTrip = false;
    final ok = await runAdminAction(context, () async {
      onTrip = await ref
          .read(godViewRepositoryProvider)
          .suspend(p.id, answer.reason, note: answer.note.trim().isEmpty ? null : answer.note.trim());
    });
    if (!ok || !mounted) return;
    showInfo(
      context,
      onTrip ? '${p.displayName} is suspended. On a trip: they can finish this one.' : '${p.displayName} is suspended.',
    );
    unawaited(_load());
  }

  Future<void> _sendPush(GodViewPerson p) => showAppSheet<void>(
    id: 'god-view.send-push',
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _PushSheet(person: p),
  );

  Future<void> _openSettings() async {
    final saved = await showAppSheet<GodViewSettings>(
      id: 'god-view.settings',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _SettingsSheet(settings: _snap?.settings ?? const GodViewSettings()),
    );
    if (saved != null && mounted) unawaited(_load());
  }

  /// "Ping now": the silent push, then up to [godViewPingWait] for the phone
  /// to answer; the map refreshes once it has.
  Future<void> _pingNow(GodViewPerson p) async {
    _pingPoll?.cancel();
    setState(() => _ping = (id: p.id, stage: GodViewPingStage.sending, at: null));
    try {
      final r = await ref.read(godViewRepositoryProvider).ping(p.id);
      if (!mounted) return;
      final stage = godViewPingStageOf(r);
      setState(() => _ping = (id: p.id, stage: stage, at: stage == GodViewPingStage.recent ? r.retryAt : null));
      if (stage == GodViewPingStage.waiting) _waitForAnswer(p.id, r.sentAt ?? _now());
    } catch (e) {
      if (!mounted) return;
      setState(() => _ping = null);
      showError(context, e);
    }
  }

  void _waitForAnswer(String id, DateTime since) {
    final every = ref.read(godViewPingPollProvider);
    final tries = (godViewPingWait.inMilliseconds / every.inMilliseconds).ceil();
    var asked = 0;
    var busy = false;
    _pingPoll = Timer.periodic(every, (t) async {
      if (busy) return;
      busy = true;
      asked++;
      try {
        final a = await ref.read(godViewRepositoryProvider).pingAnswer(id, since);
        if (!mounted || _ping?.id != id) {
          t.cancel();
          return;
        }
        if (a.answered) {
          t.cancel();
          setState(() => _ping = (id: id, stage: GodViewPingStage.answered, at: a.at));
          unawaited(_load());
        } else if (asked >= tries) {
          t.cancel();
          setState(() => _ping = (id: id, stage: GodViewPingStage.noAnswer, at: null));
        }
      } catch (_) {
        if (asked >= tries) {
          t.cancel();
          if (mounted && _ping?.id == id) setState(() => _ping = (id: id, stage: GodViewPingStage.noAnswer, at: null));
        }
      } finally {
        busy = false;
      }
    });
  }

  void _openProfile(GodViewPerson p) {
    final path = p.isPartner
        ? '/admin/m/partner-edit?id=${Uri.encodeQueryComponent(p.partnerRowId ?? '')}'
        : '/admin/m/user-edit?id=${Uri.encodeQueryComponent(p.id)}';
    context.push(path);
  }

  /// A "No location" row: the profile, when this admin may open it
  /// ([canPartner] / [canUser]: the edit pages' grants).
  VoidCallback? _openUnlocated(GodViewUnlocated u, {required bool canPartner, required bool canUser}) {
    if (!(u.isPartner ? canPartner : canUser)) return null;
    if (u.isPartner && u.partnerRowId == null) return null;
    final path = u.isPartner
        ? '/admin/m/partner-edit?id=${Uri.encodeQueryComponent(u.partnerRowId!)}'
        : '/admin/m/user-edit?id=${Uri.encodeQueryComponent(u.id)}';
    return () => context.push(path);
  }

  void _openRide(GodViewPerson p) => context.push('/admin/rides?ride=${Uri.encodeQueryComponent(p.rideId!)}');

  @override
  Widget build(BuildContext context) {
    final style = SurfaceStyle.of(context, godViewSurface);
    final snap = _snap;
    final shown = godViewShown(snap?.people ?? const [], _filters, serverQuery: snap?.query ?? '');
    final now = _now();
    final canPartner = ref.watch(pageAccessProvider('admin-partner-edit')) != AccessLevel.none;
    final canUser = ref.watch(pageAccessProvider('admin-user-edit')) != AccessLevel.none;
    return AdminPage(
      title: 'God View',
      module: 'god-view',
      actions: [
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refresh),
        IconButton(
          key: const ValueKey('god-view-settings'),
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: _openSettings,
        ),
      ],
      body: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 1000;
          final top = _TopBar(
            filters: _filters,
            search: _search,
            live: _error != null && snap != null
                ? 'Not updating: ${errorText(_error!)}'
                : godViewLiveLine(_fetchedAt, now),
            liveOk: _error == null,
            onFilters: _setFilters,
            onSearch: _onSearch,
          );
          final map = _mapStack(context, shown, style.number('markerSize'));
          final panel = _Panel(
            tabs: _tabs,
            people: godViewListOrder(shown),
            unlocated: godViewUnlocatedShown(_unlocated, _filters),
            versionRules: ref.watch(appVersionRulesProvider).value ?? const [],
            noLocationOpen: _noLocationOpen,
            onNoLocationOpen: (v) => setState(() => _noLocationOpen = v),
            onOpenUnlocated: (u) => _openUnlocated(u, canPartner: canPartner, canUser: canUser),
            selected: _selectedLast,
            selectedId: _selectedId,
            now: now,
            onPick: (p) => _select(p),
            details: _details(context, now),
          );
          if (snap == null && _error != null) {
            return Column(children: [
              top,
              Expanded(
                child: EmptyState(
                  icon: Icons.error_outline,
                  title: 'Could not load God View',
                  message: errorText(_error!),
                  action: OutlinedButton(onPressed: _load, child: const Text('Retry')),
                ),
              ),
            ]);
          }
          if (wide) {
            return Column(children: [
              top,
              const Divider(height: 1),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: map),
                  const VerticalDivider(width: 1),
                  SizedBox(width: style.number('panelWidth'), child: panel),
                ]),
              ),
            ]);
          }
          // A phone: the panel under the map.
          final mapHeight = math.max(300.0, math.min(c.maxHeight * 0.5, 520.0));
          return Column(children: [
            top,
            const Divider(height: 1),
            SizedBox(height: mapHeight, child: map),
            const Divider(height: 1),
            Expanded(child: panel),
          ]);
        },
      ),
    );
  }

  Widget _mapStack(BuildContext context, List<GodViewPerson> shown, double size) {
    final b = Theme.of(context).brightness;
    final snap = _snap;
    final markers = godViewMarkers(shown);
    final selected = _selectedId;
    final card = Theme.of(context).colorScheme.surface;
    final look = TrailLook.of(context);
    if (look.followRoads && _move != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeLoadRoads(look);
      });
    }
    return Stack(children: [
      FlutterMap(
        mapController: _map,
        options: MapOptions(
          initialCenter: defaultCenter,
          initialZoom: 11,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            keyboardOptions: mapKeyboardOptions,
          ),
          onMapReady: () {
            _mapReady = true;
            final s = _snap;
            if (s != null) _afterLoad(s);
          },
          onPositionChanged: _onCamera,
        ),
        children: [
          baseTileLayer(context),
          PolylineLayer(polylines: [
            for (final p in markers)
              if (p.nextPoint case final n?)
                Polyline(
                  points: [LatLng(p.lat, p.lng), LatLng(n.lat, n.lng)],
                  color: godViewStatusColor(p.status, b).withValues(alpha: selected != null && selected != p.id ? 0.25 : 0.85),
                  strokeWidth: 3,
                  pattern: StrokePattern.dashed(segments: const [8, 7]),
                ),
          ]),
          if (_move case final m? when m.personId == selected)
            ...godViewTrailLayers(m.shown, look, card, roads: look.followRoads && _roadsFor == _roadsKey(m) ? _roads : const []),
          MarkerLayer(markers: [
            for (final p in markers)
              Marker(
                key: ValueKey('god-view-marker-${p.id}'),
                point: LatLng(p.lat, p.lng),
                width: size * 2.4,
                height: size * 2.4,
                child: _GodViewMarker(
                  person: p,
                  size: size,
                  color: godViewStatusColor(p.status, b),
                  ring: card,
                  selected: p.id == selected,
                  dim: selected != null && p.id != selected,
                  pulse: _pulse,
                  onTap: () => _select(p, move: false),
                ),
              ),
          ]),
          const MapCreditLayer(),
        ],
      ),
      Positioned(
        left: 10,
        top: 10,
        right: 60,
        child: Wrap(spacing: 6, runSpacing: 6, children: [
          for (final s in godViewStats(
            snap?.counts ?? const GodViewCounts(),
            partners: _filters.partners,
            users: _filters.users,
            lastKnown: _filters.lastKnown,
          ))
            _StatChip(label: s.label, value: s.value, alarm: s.alarm),
          if ((snap?.omitted ?? 0) > 0)
            _Note(key: const ValueKey('god-view-omitted'), text: godViewOmittedNote(snap!)),
          if (snap?.scopeMissing == true)
            const _Note(
              key: ValueKey('god-view-scope-missing'),
              text: 'Your God View access has no region yet. A full admin sets it under Sub-admins.',
            ),
        ]),
      ),
      Positioned(
        right: 10,
        top: 10,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _MapButton(tooltip: 'Zoom in', icon: Icons.add, onPressed: () => _zoom(1)),
          const SizedBox(height: 4),
          _MapButton(tooltip: 'Zoom out', icon: Icons.remove, onPressed: () => _zoom(-1)),
          const SizedBox(height: 4),
          _MapButton(tooltip: 'Fit everyone', icon: Icons.fit_screen, onPressed: () => _fitAll(markers)),
        ]),
      ),
      Positioned(
        left: 10,
        bottom: 24,
        child: _Legend(
          statuses: godViewLegend(lastKnown: _filters.lastKnown, partners: _filters.partners, users: _filters.users),
        ),
      ),
    ]);
  }

  void _zoom(int by) {
    if (!_mapReady) return;
    _map.move(_map.camera.center, (_map.camera.zoom + by).clamp(2.0, 19.0));
  }

  Widget _details(BuildContext context, DateTime now) {
    final p = _selectedLast;
    if (p == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Tap a marker or a row to see who it is.'),
      );
    }
    final t = Theme.of(context);
    final b = t.brightness;
    final color = godViewStatusColor(p.status, b);
    final onMap = _snap?.people.any((x) => x.id == p.id) ?? false;
    final other = p.otherName ?? (p.otherId == null ? null : 'On the ride');
    final actions = godViewActionsFor(
      p,
      canReadRides: ref.watch(moduleAccessProvider('rides')) != AccessLevel.none,
      canOpenProfile: ref.watch(pageAccessProvider(p.isPartner ? 'admin-partner-edit' : 'admin-user-edit')) != AccessLevel.none,
      canPush: ref.watch(moduleAccessProvider('push')) == AccessLevel.edit,
      canSuspend: ref.watch(moduleAccessProvider(p.isPartner ? 'partners' : 'users')) == AccessLevel.edit,
    );
    final phone = _phones[p.id];
    final revealed = _phones.containsKey(p.id);
    return ListView(
      key: const ValueKey('god-view-details'),
      padding: const EdgeInsets.all(14),
      children: [
        Row(children: [
          _Avatar(person: p, color: color, size: 44),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.displayName, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              _StatusPill(status: p.status),
              if (godViewNotMovedSince(p, now) case final still?) ...[
                const SizedBox(height: 4),
                Text(
                  still,
                  key: const ValueKey('god-view-not-moved'),
                  style: TextStyle(color: t.colorScheme.onSurfaceVariant),
                ),
              ],
            ]),
          ),
        ]),
        if (p.status == GodViewStatus.sos) ...[
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('god-view-sos-note'),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color),
            ),
            child: Text(
              p.rideCode == null ? 'SOS raised. Open the incident to act.' : 'SOS raised on ride ${p.rideCode}. Open the incident to act.',
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
        if (p.status == GodViewStatus.notResponding) ...[
          const SizedBox(height: 8),
          Text(
            'The app says online, but nothing has come from it for ${godViewAge(p.updatedAt, now).replaceAll(' ago', '')}. '
            'The app may be closed.',
            key: const ValueKey('god-view-not-responding-note'),
            style: TextStyle(color: t.colorScheme.onSurfaceVariant),
          ),
        ],
        if (p.status == GodViewStatus.lastKnown) ...[
          const SizedBox(height: 8),
          Text(
            'Last known position, ${godViewAge(p.updatedAt, now)}.',
            key: const ValueKey('god-view-last-known-note'),
            style: TextStyle(color: t.colorScheme.onSurfaceVariant),
          ),
        ],
        if (!onMap) ...[
          const SizedBox(height: 8),
          Text('No longer on the map as filtered.', style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
        ],
        const SizedBox(height: 12),
        if (p.isPartner)
          if (ref.watch(partnerLiveProvider((uid: p.id, hasVehicle: (p.plate ?? '').trim().isNotEmpty))).value
              case final live?)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 80, child: Text('Status', style: TextStyle(color: t.colorScheme.onSurfaceVariant))),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    PartnerLivePill(key: const ValueKey('god-view-live-status'), status: live.status, small: true),
                    const SizedBox(height: 2),
                    Text(live.detail, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ]),
                ),
              ]),
            ),
        _Facts(rows: [
          ('Type', p.isPartner ? 'Partner · ${_serviceName(p.serviceIcon)}' : 'User'),
          if (p.isPartner) ('Vehicle', p.vehicleLine == 'Partner' ? 'No vehicle linked' : p.vehicleLine),
          if (p.area != null) ('Area', p.area!),
          ('Position', '${p.lat.toStringAsFixed(5)}, ${p.lng.toStringAsFixed(5)} · ${godViewAge(p.updatedAt, now)}'),
          if (p.rideCode != null) ('Ride', [p.rideCode!, if (p.etaMin != null) 'ETA ${p.etaMin} min'].join(' · ')),
          if (other != null) (p.isPartner ? 'Passenger' : 'Driver', other),
        ]),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 80, child: Text('Address', style: TextStyle(color: t.colorScheme.onSurfaceVariant))),
          Expanded(
            child: _addrFor == p.id && !_addrBusy && _addr != null
                ? _SmartAddressText(place: _addrPlace, fallback: _addr!)
                : Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: BusyButton.text(
                      key: const ValueKey('god-view-show-address'),
                      onPressed: _addrBusy ? null : () => _showAddress(p),
                      child: Text(_addrBusy && _addrFor == p.id ? 'Looking up…' : 'Show address'),
                    ),
                  ),
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          SizedBox(width: 80, child: Text('Phone', style: TextStyle(color: t.colorScheme.onSurfaceVariant))),
          Expanded(
            child: Text(
              revealed ? (phone ?? 'None on file') : godViewPhoneHidden,
              key: const ValueKey('god-view-phone'),
            ),
          ),
          if (!revealed)
            BusyButton.text(
              key: const ValueKey('god-view-show-phone'),
              onPressed: () => _reveal(p),
              child: const Text('Show'),
            ),
        ]),
        if (revealed)
          Text('Recorded in the admin log.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        // The newest phone at its last report: model, app, battery, network.
        PhoneFacts(profileId: p.id, now: now),
        const SizedBox(height: 10),
        _PingRow(
          stage: _ping?.id == p.id ? _ping!.stage : null,
          at: _ping?.id == p.id ? _ping!.at : null,
          blocked: godViewPingBlocked(p),
          onPing: () => _pingNow(p),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const ValueKey('god-view-movement-button'),
          onPressed: () => _toggleMovement(p),
          icon: const Icon(Icons.route_outlined),
          label: Text(_move?.personId == p.id ? 'Hide movement' : 'Movement'),
        ),
        if (_move case final m? when m.personId == p.id) ...[
          const SizedBox(height: 8),
          GodViewMovementPanel(
            state: m,
            onLast24: () {
              if (m.day == null) return;
              setState(() => _move = m.copyWith(day: () => null, hours: const {}, trail: () => null));
              _loadTrail();
            },
            onPickDay: _pickTrailDay,
            onHours: (h) {
              setState(() => _move = m.copyWith(hours: h));
              _fitTrail();
            },
            onRetry: _loadTrail,
          ),
        ],
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (actions.contains(GodViewAction.follow))
            _follow
                ? FilledButton.icon(
                    key: const ValueKey('god-view-follow'),
                    onPressed: () => setState(() => _follow = false),
                    icon: const Icon(Icons.my_location),
                    label: const Text('Following'),
                  )
                : FilledButton.icon(
                    key: const ValueKey('god-view-follow'),
                    onPressed: () {
                      setState(() => _follow = true);
                      if (_mapReady) _map.move(LatLng(p.lat, p.lng), math.max(_map.camera.zoom, 15));
                    },
                    icon: const Icon(Icons.my_location),
                    label: const Text('Follow'),
                  ),
          if (actions.contains(GodViewAction.openRide))
            _ActionButton(key: const ValueKey('god-view-open-ride'), icon: Icons.receipt_long, label: 'Open ride', onPressed: () => _openRide(p)),
          if (actions.contains(GodViewAction.profile))
            _ActionButton(key: const ValueKey('god-view-profile'), icon: Icons.person, label: 'Profile', onPressed: () => _openProfile(p)),
          if (actions.contains(GodViewAction.message))
            _ActionButton(key: const ValueKey('god-view-message'), icon: Icons.chat_outlined, label: 'Message', onPressed: () => _call(p, sms: true)),
          if (actions.contains(GodViewAction.call))
            _ActionButton(key: const ValueKey('god-view-call'), icon: Icons.call_outlined, label: 'Call', onPressed: () => _call(p)),
          if (actions.contains(GodViewAction.sendPush))
            _ActionButton(key: const ValueKey('god-view-push'), icon: Icons.campaign_outlined, label: 'Send push', onPressed: () => _sendPush(p)),
          if (actions.contains(GodViewAction.suspend))
            _ActionButton(key: const ValueKey('god-view-suspend'), icon: Icons.block, label: 'Suspend', onPressed: () => _suspend(p)),
          if (actions.contains(GodViewAction.openIncident))
            OutlinedButton.icon(
              key: const ValueKey('god-view-incident'),
              style: OutlinedButton.styleFrom(foregroundColor: color, side: BorderSide(color: color)),
              onPressed: () => openSafetyIncidents(context),
              icon: const Icon(Icons.sos),
              label: const Text('Open incident'),
            ),
        ]),
      ],
    );
  }
}

String _serviceName(GodViewService s) => switch (s) {
  GodViewService.car => 'Car',
  GodViewService.motorcycle => 'Motorcycle',
  GodViewService.freight => 'Freight',
};

// ---- The top bar ------------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.filters,
    required this.search,
    required this.live,
    required this.liveOk,
    required this.onFilters,
    required this.onSearch,
  });

  final GodViewFilters filters;
  final TextEditingController search;
  final String live;
  final bool liveOk;
  final void Function(GodViewFilters f, {bool reload}) onFilters;
  final ValueChanged<String> onSearch;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final b = t.brightness;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilterChip(
            key: const ValueKey('god-view-partners'),
            avatar: const Icon(Icons.directions_car, size: 16),
            label: const Text('Partners'),
            selected: filters.partners,
            showCheckmark: false,
            onSelected: (v) => onFilters(filters.copyWith(partners: v)),
          ),
          FilterChip(
            key: const ValueKey('god-view-users'),
            avatar: const Icon(Icons.person, size: 16),
            label: const Text('Users'),
            selected: filters.users,
            showCheckmark: false,
            onSelected: (v) => onFilters(filters.copyWith(users: v)),
          ),
          // "Show offline" and "Last known" in one: everyone without a live
          // position, where they last were (up to 7 days).
          Tooltip(
            message: 'Show offline / last known: everyone without a live position, where they last were (up to 7 days)',
            child: FilterChip(
              key: const ValueKey('god-view-last-known'),
              avatar: const Icon(Icons.history, size: 16),
              label: const Text('Last known'),
              selected: filters.lastKnown,
              showCheckmark: false,
              onSelected: (v) => onFilters(filters.copyWith(lastKnown: v), reload: true),
            ),
          ),
          if (filters.users)
            SegmentedButton<GodViewUserFilter>(
              key: const ValueKey('god-view-user-filter'),
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                for (final f in GodViewUserFilter.values) ButtonSegment(value: f, label: Text(f.label)),
              ],
              selected: {filters.userFilter},
              onSelectionChanged: (s) => onFilters(filters.copyWith(userFilter: s.first)),
            ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              key: const ValueKey('god-view-search'),
              controller: search,
              onChanged: onSearch,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search name, phone, plate or ride code',
                suffixIcon: search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          search.clear();
                          onSearch('');
                        },
                      ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            flex: 0,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: liveOk ? godViewStatusColor(GodViewStatus.free, b) : t.colorScheme.error,
                ),
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  live,
                  key: const ValueKey('god-view-live'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ]),
    );
  }
}

// ---- The map's pieces -------------------------------------------------------------------------

class _GodViewMarker extends StatelessWidget {
  const _GodViewMarker({
    required this.person,
    required this.size,
    required this.color,
    required this.ring,
    required this.selected,
    required this.dim,
    required this.pulse,
    required this.onTap,
  });

  final GodViewPerson person;
  final double size;
  final Color color;
  final Color ring;
  final bool selected;
  final bool dim;
  final Animation<double> pulse;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // A last known position: smaller and greyed.
    final old = person.status.isLastKnown;
    final s = (selected ? size * 1.25 : size) * (old ? 0.72 : 1);
    final fg = _on(color);
    final outline = godViewStatusOutline(person.status, Theme.of(context).brightness);
    final border = Border.all(color: outline ?? ring, width: old ? 2 : (outline != null ? 2.5 : 3));
    final shadow = old ? const <BoxShadow>[] : const [BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 1))];
    final shape = person.isPartner
        ? Container(
            width: s,
            height: s,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: border, boxShadow: shadow),
            child: Icon(_serviceIcon(person.serviceIcon), size: s * 0.52, color: fg),
          )
        : Container(
            width: s * 0.82,
            height: s * 0.82,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(s * 0.22),
              border: border,
              boxShadow: shadow,
            ),
            child: Icon(Icons.person, size: s * 0.46, color: fg),
          );
    return Semantics(
      button: true,
      label: '${person.displayName}, ${person.isPartner ? 'partner' : 'user'}, ${person.status.label}',
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: (dim ? 0.45 : 1) * (old ? 0.8 : 1),
          child: Stack(alignment: Alignment.center, children: [
            if (person.status.pulses)
              AnimatedBuilder(
                animation: pulse,
                builder: (_, _) => Opacity(
                  opacity: (0.6 * (1 - pulse.value)).clamp(0.0, 1.0),
                  child: Container(
                    width: s * (1 + 1.3 * pulse.value),
                    height: s * (1 + 1.3 * pulse.value),
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                ),
              ),
            shape,
          ]),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label, required this.value, required this.alarm});
  final String label;
  final int value;
  final bool alarm;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final sos = godViewStatusColor(GodViewStatus.sos, t.brightness);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: alarm ? sos : t.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(
          '$value',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: alarm ? sos : t.colorScheme.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(label, style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: t.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: t.colorScheme.onSecondaryContainer)),
    );
  }
}

class _MapButton extends StatelessWidget {
  const _MapButton({required this.tooltip, required this.icon, required this.onPressed});
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(9),
        side: BorderSide(color: t.colorScheme.outlineVariant),
      ),
      child: IconButton(tooltip: tooltip, icon: Icon(icon, size: 20), onPressed: onPressed),
    );
  }
}

/// Closed to a small "Legend" button so it does not cover the map; a tap opens it and
/// another closes it again.
class _Legend extends StatefulWidget {
  const _Legend({required this.statuses});
  final List<GodViewStatus> statuses;

  @override
  State<_Legend> createState() => _LegendState();
}

class _LegendState extends State<_Legend> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final header = InkWell(
      key: const ValueKey('god-view-legend-toggle'),
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_open ? Icons.close : Icons.info_outline, size: 16),
          const SizedBox(width: 6),
          Text(_open ? 'Hide legend' : 'Legend', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
    return Material(
      key: const ValueKey('god-view-legend'),
      color: t.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: t.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        header,
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              for (final s in widget.statuses)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: godViewStatusColor(s, t.brightness),
                        shape: BoxShape.circle,
                        border: switch (godViewStatusOutline(s, t.brightness)) {
                          final c? => Border.all(color: c, width: 1.5),
                          null => null,
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(s.label, style: const TextStyle(fontSize: 12)),
                  ]),
                ),
              const SizedBox(height: 2),
              Text('Circle: partner · Square: user',
                  style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant)),
            ]),
          ),
      ]),
    );
  }
}

// ---- The panel --------------------------------------------------------------------------------

class _Panel extends StatelessWidget {
  const _Panel({
    required this.tabs,
    required this.people,
    required this.unlocated,
    required this.versionRules,
    required this.noLocationOpen,
    required this.onNoLocationOpen,
    required this.onOpenUnlocated,
    required this.selected,
    required this.selectedId,
    required this.now,
    required this.onPick,
    required this.details,
  });

  final TabController tabs;
  final List<GodViewPerson> people;
  final List<GodViewUnlocated> unlocated;
  final List<AppVersionRule> versionRules;
  final bool noLocationOpen;
  final ValueChanged<bool> onNoLocationOpen;
  final VoidCallback? Function(GodViewUnlocated) onOpenUnlocated;
  final GodViewPerson? selected;
  final String? selectedId;
  final DateTime now;
  final ValueChanged<GodViewPerson> onPick;
  final Widget details;

  @override
  Widget build(BuildContext context) => Column(children: [
    TabBar(
      controller: tabs,
      tabs: [
        Tab(key: const ValueKey('god-view-tab-people'), text: 'People (${people.length})'),
        const Tab(key: ValueKey('god-view-tab-details'), text: 'Details'),
      ],
    ),
    Expanded(
      child: AnimatedBuilder(
        animation: tabs,
        builder: (context, _) {
          if (tabs.index == 1) return details;
          if (people.isEmpty && unlocated.isEmpty) {
            return const Padding(padding: EdgeInsets.all(16), child: Text('No one matches.'));
          }
          // The located people, then the collapsible "No location (N)" rows.
          final noLocation = unlocated.isEmpty ? 0 : 1 + (noLocationOpen ? unlocated.length : 0);
          return ListView.builder(
            key: const ValueKey('god-view-people'),
            itemCount: people.length + noLocation,
            itemBuilder: (_, i) {
              if (i < people.length) {
                return _PersonRow(
                  person: people[i],
                  selected: people[i].id == selectedId,
                  now: now,
                  onTap: () => onPick(people[i]),
                );
              }
              if (i == people.length) {
                return _NoLocationHeader(
                  count: unlocated.length,
                  open: noLocationOpen,
                  onTap: () => onNoLocationOpen(!noLocationOpen),
                );
              }
              final u = unlocated[i - people.length - 1];
              return _UnlocatedRow(
                person: u,
                reason: godViewNoLocationReason(u, versionRules),
                onTap: onOpenUnlocated(u),
              );
            },
          );
        },
      ),
    ),
  ]);
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.person, required this.selected, required this.now, required this.onTap});
  final GodViewPerson person;
  final bool selected;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = person;
    return Material(
      color: selected ? t.colorScheme.secondaryContainer.withValues(alpha: 0.5) : Colors.transparent,
      child: InkWell(
        key: ValueKey('god-view-row-${p.id}'),
        onTap: onTap,
        // A last known position reads greyed, after the live ones.
        child: Opacity(
          opacity: p.status.isLastKnown ? 0.72 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              _Avatar(person: p, color: godViewStatusColor(p.status, t.brightness), size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    [p.vehicleLine, ?p.area].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant),
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                _StatusPill(status: p.status),
                const SizedBox(height: 2),
                Text(
                  godViewNotMovedSince(p, now) ?? godViewAge(p.updatedAt, now),
                  style: TextStyle(fontSize: 11, color: t.colorScheme.onSurfaceVariant),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class _NoLocationHeader extends StatelessWidget {
  const _NoLocationHeader({required this.count, required this.open, required this.onTap});
  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: InkWell(
        key: const ValueKey('god-view-no-location'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            Icon(Icons.location_off_outlined, size: 18, color: t.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text('No location ($count)', style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Icon(open ? Icons.expand_less : Icons.expand_more, color: t.colorScheme.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }
}

/// Someone God View cannot put on the map: in the list only, greyed, with why.
class _UnlocatedRow extends StatelessWidget {
  const _UnlocatedRow({required this.person, required this.reason, required this.onTap});
  final GodViewUnlocated person;
  final String reason;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = person;
    final grey = godViewStatusColor(GodViewStatus.lastKnown, t.brightness);
    final size = 34.0;
    return InkWell(
      key: ValueKey('god-view-unlocated-${p.id}'),
      onTap: onTap,
      child: Opacity(
        opacity: 0.72,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: grey,
                shape: p.isPartner ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: p.isPartner ? null : BorderRadius.circular(size * 0.25),
              ),
              child: Text(
                p.initials,
                style: TextStyle(color: _on(grey), fontWeight: FontWeight.w700, fontSize: size * 0.36),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  '${p.vehicleLine} · $reason',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: grey.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(6)),
              child: Text(
                'No location',
                style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 11, fontWeight: FontWeight.w700),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.person, required this.color, required this.size});
  final GodViewPerson person;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: color,
      shape: person.isPartner ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: person.isPartner ? null : BorderRadius.circular(size * 0.25),
    ),
    child: Text(
      person.initials,
      style: TextStyle(color: _on(color), fontWeight: FontWeight.w700, fontSize: size * 0.36),
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final GodViewStatus status;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = godViewStatusColor(status, t.brightness);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(6)),
      child: Text(status.label, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts({required this.rows});
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(children: [
      for (final (k, v) in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 80, child: Text(k, style: TextStyle(color: muted))),
            Expanded(child: Text(v)),
          ]),
        ),
    ]);
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({super.key, required this.icon, required this.label, required this.onPressed});
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) =>
      OutlinedButton.icon(onPressed: onPressed, icon: Icon(icon, size: 18), label: Text(label));
}

// ---- Suspend and Send push --------------------------------------------------------------------

/// The reason picked and the admin's note.
typedef _SuspendAnswer = ({String reason, String note});

class _SuspendDialog extends StatefulWidget {
  const _SuspendDialog({required this.person, required this.onTrip});
  final GodViewPerson person;
  final bool onTrip;

  @override
  State<_SuspendDialog> createState() => _SuspendDialogState();
}

class _SuspendDialogState extends State<_SuspendDialog> {
  String? _reason;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.person;
    final t = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('god-view-suspend-dialog'),
      title: Text('Suspend ${p.displayName}?'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(
              p.isPartner
                  ? 'They are blocked as on the Partners page: taken offline and sent no new requests. The reason is shown to them.'
                  : 'They are blocked as on the Users page.',
            ),
            if (widget.onTrip) ...[
              const SizedBox(height: 10),
              Container(
                key: const ValueKey('god-view-suspend-on-trip'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: t.colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'On a trip: they can finish this one.',
                  style: TextStyle(color: t.colorScheme.onTertiaryContainer, fontWeight: FontWeight.w600),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text('Reason', style: t.textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final r in godViewSuspendReasons)
                ChoiceChip(
                  key: ValueKey('god-view-reason-$r'),
                  label: Text(r),
                  selected: _reason == r,
                  onSelected: (_) => setState(() => _reason = r),
                ),
            ]),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('god-view-suspend-note'),
              controller: _note,
              maxLines: 2,
              maxLength: 300,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('god-view-suspend-confirm'),
          style: FilledButton.styleFrom(backgroundColor: t.colorScheme.error, foregroundColor: t.colorScheme.onError),
          onPressed: _reason == null ? null : () => Navigator.pop(context, (reason: _reason!, note: _note.text)),
          child: const Text('Suspend'),
        ),
      ],
    );
  }
}

class _PushSheet extends ConsumerStatefulWidget {
  const _PushSheet({required this.person});
  final GodViewPerson person;

  @override
  ConsumerState<_PushSheet> createState() => _PushSheetState();
}

class _PushSheetState extends ConsumerState<_PushSheet> {
  final _title = TextEditingController();
  final _body = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ready = _title.text.trim().isNotEmpty && _body.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Send push to ${widget.person.displayName}', style: t.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Only this person gets it. It is kept in the push history.',
          style: TextStyle(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('god-view-push-title'),
          controller: _title,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Title'),
          onChanged: (_) => setState(() {}),
        ),
        TextField(
          key: const ValueKey('god-view-push-body'),
          controller: _body,
          maxLines: 3,
          maxLength: 300,
          decoration: const InputDecoration(labelText: 'Message'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        BusyButton.filled(
          key: const ValueKey('god-view-push-send'),
          onPressed: !ready
              ? null
              : () async {
                  final ok = await runAdminAction(
                    context,
                    () => ref
                        .read(godViewRepositoryProvider)
                        .sendPush(widget.person.id, _title.text.trim(), _body.text.trim()),
                    success: 'Sent to ${widget.person.displayName}',
                  );
                  if (ok && context.mounted) Navigator.pop(context);
                },
          child: const Text('Send'),
        ),
      ]),
    );
  }
}

// ---- "Still there?" and the settings (migration 0276) -------------------------------------------

/// "Ping now" and the line saying how it went.
/// "Show address" as the rider app shows a place (smart address A): its
/// name, and under it only its area; the full address on hover or a long
/// press.
class _SmartAddressText extends StatelessWidget {
  const _SmartAddressText({required this.place, required this.fallback});
  final Place? place;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final p = place;
    if (p == null) return Text(fallback, key: const ValueKey('god-view-address'));
    final t = Theme.of(context);
    final name = p.name.trim().isEmpty ? shortArea(p) : p.name.trim();
    final area = placeAreaLine(p, clean: true);
    return Tooltip(
      message: p.address,
      child: Row(key: const ValueKey('god-view-address'), crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(placeIcon(p), size: 18, color: t.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (area != null) Text(area, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }
}

class _PingRow extends StatelessWidget {
  const _PingRow({required this.stage, required this.at, required this.onPing, this.blocked});
  final GodViewPingStage? stage;

  /// Why the ping can't be sent now (the phone reports live); null when it can.
  final String? blocked;
  final DateTime? at;
  final VoidCallback onPing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final busy = stage == GodViewPingStage.sending || stage == GodViewPingStage.waiting;
    final s = stage;
    final color = switch (s) {
      GodViewPingStage.answered => godViewStatusColor(GodViewStatus.free, t.brightness),
      GodViewPingStage.failed => t.colorScheme.error,
      _ => t.colorScheme.onSurfaceVariant,
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        OutlinedButton.icon(
          key: const ValueKey('god-view-ping'),
          onPressed: busy || blocked != null ? null : onPing,
          icon: busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.my_location_outlined, size: 18),
          label: const Text('Ping now'),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            blocked ?? 'Asks their phone where it is.',
            key: const ValueKey('god-view-ping-note'),
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
      ]),
      if (s != null) ...[
        const SizedBox(height: 6),
        Text(godViewPingLine(s, at: at), key: const ValueKey('god-view-ping-line'), style: TextStyle(color: color)),
      ],
    ]);
  }
}

/// Admin → God View → Settings: the "Still there?" pings and how long a
/// quiet Always on phone stays Always on. A full admin changes them; anyone
/// else with God View sees them.
class _SettingsSheet extends ConsumerStatefulWidget {
  const _SettingsSheet({required this.settings});
  final GodViewSettings settings;

  @override
  ConsumerState<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<_SettingsSheet> {
  late GodViewSettings _s = widget.settings;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = TextStyle(color: t.colorScheme.onSurfaceVariant);
    final edit = widget.settings.editable;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('God View settings', style: t.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('For phones with location set to always. They report when they move; these keep them on the map while they stay put.', style: muted),
        if (!edit) ...[
          const SizedBox(height: 8),
          Text('Only a full admin can change these.', key: const ValueKey('god-view-settings-readonly'), style: muted),
        ],
        const SizedBox(height: 8),
        SwitchListTile(
          key: const ValueKey('god-view-settings-pings'),
          contentPadding: EdgeInsets.zero,
          title: const Text('"Still there?" pings'),
          subtitle: const Text('A silent push asks a quiet phone where it is.'),
          value: _s.pings,
          onChanged: edit ? (v) => setState(() => _s = _s.copyWith(pings: v)) : null,
        ),
        const SizedBox(height: 4),
        Text('Ping a phone quiet for ${godViewMinutesLabel(_s.pingMinutes)}', style: t.textTheme.titleSmall),
        Slider(
          key: const ValueKey('god-view-settings-minutes'),
          value: _s.pingMinutes.toDouble(),
          min: GodViewSettings.minPingMinutes.toDouble(),
          max: GodViewSettings.maxPingMinutes.toDouble(),
          divisions: (GodViewSettings.maxPingMinutes - GodViewSettings.minPingMinutes) ~/ 5,
          label: godViewMinutesLabel(_s.pingMinutes),
          onChanged: edit && _s.pings ? (v) => setState(() => _s = _s.copyWith(pingMinutes: v.round())) : null,
        ),
        Text('Each phone at most this often. iPhones limit silent pushes, so a short time may be skipped.', style: muted),
        const SizedBox(height: 12),
        Text('Always on for ${_s.alwaysOnHours} h after the last report', style: t.textTheme.titleSmall),
        Slider(
          key: const ValueKey('god-view-settings-hours'),
          value: _s.alwaysOnHours.toDouble(),
          min: GodViewSettings.minAlwaysOnHours.toDouble(),
          max: GodViewSettings.maxAlwaysOnHours.toDouble(),
          divisions: GodViewSettings.maxAlwaysOnHours - GodViewSettings.minAlwaysOnHours,
          label: '${_s.alwaysOnHours} h',
          onChanged: edit ? (v) => setState(() => _s = _s.copyWith(alwaysOnHours: v.round())) : null,
        ),
        Text('After that the phone shows as Last known.', style: muted),
        const SizedBox(height: 16),
        if (edit)
          BusyButton.filled(
            key: const ValueKey('god-view-settings-save'),
            onPressed: () async {
              GodViewSettings? saved;
              final ok = await runAdminAction(
                context,
                () async => saved = await ref.read(godViewRepositoryProvider).saveSettings(_s),
                success: 'God View settings saved',
              );
              if (ok && context.mounted) Navigator.pop(context, saved);
            },
            child: const Text('Save'),
          )
        else
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ]),
    );
  }
}
