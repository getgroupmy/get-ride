import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/airport_areas.dart';
import '../../core/format.dart';
import '../../core/place_gates.dart';
import '../../core/smart_address.dart';
import '../../data/app_display_repository.dart';
import '../../data/geo_service.dart';
import '../../data/place_gates_repository.dart';
import '../../core/saved_places.dart';
import '../../data/saved_places_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart' show mutedTextColor;
import '../../widgets/map_pick_icon.dart';
import 'map_place_picker.dart';
import 'saved_place_form.dart';
import '../../widgets/page_style_host.dart';

/// Result of the place picker: either a concrete place or a request to drop
/// a pin on the map.
class PlacePick {
  const PlacePick.place(Place this.place, {this.entrance = '', this.from = false}) : pickOnMap = false;
  const PlacePick.onMap({this.from = false}) : place = null, entrance = '', pickOnMap = true;
  final Place? place;
  final bool pickOnMap;

  /// A saved place's entrance ("Gate B"); empty for none.
  final String entrance;

  /// The rider changed the trip's start ("From") instead of its end.
  final bool from;

  PlacePick _asFrom() =>
      pickOnMap ? const PlacePick.onMap(from: true) : PlacePick.place(place!, entrance: entrance, from: true);
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
  Place? to,
  bool routeEnds = false,
  bool startOnFrom = false,
  PlaceSearchMode mode = PlaceSearchMode.route,
  ValueListenable<RouteSheetEnds>? live,
}) {
  final wide = MediaQuery.sizeOf(context).width >= 720;
  final body = _PlaceSearch(
    title: title,
    near: near,
    current: current,
    usage: usage,
    from: from,
    to: to,
    routeEnds: routeEnds,
    startOnFrom: startOnFrom,
    mode: mode,
    live: live,
  );
  if (wide) {
    return showAppDialog<PlacePick>(id: 'place-search.show-place-search',
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680), child: body),
      ),
    );
  }
  return showAppSheet<PlacePick>(id: 'place-search.show-place-search-2',
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // inDrive's: the whole screen under the status bar, plain (white by
    // day), no handle.
    showDragHandle: false,
    backgroundColor: routeSheetBackground(Theme.of(context)),
    builder: (c) => Theme(data: routeSheetTheme(Theme.of(c)), child: body),
  );
}

/// The pickup and the rider's current place as the home screen has them
/// now: an open route sheet follows them (an address that arrives after it
/// opened fills its From and its Current location row).
typedef RouteSheetEnds = ({Place? from, Place? current});

/// The Current location row's second line: the short label the From row
/// shows, then the full address when it says more.
String currentPlaceSubtitle(Place p) {
  final name = p.name.trim(), address = p.address.trim();
  if (name.isEmpty || isCoordinateLabel(name)) return address;
  if (address.isEmpty || address == name) return name;
  return '$name\n$address';
}

/// The route sheet's page: white by day.
Color routeSheetBackground(ThemeData t) => t.brightness == Brightness.dark ? t.colorScheme.surface : Colors.white;

/// The route sheet's theme: inDrive's text, with no letter spacing (the
/// app's Material text spreads its letters out).
ThemeData routeSheetTheme(ThemeData t) {
  TextStyle? tight(TextStyle? s) => s?.copyWith(letterSpacing: 0);
  final x = t.textTheme;
  return t.copyWith(
    textTheme: x.copyWith(
      displayLarge: tight(x.displayLarge),
      displayMedium: tight(x.displayMedium),
      displaySmall: tight(x.displaySmall),
      headlineLarge: tight(x.headlineLarge),
      headlineMedium: tight(x.headlineMedium),
      headlineSmall: tight(x.headlineSmall),
      titleLarge: tight(x.titleLarge),
      titleMedium: tight(x.titleMedium),
      titleSmall: tight(x.titleSmall),
      bodyLarge: tight(x.bodyLarge),
      bodyMedium: tight(x.bodyMedium),
      bodySmall: tight(x.bodySmall),
      labelLarge: tight(x.labelLarge),
      labelMedium: tight(x.labelMedium),
      labelSmall: tight(x.labelSmall),
    ),
  );
}

