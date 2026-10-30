// myGiG: the driver enters the trip (as the street-hail destination screen,
// hail_destination_screen.dart): the pickup starts at where the driver is
// and can be changed, the drop-off is searched or tapped on the map, up to
// four stops, a round trip, passengers and luggage by size. The server
// prices it (mygig_quote); the passenger's phone is checked as it is typed
// (mygig_lookup_phone); then the fare goes to the passenger the way the
// driver picks (mygig_create).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/mygig.dart';
import '../../core/mygig_extras.dart' show MygigPlace, MygigRegular, mygigSamePlace;
import '../../core/mygig_hire.dart';
import '../../data/geo_service.dart';
import '../../data/mygig_repository.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/ride_map.dart';
import '../partner/partner_trip_screen.dart' show tripFixProvider;
import '../ride/place_search.dart';
import 'mygig_entry.dart';
import 'mygig_waiting_screen.dart';
import 'mygig_when.dart';

/// A place on a myGiG trip.
class MygigStop {
  const MygigStop({required this.name, this.address, required this.at, this.here = false});
  final String name;
  final String? address;
  final LatLng at;

  /// The driver's current location (the pickup when nothing else is set).
  final bool here;

  Map<String, dynamic> toJson() => {
    'lat': at.latitude,
    'lng': at.longitude,
    'name': name,
    if (address != null && address != name) 'address': address,
    'here': here,
  };
}

/// What the screen sends as the trip.
Map<String, dynamic> mygigTripJson({
  required MygigStop pickup,
  required MygigStop drop,
  List<MygigStop> stops = const [],
  bool round = false,
  double? km,
  double? minutes,
  int pax = 1,
  Map<String, int> bags = const {},
  double approachKm = 0,
  bool waive = false,
  MygigPay pay = MygigPay.cash,
  String? businessId,
}) => {
  'pickup': pickup.toJson(),
  'drop': drop.toJson()..remove('here'),
  'stops': [for (final s in stops) s.toJson()..remove('here')],
  'round': round,
  'km': ?km,
  'min': ?minutes,
  'pax': pax,
  'bags': {for (final s in const ['small', 'medium', 'large']) s: bags[s] ?? 0},
  'approachKm': approachKm,
  'waiveApproach': waive,
  'pay': pay.name,
  'businessId': ?businessId,
};

/// Why the fare can't be sent yet, or null.
String? mygigSendProblem({
  required MygigQuote? quote,
  required MygigLookup lookup,
  required String phone,
  required String name,
  required MygigPay pay,
  required MygigWay? way,
  required bool phoneRequired,
  MygigBookingChoice booking = const MygigBookingChoice(),
  MygigHireSettings? hire,
  DateTime? now,
}) {
  final problem = quote?.problem['message'];
  if (problem is String && problem.isNotEmpty) return problem;
  // 0330: the package and the time.
  final kindProblem = quote?.raw['kindProblem'];
  if (kindProblem is Map && kindProblem['message'] is String) return kindProblem['message'] as String;
  if (hire != null) {
    final when = mygigWhenProblem(booking, hire, now ?? DateTime.now());
    if (when != null) return when;
  }
  if ((booking.kind == MygigKind.weekly || booking.kind == MygigKind.monthly) && booking.weekdays.isEmpty) {
    return 'Choose the working days.';
  }
  if (hire != null && booking.isLater && quote != null) {
    final plan = mygigPlanFor(booking, pay.name, registered: lookup.registered, s: hire, total: quote.total);
    if (plan.problem != null) return plan.problem;
    if (plan.payNowByLink && !mygigPhoneComplete(phone)) {
      return 'Paying by link needs the passenger’s phone: they pay before the booking is confirmed.';
    }
  }
  if (lookup.state == MygigLookupState.blocked) return 'You blocked this number.';
  final typed = phone.trim().isNotEmpty;
  final complete = mygigPhoneComplete(phone);
  if (pay == MygigPay.link && !complete) return 'Pay by link needs the passenger’s phone.';
  if (phoneRequired && !complete) return 'Enter the passenger’s phone number.';
  if (typed && !complete) return 'Finish the phone number, or clear it.';
  if (lookup.needsName && name.trim().isEmpty) return 'Enter the passenger’s name: this number isn’t registered.';
  if (quote == null) return 'Working out the price…';
  if (way == null) return 'Choose how the passenger accepts the fare.';
  return null;
}

/// The driver's quick trips (0331): their most used myGiG drop-offs.
final mygigQuickTripsProvider = FutureProvider.autoDispose<List<MygigPlace>>(
  (ref) => ref.watch(mygigRepositoryProvider).quickTrips(),
);

class MygigNewScreen extends ConsumerStatefulWidget {
  const MygigNewScreen({super.key});

  @override
  ConsumerState<MygigNewScreen> createState() => _MygigNewScreenState();
}

class _MygigNewScreenState extends ConsumerState<MygigNewScreen> {
  LatLng? _origin;
  MygigStop? _pickup;
  MygigStop? _drop;
  final _stops = <MygigStop>[];
  bool _round = false;
  int _pax = 1;
  final _bags = <String, int>{'small': 0, 'medium': 0, 'large': 0};
  bool _waive = false;
  MygigPay _pay = MygigPay.cash;
  String? _businessId;
  MygigWay? _way;
  final _phone = TextEditingController();
  final _name = TextEditingController();
  MygigLookup _lookup = const MygigLookup();
  // 0331: a number that rode with this driver before, and its usual drop-off.
  MygigRegular? _regular;
  MygigQuote? _quote;
  List<LatLng> _route = const [];
  double? _km;
  double? _min;
  double _approachKm = 0;
  bool _routing = false;
  String? _quoteError;
  // 0330: what is sent and when; a hire may have no drop-off ("as directed").
  MygigBookingChoice _booking = const MygigBookingChoice();
  bool _directed = false;
  Timer? _lookupTimer;
  Timer? _quoteTimer;
  int _quoteSeq = 0;
  int _routeSeq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_locate());
  }

  @override
  void dispose() {
    _lookupTimer?.cancel();
    _quoteTimer?.cancel();
    _phone.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    final fix = await ref.read(tripFixProvider)();
    if (!mounted || fix == null) return;
    Place? named;
    try {
      named = await ref.read(geoServiceProvider).reverse(fix);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _origin = fix;
      _pickup ??= MygigStop(name: 'Current location', address: named?.address ?? named?.name, at: fix, here: true);
    });
  }

  MygigConfig? get _config => ref.read(mygigConfigProvider(mygigAt(_origin?.latitude, _origin?.longitude))).value;

  Future<MygigStop?> _search(String title) async {
    final pick = await showPlaceSearch(context, title: title, near: _origin);
    final p = pick?.place;
    if (p == null) return null;
    return MygigStop(name: p.name, address: p.address, at: p.point);
  }

  Future<void> _editPickup() async {
    final choice = await showAppSheet<String>(
      id: 'mygig.pickup',
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            key: const ValueKey('mygig-pickup-here'),
            leading: const Icon(Icons.my_location),
            title: const Text('Current location'),
            onTap: () => Navigator.pop(c, 'here'),
          ),
          ListTile(
            key: const ValueKey('mygig-pickup-search'),
            leading: const Icon(Icons.search),
            title: const Text('Search another place'),
            subtitle: const Text('For example, meeting the passenger at a mall entrance'),
            onTap: () => Navigator.pop(c, 'search'),
          ),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'here') {
      if (_origin == null) return;
      setState(() {
        _pickup = MygigStop(name: 'Current location', at: _origin!, here: true);
        _approachKm = 0;
      });
      return _changed();
    }
    final p = await _search('Pickup location');
    if (p == null || !mounted) return;
    setState(() => _pickup = p);
    await _changed();
  }

  Future<void> _editDrop() async {
    final p = await _search('Where to?');
    if (p == null || !mounted) return;
    setState(() {
      _drop = p;
      _directed = false;
    });
    await _changed();
  }

  /// Hire with no drop-off: the passenger tells the driver where to go.
  Future<void> _asDirected() async {
    final pickup = _pickup;
    if (pickup == null) return;
    setState(() {
      _drop = MygigStop(name: 'No drop-off · as directed', at: pickup.at);
      _directed = true;
      _stops.clear();
      _round = false;
    });
    await _changed();
  }

  /// Trip or a hire package: a trip needs a drop-off; days, weeks and
  /// months start later.
  Future<void> _kind(MygigKind k) async {
    setState(() {
      _booking = _booking.copyWith(kind: k, later: k.multiDay ? true : _booking.later);
      if (k == MygigKind.trip && _directed) {
        _drop = null;
        _directed = false;
      }
      if (k.hire) _round = false;
    });
    if (k.hire && _drop == null) return _asDirected();
    _requote();
  }

  MygigHireSettings _hireSettings(MygigConfig? c) => MygigHireSettings.of(c?.settings.raw ?? const {});

  List<MygigKind> _kinds(MygigConfig? c) =>
      c == null ? const [MygigKind.trip] : mygigKindsOn(_hireSettings(c), MygigHirePrefs.of(c.prefs.raw));

  Future<void> _addStop() async {
    if (_stops.length >= mygigMaxStops) return;
    final p = await _search('Add a stop');
    if (p == null || !mounted) return;
    setState(() => _stops.add(p));
    await _changed();
  }

  Future<void> _mapTap(LatLng at) async {
    Place? named;
    try {
      named = await ref.read(geoServiceProvider).reverse(at);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _drop = MygigStop(
      name: named?.name ?? '${at.latitude.toStringAsFixed(5)}, ${at.longitude.toStringAsFixed(5)}',
      address: named?.address,
      at: at,
    ));
    await _changed();
  }

  /// The route (and the drive to a pickup elsewhere), then the price.
  Future<void> _changed() async {
    final pickup = _pickup, drop = _drop;
    if (pickup == null || drop == null) return;
    final seq = ++_routeSeq;
    setState(() => _routing = true);
    final geo = ref.read(geoServiceProvider);
    RouteInfo? r;
    try {
      r = _directed
          ? null
          : _round
          ? await geo.route(pickup.at, pickup.at, via: [for (final s in _stops) s.at, drop.at])
          : await geo.route(pickup.at, drop.at, via: [for (final s in _stops) s.at]);
    } catch (_) {}
    var approach = 0.0;
    if (!pickup.here && _origin != null) {
      try {
        approach = (await geo.route(_origin!, pickup.at)).distanceKm;
      } catch (_) {
        approach = const Distance().as(LengthUnit.Meter, _origin!, pickup.at) / 1000 * 1.3;
      }
    }
    if (!mounted || seq != _routeSeq) return;
    setState(() {
      _routing = false;
      _route = r?.points ?? const [];
      _km = r != null && r.distanceKm > 0 ? r.distanceKm : null;
      _min = r != null && r.distanceKm > 0 ? r.durationMin : null;
      _approachKm = double.parse(approach.toStringAsFixed(2));
    });
    _requote();
  }

  Map<String, dynamic> _trip() => _tripOnly()
    ..addAll({if (_directed) 'directed': true})
    ..removeWhere((k, _) => _directed && (k == 'drop' || k == 'km' || k == 'min'));

  Map<String, dynamic> _tripOnly() => mygigTripJson(
    pickup: _pickup!,
    drop: _drop!,
    stops: _stops,
    round: _round,
    km: _km,
    minutes: _min,
    pax: _pax,
    bags: _bags,
    approachKm: _approachKm,
    waive: _waive,
    pay: _pay,
    businessId: _businessId,
  );

  void _requote() {
    if (_pickup == null || _drop == null) return;
    _quoteTimer?.cancel();
    _quoteTimer = Timer(const Duration(milliseconds: 250), () async {
      final seq = ++_quoteSeq;
      try {
        final q = await ref.read(mygigRepositoryProvider)
            .quote({..._trip(), 'booking': _booking.toJson(), 'registered': _lookup.registered});
        if (!mounted || seq != _quoteSeq) return;
        setState(() {
          _quote = q;
          _quoteError = null;
        });
      } catch (e) {
        if (!mounted || seq != _quoteSeq) return;
        setState(() => _quoteError = '$e');
      }
    });
  }

  void _phoneChanged(String v) {
    _lookupTimer?.cancel();
    if (!mygigPhoneComplete(v)) {
      setState(() {
        _lookup = const MygigLookup();
        _regular = null;
      });
      _fixPayAndWay();
      return;
    }
    _lookupTimer = Timer(const Duration(milliseconds: 450), () async {
      try {
        final l = await ref.read(mygigRepositoryProvider).lookup(v, lat: _origin?.latitude, lng: _origin?.longitude);
        if (!mounted || _phone.text != v) return;
        setState(() => _lookup = l);
        _fixPayAndWay();
        final regular = await ref.read(mygigRepositoryProvider).regular(v).catchError((_) => null);
        if (mounted && _phone.text == v) setState(() => _regular = regular);
      } catch (e) {
        if (mounted) showError(context, e);
      }
    });
  }

  /// A payment or a way that no longer fits what the number is goes back.
  void _fixPayAndWay() {
    final c = _config;
    final pays = mygigPayOptions(_lookup);
    if (!pays.contains(_pay)) _pay = MygigPay.cash;
    if (_pay != MygigPay.business) _businessId = null;
    if (_pay == MygigPay.business && _businessId == null && _lookup.businesses.isNotEmpty) {
      _businessId = _lookup.businesses.first.id;
    }
    final ways = c == null ? const <MygigWay>[] : _waysNow(c);
    if (_way != null && !ways.contains(_way)) _way = null;
    setState(() {});
    _requote();
  }

  List<MygigWay> _waysNow(MygigConfig c) {
    final ways = mygigWays(c.settings, _lookup.state, hasPhone: mygigPhoneComplete(_phone.text));
    // A Family ride is accepted in the member's own app.
    return _pay == MygigPay.family ? ways.where((w) => w == MygigWay.app).toList() : ways;
  }

  Future<void> _send() async {
    final c = _config;
    final way = _way;
    if (c == null || way == null) return;
    final sent = await ref.read(mygigRepositoryProvider).create(
      trip: _trip(),
      phone: mygigPhoneComplete(_phone.text) ? '+${mygigPhoneDigits(_phone.text)}' : null,
      name: _name.text.trim().isEmpty ? null : _name.text.trim(),
      way: way,
      lat: _origin?.latitude,
      lng: _origin?.longitude,
      booking: _booking.isBooking ? _booking.toJson() : null,
    );
    if (!mounted) return;
    if (way == MygigWay.whatsapp) await openMygigWhatsApp(sent);
    if (!mounted) return;
    await Navigator.of(context).push(AppPageRoute<void>(
      id: 'mygig.waiting',
      builder: (_) => MygigWaitingScreen(sent: sent),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(mygigConfigProvider(mygigAt(_origin?.latitude, _origin?.longitude))).value;
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('myGiG'),
        actions: [
          IconButton(
            key: const ValueKey('mygig-tune'),
            tooltip: 'myGiG settings',
            icon: const Icon(Icons.tune),
            onPressed: () async {
              await context.push(mygigSettingsPath);
              if (mounted) _requote();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: ResponsiveCenter(
          maxWidth: 760,
          child: ListView(
            key: const ValueKey('mygig-new'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              BusyButton.outlined(
                key: const ValueKey('mygig-where'),
                onPressed: _editDrop,
                icon: const Icon(Icons.search),
                child: Align(alignment: Alignment.centerLeft, child: Text(_drop?.name ?? 'Where to?')),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  height: _drop == null ? 260 : 180,
                  child: RideMap(
                    pickup: _pickup?.at ?? _origin,
                    drop: _drop?.at,
                    stops: [for (final s in _stops) s.at],
                    route: _route,
                    onTap: _mapTap,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (_drop == null) ...[
                _pickupTile(t),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('Search, or tap the map where the passenger is going.', style: t.textTheme.bodyLarge),
                ),
                // 0331: quick trips, the driver's most used drop-offs, one tap.
                ..._quickTrips(t),
                // 0330: hire by time, with or without a drop-off.
                if (_kinds(c).length > 1) ...[
                  Text('Or hire by time', style: t.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final k in _kinds(c).where((k) => k.hire))
                      ActionChip(
                        key: ValueKey('mygig-hire-${k.name}'),
                        avatar: const Icon(Icons.schedule, size: 18),
                        label: Text(k.chip),
                        onPressed: _pickup == null ? null : () => _kind(k),
                      ),
                  ]),
                ],
              ] else
                ..._details(t, c),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _drop == null || c == null ? null : _foot(t, c),
    );
  }

  Widget _pickupTile(ThemeData t) => ListTile(
    key: const ValueKey('mygig-pickup'),
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.trip_origin, color: Color(0xFF2E9E5B)),
    title: Text(_pickup == null ? 'Finding where you are…' : (_pickup!.here ? 'Current location' : _pickup!.name)),
    subtitle: Text(_pickup?.here ?? true ? 'Pickup · your current location' : 'Pickup'),
    trailing: IconButton(tooltip: 'Change pickup', icon: const Icon(Icons.edit), onPressed: _editPickup),
  );

  List<Widget> _details(ThemeData t, MygigConfig? c) {
    final q = _quote;
    final s = c?.settings ?? MygigSettings.fallback;
    final problem = q?.problem;
    final bagsCount = _bags.values.fold<int>(0, (a, b) => a + b);
    final ways = c == null ? const <MygigWay>[] : _waysNow(c);
    final hasPhone = mygigPhoneComplete(_phone.text);
    final hs = _hireSettings(c);
    final kinds = _kinds(c);
    final hire = _booking.kind.hire;
    final rates = c == null ? hs.rates : mygigHireCard(hs, MygigHirePrefs.of(c.prefs.raw));
    return [
      if (kinds.length > 1) ...[
        MygigKindChips(kinds: kinds, selected: _booking.kind, onSelected: _kind),
        const SizedBox(height: 8),
      ],
      if (problem != null && problem.isNotEmpty)
        _box(t, Icons.block, problem['end'] == 'pickup' ? 'No myGiG pickups at ${problem['name']}' : 'No myGiG drop-offs at ${problem['name']}',
            '${problem['message']} Change it, or ask the passenger to book in the app.', bad: true),
      Card(
        margin: EdgeInsets.zero,
        child: Column(children: [
          _pickupTile(t),
          for (final (i, st) in _stops.indexed)
            ListTile(
              key: ValueKey('mygig-stop-$i'),
              leading: CircleAvatar(radius: 12, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
              title: Text(st.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('Stop ${i + 1}'),
              trailing: IconButton(
                tooltip: 'Remove stop ${i + 1}',
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() => _stops.removeAt(i));
                  _changed();
                },
              ),
            ),
          ListTile(
            key: const ValueKey('mygig-drop'),
            leading: Icon(_directed ? Icons.alt_route : Icons.location_on, color: t.colorScheme.error),
            title: Text(_drop!.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(_directed ? 'The passenger tells you where to go' : 'Drop-off'),
            trailing: IconButton(tooltip: 'Change drop-off', icon: const Icon(Icons.edit), onPressed: _editDrop),
          ),
          if (hire && !_directed)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('mygig-as-directed'),
                onPressed: _asDirected,
                icon: const Icon(Icons.alt_route),
                label: const Text('No drop-off · as directed'),
              ),
            ),
          if (_directed)
            const SizedBox.shrink()
          else if (_stops.length < mygigMaxStops)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('mygig-add-stop'),
                onPressed: _addStop,
                icon: const Icon(Icons.add),
                label: const Text('Add stop'),
              ),
            )
          else
            const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('Up to $mygigMaxStops stops.')),
          if (!hire)
          SwitchListTile(
            key: const ValueKey('mygig-round'),
            value: _round,
            title: const Text('Round trip'),
            subtitle: const Text('Back to the pickup at the end'),
            onChanged: (v) {
              setState(() => _round = v);
              _changed();
            },
          ),
        ]),
      ),
      // 0330: a long round trip may suit hourly hire better.
      if (!hire && _round && q != null && q.minutes > 60 && kinds.contains(MygigKind.hourly))
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Card(
            key: const ValueKey('mygig-switch-hourly'),
            color: t.colorScheme.tertiaryContainer,
            child: ListTile(
              leading: Icon(Icons.schedule, color: t.colorScheme.onTertiaryContainer),
              title: Text('Long round trip: about ${q.minutes} min', style: TextStyle(color: t.colorScheme.onTertiaryContainer)),
              subtitle: Text('Hourly hire may suit better: the passenger keeps you by the hour.',
                  style: TextStyle(color: t.colorScheme.onTertiaryContainer)),
              trailing: TextButton(
                onPressed: () {
                  setState(() => _booking = _booking.copyWith(
                      hours: ((q.minutes / 60).ceil()).clamp(hs.minHours.ceil(), hs.maxHours.floor()).toDouble()));
                  _kind(MygigKind.hourly);
                },
                child: const Text('Switch'),
              ),
            ),
          ),
        ),
      if (hire) ...[
        const SizedBox(height: 12),
        MygigHireOptions(
          choice: _booking,
          settings: hs,
          rates: rates,
          kmIncluded: q == null ? null : (q.raw['kmIncluded'] as num?)?.toDouble(),
          onChanged: (b) {
            setState(() => _booking = b);
            _requote();
          },
        ),
      ],
      if (hs.laterEnabled || _booking.kind.multiDay) ...[
        const SizedBox(height: 12),
        MygigWhenPicker(
          key: ValueKey('mygig-when-${_booking.kind.name}'),
          choice: _booking,
          settings: hs,
          now: DateTime.now(),
          onChanged: (b) {
            setState(() => _booking = b);
            _requote();
          },
        ),
      ],
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: Text(
            _routing
                ? 'Finding the route…'
                : q == null
                ? 'Working out the price…'
                : hire
                ? '${((q.raw['kmIncluded'] as num?) ?? 0).round()} km included · ${_booking.kind == MygigKind.hourly ? '${_booking.hours.round()} h' : '${q.raw['days'] ?? 1} days'}'
                : '${q.km.toStringAsFixed(1)} km · ${q.minutes} min',
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
        Text(q == null ? '' : mygigMoney(q.total), key: const ValueKey('mygig-total'), style: t.textTheme.headlineSmall),
      ]),
      if (_quoteError != null) Text(_quoteError!, style: TextStyle(color: t.colorScheme.error)),
      if (q != null)
        MygigPriceLines(quote: q, what: hire ? _booking.whatText : 'myGiG', bags: _bags, stops: _stops.length, round: _round),
      if (q != null && q.guard && !hire)
        _box(t, Icons.warning_amber, 'Much higher than the app price',
            'The same trip is about ${mygigMoney(q.appPrice)} in the get.ride app. The passenger sees that price too.', warn: true),
      if (q != null && q.approachFull > 0)
        SwitchListTile(
          key: const ValueKey('mygig-charge-approach'),
          contentPadding: EdgeInsets.zero,
          value: !_waive,
          title: const Text('Charge for coming to the pickup'),
          subtitle: Text('${q.approachKm.toStringAsFixed(1)} km from where you are · ${mygigMoney(q.approachFull)}'),
          onChanged: (v) {
            setState(() => _waive = !v);
            _requote();
          },
        ),
      Text(
          hire
              ? 'A fixed package price. Overtime and extra km are added at the end of each day; tolls and parking too.'
              : 'A fixed price for the passenger. Tolls and parking are added at the end.',
          style: t.textTheme.bodySmall),
      const SizedBox(height: 12),
      _stepper(t, Icons.person_outline, 'Passengers', _pax, 1, 8, (v) => setState(() => _pax = v), key: 'mygig-pax'),
      const SizedBox(height: 8),
      Row(children: [
        const Icon(Icons.luggage_outlined),
        const SizedBox(width: 8),
        Text('Luggage', style: t.textTheme.titleSmall),
        const Spacer(),
        Text('${(c?.prefs.freeBags ?? 0) > 0 ? '${c!.prefs.freeBags} free · ' : ''}$bagsCount/${s.maxBags}',
            style: t.textTheme.bodySmall),
      ]),
      for (final (k, label, hint) in mygigBagSizes)
        _stepper(
          t,
          null,
          '$label ${(c?.prefs.lug(k) ?? 0) > 0 ? '+${mygigMoney(c!.prefs.lug(k))} each' : 'Free'}',
          _bags[k]!,
          0,
          _bags[k]! + (s.maxBags - bagsCount),
          (v) {
            setState(() => _bags[k] = v);
            _requote();
          },
          sub: hint,
          key: 'mygig-bag-$k',
        ),
      const SizedBox(height: 12),
      Row(children: [
        const Icon(Icons.person),
        const SizedBox(width: 8),
        Text('Passenger', style: t.textTheme.titleSmall),
        const SizedBox(width: 8),
        Text(s.phoneRequired ? 'Phone required' : 'Phone optional', style: t.textTheme.bodySmall),
      ]),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('mygig-phone'),
        controller: _phone,
        keyboardType: TextInputType.phone,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 \-]'))],
        decoration: InputDecoration(
          prefixText: '+60 ',
          labelText: s.phoneRequired ? 'Phone' : 'Phone (optional)',
          hintText: '12 345 6789',
          suffixIcon: _phone.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear phone',
                  icon: const Icon(Icons.cancel),
                  onPressed: () {
                    _phone.clear();
                    _name.clear();
                    _phoneChanged('');
                  },
                ),
        ),
        onChanged: _phoneChanged,
      ),
      const SizedBox(height: 8),
      ..._lookupLines(t),
      if (_regular case final reg? when _drop == null || _directed ||
          !mygigSamePlace(_drop!.at.latitude, _drop!.at.longitude, reg.drop.lat, reg.drop.lng))
        Card(
          key: const ValueKey('mygig-regular'),
          child: ListTile(
            leading: const Icon(Icons.history),
            title: Text(reg.title),
            subtitle: Text(reg.subtitle),
            trailing: TextButton(
              key: const ValueKey('mygig-regular-use'),
              onPressed: () => _useDrop(reg.drop),
              child: const Text('Use'),
            ),
          ),
        ),
      if (_lookup.needsName)
        TextField(
          key: const ValueKey('mygig-name'),
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Passenger name (required)'),
          onChanged: (_) => setState(() {}),
        ),
      const SizedBox(height: 12),
      Text('Payment', style: t.textTheme.titleSmall),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final p in mygigPayOptions(_lookup))
          ChoiceChip(
            key: ValueKey('mygig-pay-${p.name}'),
            label: Text(mygigPayName(p, familyHost: _lookup.familyHost,
                business: _lookup.businesses.where((b) => b.id == _businessId).firstOrNull?.name ??
                    _lookup.businesses.firstOrNull?.name)),
            selected: _pay == p,
            onSelected: (_) {
              setState(() => _pay = p);
              _fixPayAndWay();
            },
          ),
      ]),
      if (_pay == MygigPay.family && _lookup.familyHost != null)
        _box(t, Icons.family_restroom, 'Paid by ${_lookup.familyHost}',
            'From ${_lookup.familyHost}’s GET.wallet, within the passenger’s Family limit'
            '${_lookup.familyLeft == null ? '' : ' (${mygigMoney(_lookup.familyLeft!)} left this month)'}. They accept in the app.',
            ok: true),
      if (_pay == MygigPay.business && _lookup.businesses.length > 1)
        Wrap(spacing: 8, children: [
          for (final b in _lookup.businesses)
            ChoiceChip(label: Text(b.name), selected: _businessId == b.id, onSelected: (_) => setState(() => _businessId = b.id)),
        ]),
      if (_pay == MygigPay.business)
        _box(t, Icons.business_center_outlined, _lookup.businesses.where((b) => b.id == _businessId).firstOrNull?.name ?? 'Business',
            'Charged to the business account, on its own settlement.', ok: true),
      if (_pay == MygigPay.link && !_booking.isLater)
        Text('The passenger pays on their phone by card, FPX or DuitNow when the trip ends. If they don’t, take cash.',
            style: t.textTheme.bodySmall),
      // 0330: how a booking or hire is paid (no losses: nothing later without in-app payment).
      if (q != null && (_booking.isLater || hire))
        Builder(builder: (_) {
          final plan = mygigPlanFor(_booking, _pay.name, registered: _lookup.registered, s: hs, total: q.total);
          if (plan.problem != null) {
            return MygigNote(key: const ValueKey('mygig-plan'), icon: Icons.block, title: 'Not offered', body: plan.problem!, bad: true);
          }
          final text = mygigPlanText(_booking, plan, hs,
              payName: mygigPayName(_pay, familyHost: _lookup.familyHost),
              business: _lookup.businesses.where((b) => b.id == _businessId).firstOrNull?.name,
              balanceHow: _pay == MygigPay.cash ? 'in cash' : 'in cash or by link');
          return MygigNote(
            key: const ValueKey('mygig-plan'),
            icon: plan.payNowByLink ? Icons.link : plan.kind == MygigPlanKind.business ? Icons.business_center_outlined : Icons.account_balance_wallet_outlined,
            title: text.title,
            body: text.body,
            ok: !plan.payNowByLink,
            warn: plan.payNowByLink,
          );
        }),
      if (c != null)
        if (mygigFeeNote(_lookup, _pay,
                cancelFee: c.settings.cancelOn && c.prefs.cancelOn ? c.prefs.cancelAmount : 0,
                noShowFee: c.settings.noShowOn && c.prefs.noShowOn ? c.prefs.noShowAmount : 0,
                freeMin: c.settings.cancelFreeMin)
            case final note?)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(note, key: const ValueKey('mygig-fee-note'), style: t.textTheme.bodySmall),
          ),
      const SizedBox(height: 12),
      Text('How they accept the fare', style: t.textTheme.titleSmall),
      Card(
        margin: const EdgeInsets.only(top: 8),
        child: RadioGroup<MygigWay>(
          groupValue: _way,
          onChanged: (w) => setState(() => _way = w),
          child: Column(children: [
            for (final w in ways)
              RadioListTile<MygigWay>(
                key: ValueKey('mygig-way-${w.name}'),
                value: w,
                title: Text(w.label),
                subtitle: Text(w.sub),
                secondary: Icon(_wayIcon(w)),
              ),
          ]),
        ),
      ),
      if (!hasPhone && !s.phoneRequired)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('With no phone, the fare can only be shown on this phone, and no receipt or trip link is sent.',
              style: t.textTheme.bodySmall),
        ),
    ];
  }

  /// A quick trip or a regular's usual drop-off becomes the drop-off.
  Future<void> _useDrop(MygigPlace p) async {
    setState(() {
      _drop = MygigStop(name: p.name, address: p.address, at: LatLng(p.lat, p.lng));
      _directed = false;
    });
    await _changed();
  }

  List<Widget> _quickTrips(ThemeData t) {
    final places = ref.watch(mygigQuickTripsProvider).value ?? const <MygigPlace>[];
    if (places.isEmpty) return const [];
    return [
      Text('Quick trips', style: t.textTheme.titleSmall),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final p in places)
          ActionChip(
            key: ValueKey('mygig-quick-${p.name}'),
            avatar: const Icon(Icons.bolt, size: 18),
            label: Text(p.name),
            onPressed: _pickup == null ? null : () => _useDrop(p),
          ),
      ]),
      const SizedBox(height: 12),
    ];
  }

  List<Widget> _lookupLines(ThemeData t) {
    final l = _lookup;
    if (l.state == MygigLookupState.short) {
      return [
        if (_phone.text.trim().isNotEmpty)
          Text('Checking when the number is complete…', style: t.textTheme.bodySmall),
      ];
    }
    if (l.state == MygigLookupState.blocked) {
      return [_box(t, Icons.block, 'You blocked this number', l.note, bad: true)];
    }
    if (l.registered) {
      return [
        _box(t, l.state == MygigLookupState.latest ? Icons.verified : Icons.system_update,
            l.name ?? 'Registered passenger', [if (l.idLine != null) l.idLine!, l.note].join('\n'),
            ok: l.state == MygigLookupState.latest, warn: l.state == MygigLookupState.old),
      ];
    }
    return [
      _box(t, Icons.person_add_alt, 'Not registered', l.note),
      if (l.flagged)
        _box(t, Icons.flag_outlined, '${l.repeat} myGiG rides from this number this week',
            'get.ride shows this to the admin. A regular passenger can book you in the app with your QR.', warn: true),
    ];
  }

  IconData _wayIcon(MygigWay w) => switch (w) {
    MygigWay.app => Icons.send_to_mobile,
    MygigWay.whatsapp => Icons.chat_outlined,
    MygigWay.sms => Icons.sms_outlined,
    MygigWay.here => Icons.screen_rotation,
  };

  Widget _box(ThemeData t, IconData icon, String title, String body, {bool bad = false, bool warn = false, bool ok = false}) {
    final cs = t.colorScheme;
    final bg = bad ? cs.errorContainer : warn ? cs.tertiaryContainer : ok ? cs.secondaryContainer : cs.surfaceContainerHighest;
    final fg = bad ? cs.onErrorContainer : warn ? cs.onTertiaryContainer : ok ? cs.onSecondaryContainer : cs.onSurface;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: fg),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.textTheme.titleSmall?.copyWith(color: fg)),
            Text(body, style: t.textTheme.bodySmall?.copyWith(color: fg)),
          ]),
        ),
      ]),
    );
  }

  Widget _stepper(ThemeData t, IconData? icon, String label, int value, int min, int max, ValueChanged<int> set,
      {String? sub, required String key}) =>
      Row(key: ValueKey(key), children: [
        if (icon != null) ...[Icon(icon), const SizedBox(width: 8)],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label),
            if (sub != null) Text(sub, style: t.textTheme.bodySmall),
          ]),
        ),
        IconButton(
          tooltip: 'Fewer',
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: value > min ? () => set(value - 1) : null,
        ),
        Text('$value', style: t.textTheme.titleMedium),
        IconButton(
          tooltip: 'More',
          icon: const Icon(Icons.add_circle_outline),
          onPressed: value < max ? () => set(value + 1) : null,
        ),
      ]);

  Widget _foot(ThemeData t, MygigConfig c) {
    final why = mygigSendProblem(
      quote: _quote,
      lookup: _lookup,
      phone: _phone.text,
      name: _name.text,
      pay: _pay,
      way: _way,
      phoneRequired: c.settings.phoneRequired,
      booking: _booking,
      hire: _hireSettings(c),
    );
    final at = _booking.at;
    final label = switch (_way) {
      null => 'Choose how they accept',
      _ when _booking.isLater && at != null => 'Send booking for ${mygigWhenText(at, DateTime.now())}',
      MygigWay.app => 'Send to ${c.settings.nameMode == 'hide' || _lookup.name == null ? 'their' : '${_lookup.name}’s'} app',
      MygigWay.whatsapp => 'Send WhatsApp link',
      MygigWay.sms => 'Send SMS link',
      MygigWay.here => 'Show the passenger',
    };
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (why != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(why, key: const ValueKey('mygig-why'), textAlign: TextAlign.center, style: t.textTheme.bodySmall),
            ),
          SizedBox(
            width: double.infinity,
            child: BusyButton.filled(
              key: const ValueKey('mygig-send'),
              icon: Icon(_way == null ? Icons.send : _wayIcon(_way!)),
              onPressed: why == null ? _send : null,
              child: Text(label),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Opens WhatsApp on the driver's phone with the trip link for the passenger.
Future<void> openMygigWhatsApp(MygigSent sent) async {
  final digits = (sent.phone ?? '').replaceAll(RegExp(r'\D'), '');
  final text = sent.message ?? sent.link ?? '';
  if (digits.isEmpty || text.isEmpty) return;
  final uri = Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text)}');
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// The price lines, as the driver set it to show (the tax as its own line,
/// or one price that includes it).
class MygigPriceLines extends StatelessWidget {
  const MygigPriceLines({super.key, required this.quote, required this.what, this.bags = const {}, this.stops = 0, this.round = false});
  final MygigQuote quote;
  final String what;
  final Map<String, int> bags;
  final int stops;
  final bool round;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final small = t.textTheme.bodySmall;
    final label = [what, if (stops > 0) '$stops stop${stops > 1 ? 's' : ''}', if (round) 'round trip'].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(key: const ValueKey('mygig-lines'), children: [
        for (final l in quote.lines(what: label, bags: bags))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(children: [
              Expanded(child: Text(l.label, style: small)),
              if (l.struck && l.was != null) ...[
                Text(mygigMoney(l.was!), style: small?.copyWith(decoration: TextDecoration.lineThrough)),
                const SizedBox(width: 6),
              ],
              Text(mygigMoney(l.amount), style: small),
            ]),
          ),
        if (quote.taxNote != null)
          Align(alignment: Alignment.centerLeft, child: Text(quote.taxNote!, style: small)),
      ]),
    );
  }
}