class _PlaceSearch extends ConsumerStatefulWidget {
  const _PlaceSearch({
    required this.title,
    this.near,
    this.current,
    this.usage,
    this.from,
    this.to,
    this.routeEnds = false,
    this.startOnFrom = false,
    this.mode = PlaceSearchMode.route,
    this.live,
  });
  final String title;
  final LatLng? near;
  final Place? current;

  /// Whether this is a pickup or a drop-off, so only gates open for it show.
  final GateUsage? usage;

  /// Where the trip starts, shown above the field ("From").
  final Place? from;

  /// Where it ends so far, shown under the From field while that is searched.
  final Place? to;

  /// Both ends of the trip shown, From over To, even with neither set yet
  /// (the home screen's route sheet).
  final bool routeEnds;

  /// Search the From (the pickup) first rather than the To.
  final bool startOnFrom;
  final PlaceSearchMode mode;

  /// Later values of [from] and [current], while the sheet is open.
  final ValueListenable<RouteSheetEnds>? live;

  @override
  ConsumerState<_PlaceSearch> createState() => _PlaceSearchState();
}

class _PlaceSearchState extends ConsumerState<_PlaceSearch> {
  /// The From and the current place: as the sheet opened, or newer from
  /// [_PlaceSearch.live] once they arrive (the reverse-geocoded address).
  Place? get _from => widget.live?.value.from ?? widget.from;
  Place? get _current => widget.live?.value.current ?? widget.current;

  void _liveChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.live?.addListener(_liveChanged);
  }

  @override
  void didUpdateWidget(covariant _PlaceSearch old) {
    super.didUpdateWidget(old);
    if (old.live != widget.live) {
      old.live?.removeListener(_liveChanged);
      widget.live?.addListener(_liveChanged);
    }
  }

  final _query = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  List<Place> _results = [];
  bool _loading = false;

  /// Each result's road distance from where the user is (Admin → Settings →
  /// Maps → distance), by [_at] or a suggestion's place id; arrives after
  /// the results.
  Map<String, double> _km = const {};
  int _asked = 0;

  /// A picked suggestion being looked up, or a picked address checked.
  bool _picking = false;

  static String _at(LatLng p) => '${p.latitude},${p.longitude}';

  /// Search Results (while typing), Suggested (current place, recent) or Saved.
  _Tab _tab = _Tab.suggested;

  bool get _route => widget.mode == PlaceSearchMode.route;

  /// Changing the trip's start ("From", tapped) instead of its end.
  late bool _editFrom = widget.startOnFrom && _ends;

  /// From over To, as the route sheet shows them.
  bool get _ends => _route && (widget.routeEnds || _from != null);

  GateUsage? get _usage => _editFrom ? GateUsage.pickup : widget.usage;

  /// Closes with [p], marked as the new start when the rider is changing it.
  void _done(PlacePick p) => Navigator.pop(context, _editFrom ? p._asFrom() : p);

  /// Back to searching the trip's end (the To row tapped).
  void _changeTo() {
    _debounce?.cancel();
    _query.clear();
    _asked++;
    setState(() {
      _editFrom = false;
      _results = [];
      _km = const {};
      _tab = _Tab.suggested;
    });
    _focus.requestFocus();
  }

  /// The search field: outlined, a search icon, its label (From, To or
  /// Address) small over the text, a clear button while there is text, and
  /// the choose-on-map button (inDrive's, 58 high).
  /// The search field's caption: what it is for.
  String get _fieldLabel => _editFrom
      ? 'From'
      : _route
      ? 'To'
      : 'Address';

  Widget _field(ThemeData t) {
    final muted = mutedTextColor(t, background: t.colorScheme.surface);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        constraints: const BoxConstraints(minHeight: 58),
        decoration: BoxDecoration(
          color: t.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.colorScheme.onSurface, width: 2),
        ),
        padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
        child: Row(
          children: [
            Icon(Icons.search, size: 26, color: t.colorScheme.onSurface),
            const SizedBox(width: 12),
            // The field fills the box's height, its caption laid over its
            // top: the whole row is the field to tap (it was a 24 high
            // strip under the caption, too small a target).
            Expanded(
              child: Stack(
                children: [
                  TextField(
                    key: const ValueKey('place-search-field'),
                    controller: _query,
                    focusNode: _focus,
                    autofocus: true,
                    style: t.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w400, height: 1.3),
                    decoration: const InputDecoration.collapsed(hintText: null).copyWith(
                      isDense: true,
                      contentPadding: const EdgeInsets.only(top: 25, bottom: 7),
                    ),
                    onChanged: _onChanged,
                  ),
                  PositionedDirectional(
                    start: 0,
                    top: 7,
                    child: IgnorePointer(
                      child: Text(
                        _fieldLabel,
                        style: t.textTheme.bodySmall?.copyWith(fontSize: 13, height: 1.2, color: muted),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_loading || _picking)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_query.text.isNotEmpty)
              IconButton(
                key: const ValueKey('place-search-clear'),
                tooltip: 'Clear',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.cancel, size: 22, color: muted.withValues(alpha: 0.6)),
                onPressed: () {
                  _query.clear();
                  _onChanged('');
                },
              ),
            // Choose the spot on the map instead.
            Tooltip(
              message: 'Choose on map',
              child: InkWell(
                key: const ValueKey('place-search-map'),
                borderRadius: BorderRadius.circular(10),
                onTap: _onMap,
                child: const MapPickIcon(size: 44),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The end of the trip not being searched: its icon and place (or its
  /// name greyed), tapped to search it instead.
  Widget _endRow(
    ThemeData t, {
    required Key key,
    required IconData icon,
    required String label,
    required String? value,
    required VoidCallback onTap,
  }) {
    final has = value != null && value.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: _fill(t),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 58),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  Icon(icon, size: 26, color: t.colorScheme.onSurface),
                  const SizedBox(width: 12),
                  Expanded(
                    child: has
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                label,
                                style: t.textTheme.bodySmall?.copyWith(
                                  fontSize: 13,
                                  height: 1.2,
                                  color: mutedTextColor(t, background: _fill(t)),
                                ),
                              ),
                              Text(
                                value,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w400),
                              ),
                            ],
                          )
                        : Text(
                            label,
                            style: t.textTheme.titleMedium?.copyWith(
                              fontSize: 17,
                              fontWeight: FontWeight.w400,
                              color: mutedTextColor(t, background: _fill(t)),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _changeFrom() {
    _debounce?.cancel();
    _query.clear();
    _asked++;
    setState(() {
      _editFrom = true;
      _results = [];
      _km = const {};
      _tab = _Tab.suggested;
    });
    _focus.requestFocus();
  }

  @override
  void dispose() {
    widget.live?.removeListener(_liveChanged);
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    // Typing shows the results; clearing goes back to the suggestions.
    setState(() {
      if (q.trim().isNotEmpty) {
        _tab = _Tab.results;
      } else if (_tab == _Tab.results) {
        _tab = _Tab.suggested;
      }
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      setState(() => _loading = true);
      try {
        final r = await ref.read(geoServiceProvider).search(q, near: widget.near);
        if (mounted) setState(() => _results = r);
        _measure(r);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  /// The results' distances from [_PlaceSearch.near], up to ten, without
  /// holding the list back; a newer search's results replace them.
  Future<void> _measure(List<Place> places) async {
    final ask = ++_asked;
    final from = widget.near;
    if (mounted) setState(() => _km = const {});
    if (from == null || places.isEmpty) return;
    final geo = ref.read(geoServiceProvider);
    final to = places.where((p) => !p.pending).take(10).map((p) => p.point).toList();
    if (to.isNotEmpty) {
      final km = await geo.distances(from, to);
      if (!mounted || ask != _asked) return;
      setState(
        () => _km = {
          for (var i = 0; i < to.length && i < km.length; i++)
            if (km[i] != null) _at(to[i]): km[i]!,
        },
      );
    }
    // Autocomplete's suggestions have no position yet: found roughly on
    // OpenStreetMap, then measured by road like the rest. Google's own
    // straight-line distance stands in until then, and where OSM can't.
    final pending = places.where((p) => p.pending).take(5).toList();
    if (pending.isEmpty) return;
    final rough = await geo.roughPoints(pending, near: from, stillWanted: () => mounted && ask == _asked);
    if (!mounted || ask != _asked) return;
    final found = [
      for (var i = 0; i < rough.length; i++)
        if (rough[i] != null) (id: pending[i].placeId!, at: rough[i]!),
    ];
    if (found.isEmpty) return;
    final km = await geo.distances(from, [for (final f in found) f.at]);
    if (!mounted || ask != _asked) return;
    setState(
      () => _km = {
        ..._km,
        for (var i = 0; i < found.length && i < km.length; i++)
          if (km[i] != null) found[i].id: km[i]!,
      },
    );
  }

  /// The map picker (inDrive's): the place chosen there, handed straight back.
  Future<void> _onMap() async {
    final p = await pickPlaceOnMap(context, start: _current?.point ?? widget.near, me: widget.near);
    if (p != null && mounted) _done(PlacePick.place(p));
  }

  Future<void> _add(SavedPlaceKind kind) => addSavedPlace(context, kind, near: widget.near);

  /// A search result, with the admin's gates under it when it is a
  /// multi-gate place (Expo `PlaceGatesList`). Where the place requires a
  /// gate, the place itself can't be picked — only one of its gates.
  Widget _result(Place p, GateCatalogue? catalogue, SmartAddress smart) {
    final gated = catalogue == null || p.pending
        ? null
        : matchGatedPlace(
            places: catalogue.places,
            gates: catalogue.gates,
            point: p.point,
            name: p.name,
            usage: _usage,
          );
    final gates = gated?.gates ?? const <GateOption>[];
    final blocked = gated?.blocksPlace ?? false;
    final km = p.pending ? _km[p.placeId] ?? p.km : _km[_at(p.point)];
    final t = Theme.of(context);
    final muted = mutedTextColor(t, background: routeSheetBackground(t));
    // A pin, or what the place is (smart address A) where that says more.
    final typed = smart.clean ? placeIcon(p) : null;
    final icon = gates.isNotEmpty
        ? Icons.door_front_door_outlined
        : typed == null || typed == Icons.place_outlined || typed == Icons.home_outlined
        ? Icons.location_on_outlined
        : typed;
    final saved = _savedAt(p);
    return InkWell(
      // Suggestions have no position yet: each by Google's id, so no two share a key.
      key: ValueKey('result-${_id(p)}'),
      onTap: blocked || _picking ? null : () => _pick(p, catalogue, smart),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 16),
              child: Icon(icon, size: 24, color: muted),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    _highlighted(p.name, _query.text, t),
                    maxLines: smart.clean ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    smart.clean ? shortArea(p, homeRegion: areaRegion(_current)) : p.address,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.bodyMedium?.copyWith(color: muted, fontSize: 15),
                  ),
                  if (gates.isNotEmpty) ...[
                    if (blocked)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('Choose a gate', style: t.textTheme.labelMedium),
                      ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final g in gates)
                          ActionChip(
                            key: ValueKey('gate-${g.id}'),
                            avatar: const Icon(Icons.door_front_door_outlined, size: 16),
                            label: Text(g.name),
                            onPressed: () => _done(PlacePick.place(gatePlace(p, gated!, g))),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            // The distance from here, then save it (Grab's and inDrive's
            // right-hand side).
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 8),
              child: SizedBox(
                width: 60,
                child: km == null
                    ? null
                    : Text(
                        placeDistanceLabel(km),
                        key: ValueKey('result-km-${_id(p)}'),
                        maxLines: 1,
                        textAlign: TextAlign.right,
                        style: t.textTheme.bodyMedium?.copyWith(fontSize: 15, color: muted),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: IconButton.filledTonal(
                key: ValueKey('result-save-${_id(p)}'),
                tooltip: saved == null ? 'Save place' : 'Saved',
                style: _roundButton(t),
                icon: Icon(saved == null ? Icons.bookmark_border : Icons.bookmark, size: 20),
                onPressed: _picking ? null : () => _savePlace(p, saved),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A result's key part: Google's id for a suggestion (no position yet, so
  /// no two share one), else its position.
  static String _id(Place p) => p.pending ? '${p.placeId}' : '${p.point.latitude},${p.point.longitude}';

  /// [text] with each word of [query] in it in the accent colour (what was
  /// typed, as found).
  static TextSpan _highlighted(String text, String query, ThemeData t) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return TextSpan(text: text);
    final lower = text.toLowerCase();
    final hit = List<bool>.filled(text.length, false);
    for (final w in words) {
      for (var i = lower.indexOf(w); i >= 0; i = lower.indexOf(w, i + w.length)) {
        for (var j = i; j < i + w.length && j < hit.length; j++) {
          hit[j] = true;
        }
      }
    }
    final accent = TextStyle(
      color: t.brightness == Brightness.dark ? const Color(0xFF8AB4FF) : const Color(0xFF3D5AFE),
    );
    final spans = <TextSpan>[];
    var start = 0;
    for (var i = 1; i <= text.length; i++) {
      if (i == text.length || hit[i] != hit[start]) {
        spans.add(TextSpan(text: text.substring(start, i), style: hit[start] ? accent : null));
        start = i;
      }
    }
    return TextSpan(children: spans);
  }

  /// The rider's saved place at [p] (within 100 m), if there is one.
  SavedPlace? _savedAt(Place p) {
    if (p.pending) return null;
    for (final s in ref.watch(savedPlacesProvider).value ?? const <SavedPlace>[]) {
      if (const Distance().as(LengthUnit.Meter, s.point, p.point) < 100) return s;
    }
    return null;
  }

  /// The bookmark: [p] saved as one of the rider's places (looked up first
  /// when it is a suggestion), or the saved one opened.
  Future<void> _savePlace(Place p, SavedPlace? saved) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (ref.read(currentUserIdProvider) == null) {
      messenger?.showSnackBar(const SnackBar(content: Text('Sign in to save your places')));
      return;
    }
    if (saved != null) {
      await showSavedPlaceForm(context, saved, near: widget.near);
      return;
    }
    var place = p;
    if (p.pending) {
      setState(() => _picking = true);
      try {
        place = await ref.read(geoServiceProvider).resolve(p) ?? p;
      } finally {
        if (mounted) setState(() => _picking = false);
      }
      if (place.pending) {
        messenger?.showSnackBar(const SnackBar(content: Text("Couldn't find that place. Try another.")));
        return;
      }
    }
    if (!mounted) return;
    await showSavedPlaceForm(
      context,
      SavedPlace(
        kind: SavedPlaceKind.other,
        name: place.name,
        address: place.address.isEmpty ? place.name : place.address,
        point: place.point,
      ),
      near: widget.near,
    );
  }

  /// A result picked: an Autocomplete suggestion looked up first (shown
  /// again with its gates when it turns out to have some), a street
  /// address checked by Google with smart address C, then handed back.
  Future<void> _pick(Place p, GateCatalogue? catalogue, SmartAddress smart) async {
    final geo = ref.read(geoServiceProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _picking = true);
    try {
      var place = await geo.resolve(p);
      if (!mounted) return;
      if (place == null) {
        messenger?.showSnackBar(const SnackBar(content: Text("Couldn't find that place. Try another.")));
        return;
      }
      if (p.pending && catalogue != null) {
        final gated = matchGatedPlace(
          places: catalogue.places,
          gates: catalogue.gates,
          point: place.point,
          name: place.name,
          usage: _usage,
        );
        if (gated != null && gated.gates.isNotEmpty) {
          // Choose its gate from the list, as for any gated place.
          final looked = place;
          setState(() => _results = [for (final r in _results) identical(r, p) ? looked : r]);
          _measure(_results);
          return;
        }
      }
      if (smart.check && isStreetAddress(place)) place = await geo.checkAddress(place);
      if (!mounted) return;
      _done(PlacePick.place(place));
      if (place.verified) {
        messenger?.showSnackBar(
          SnackBar(
            key: const ValueKey('place-verified'),
            // No ✓ on the web: the browser would fetch a symbol font for it.
            content: Text('${kIsWeb ? '' : '✓ '}Address confirmed by Google: ${place.address}'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Option B: the rider's saved and recent places that match on top, then
  /// named places, then street addresses under their own heading.
  List<Widget> _placesFirst(ThemeData t, List<Place> shown, GateCatalogue? catalogue, SmartAddress smart) {
    final rows = placesFirst(
      _query.text,
      shown,
      saved: ref.watch(savedPlacesProvider).value ?? const [],
      recent: ref.watch(recentPlacesProvider).value ?? const [],
    );
    return [
      for (final r in rows.top)
        if (r.saved case final s?)
          ListTile(
            key: ValueKey('smart-saved-${s.id}'),
            leading: const Icon(Icons.star_rounded),
            title: Text('Saved: ${s.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(s.address, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => _done(PlacePick.place(savedPlaceAsPlace(s), entrance: s.entrance)),
          )
        else if (r.recent)
          ListTile(
            key: ValueKey('smart-recent-${r.place!.point.latitude},${r.place!.point.longitude}'),
            leading: const Icon(Icons.history),
            title: Text('Recent: ${r.place!.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              smart.clean ? shortArea(r.place!, homeRegion: areaRegion(_current)) : r.place!.address,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _done(PlacePick.place(r.place!)),
          )
        else
          _result(r.place!, catalogue, smart),
      if (rows.addresses.isNotEmpty)
        Padding(
          key: const ValueKey('smart-addresses'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('Addresses', style: t.textTheme.labelMedium),
              ),
              const Expanded(child: Divider()),
            ],
          ),
        ),
      for (final p in rows.addresses) _result(p, catalogue, smart),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final catalogue = ref.watch(placeGatesProvider).value;
    final typing = _query.text.trim().isNotEmpty;
    final smart = ref.watch(geoServiceProvider).smartAddress;
    return Column(
      children: [
        // The title in the middle, a round close on the right (inDrive's).
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 12, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: t.textTheme.titleLarge?.copyWith(fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                key: const ValueKey('place-search-close'),
                tooltip: 'Close',
                style: _roundButton(t),
                icon: const Icon(Icons.close, size: 22),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        // inDrive's route sheet: From over To, the one being searched an
        // outlined field, the other a row that is tapped to search it.
        if (_ends && _editFrom)
          _field(t)
        else if (_ends)
          _endRow(
            t,
            key: const ValueKey('place-search-from'),
            icon: Icons.emoji_people,
            label: 'From',
            value: _from?.name,
            onTap: _changeFrom,
          ),
        if (_ends) const SizedBox(height: 12),
        if (_editFrom)
          _endRow(
            t,
            key: const ValueKey('place-search-to'),
            icon: Icons.flag,
            label: 'To',
            value: widget.to?.name,
            onTap: _changeTo,
          )
        else
          _field(t),
        // The tabs' 44 high targets take 5 above and below their pills.
        SizedBox(height: _route ? 17 : 22),
        if (_route)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            // From the left, as inDrive's.
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: SingleChildScrollView(
                key: const ValueKey('place-tabs'),
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final tab in [if (typing) _Tab.results, _Tab.suggested, _Tab.saved]) ...[
                      _Pill(
                        key: ValueKey('place-tab-${tab.name}'),
                        label: tab.label,
                        on: _tab == tab,
                        onTap: () => setState(() => _tab = tab),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: ListView(
            children: [
              if (_route && _tab == _Tab.saved) ..._savedList(t),
              if (_route && _tab == _Tab.suggested) ..._suggested(t),
              // An address for a saved place, before typing: the map, and
              // the places already been to.
              if (!_route && !typing) ...[
                ListTile(
                  key: const ValueKey('place-search-map-row'),
                  leading: const Icon(Icons.map_outlined),
                  title: const Text('Choose on map'),
                  onTap: _onMap,
                ),
                ..._suggested(t),
              ],
              if (typing && (!_route || _tab == _Tab.results))
                ...() {
                  final shown = collapseAirports<Place>(
                    _results,
                    ref.watch(airportAreasProvider).value ?? const [],
                    point: (p) => p.point,
                    text: (p) => '${p.name} ${p.address}',
                    airport: (a) => Place(
                      name: a.name,
                      address: a.code.isEmpty ? 'Airport' : '${a.code} · Airport',
                      point: a.centroid,
                      types: const ['airport'],
                    ),
                  );
                  return smart.placesFirst
                      ? _placesFirst(t, shown, catalogue, smart)
                      : [for (final p in shown) _result(p, catalogue, smart)];
                }(),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _suggested(ThemeData t) => [
    if (_current != null)
      ListTile(
        leading: const Icon(Icons.my_location),
        key: const ValueKey('place-search-current'),
        title: const Text('Current location'),
        // The same short label as the From row, the full address under it.
        // Bare coordinates until the address arrives say nothing to a rider.
        subtitle: isCoordinateLabel(_current!.address)
            ? null
            : Text(
                currentPlaceSubtitle(_current!),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
        onTap: () => _done(PlacePick.place(_current!)),
      ),
    // Choosing on the map is the pin button in the search field.
    ...switch (ref.watch(recentPlacesProvider).value ?? const <Place>[]) {
      final List<Place> recent when recent.isNotEmpty => [
        if (_current != null) const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text('Recent', style: t.textTheme.titleSmall),
        ),
        for (final p in recent)
          ListTile(
            key: ValueKey('recent-${p.point.latitude},${p.point.longitude}'),
            leading: const Icon(Icons.history),
            title: Text(p.name),
            // None when it would only repeat the name.
            subtitle: switch (placeSubtitle(p.name, p.address)) {
              final a? => Text(a, maxLines: 1, overflow: TextOverflow.ellipsis),
              null => null,
            },
            onTap: () => _done(PlacePick.place(p)),
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
    final muted = mutedTextColor(t, background: routeSheetBackground(t));
    final titleStyle = t.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w500);
    // The same row as a search result: icon, name over address, distance,
    // and a round button (here: edit).
    Widget saved(SavedPlace p, IconData icon) => InkWell(
      key: ValueKey('saved-${p.kind.name}-${p.id}'),
      onTap: () => _done(PlacePick.place(savedPlaceAsPlace(p), entrance: p.entrance)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Icon(icon, size: 24, color: muted),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
                  const SizedBox(height: 2),
                  Text(
                    [savedPlaceLine(p), if (p.entrance.isNotEmpty) p.entrance].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.bodyMedium?.copyWith(color: muted, fontSize: 15),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                savedPlaceDistance(widget.near, p.point),
                style: t.textTheme.bodyMedium?.copyWith(fontSize: 15, color: muted),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: IconButton.filledTonal(
                key: ValueKey('saved-edit-${p.id}'),
                tooltip: 'Edit',
                style: _roundButton(t),
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: () => showSavedPlaceForm(context, p, near: widget.near),
              ),
            ),
          ],
        ),
      ),
    );
    Widget add(String label, IconData icon, SavedPlaceKind kind, Key key) => InkWell(
      key: key,
      onTap: () => _add(kind),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Icon(icon, size: 24, color: muted),
            ),
            Expanded(child: Text(label, style: titleStyle)),
            Icon(Icons.chevron_right, color: muted),
          ],
        ),
      ),
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

/// The sheet's tabs: what was found, the suggestions, the saved places.
enum _Tab {
  results('Search Results'),
  suggested('Suggested'),
  saved('Saved');

  const _Tab(this.label);
  final String label;
}

/// A tab: black when on, grey when off (inDrive's).
class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // The pill stays 34 high; the target around it is 44 (a finger).
    return Semantics(
      container: true,
      button: true,
      selected: on,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Center(
            widthFactor: 1,
            child: Material(
              color: on ? t.colorScheme.onSurface : _fill(t),
              shape: const StadiumBorder(),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    label,
                    style: t.textTheme.titleMedium?.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      height: 1.2,
                      color: on ? t.colorScheme.surface : t.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The sheet's grey: the From box, the off tabs and the round buttons
/// (inDrive's light grey by day, a lifted grey at night).
Color _fill(ThemeData t) => routeSheetFill(t);

/// The route sheet's warm grey, for the forms opened from it too.
Color routeSheetFill(ThemeData t) =>
    t.brightness == Brightness.dark ? const Color(0xFF2C2D30) : const Color(0xFFF2F1EE);

/// A 36 round grey button with a dark icon: close, save, edit. It is tapped
/// anywhere in the 48 around it.
ButtonStyle _roundButton(ThemeData t) => routeSheetRoundButton(t);

/// [_roundButton], for the forms opened from the route sheet.
ButtonStyle routeSheetRoundButton(ThemeData t) => IconButton.styleFrom(
  backgroundColor: _fill(t),
  foregroundColor: t.colorScheme.onSurface,
  fixedSize: const Size.square(36),
  minimumSize: const Size.square(36),
  padding: EdgeInsets.zero,
  tapTargetSize: MaterialTapTargetSize.padded,
);
