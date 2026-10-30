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
}) {
  final problem = quote?.problem['message'];
  if (problem is String && problem.isNotEmpty) return problem;
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
  MygigQuote? _quote;
  List<LatLng> _route = const [];
  double? _km;
  double? _min;
  double _approachKm = 0;
  bool _routing = false;
  String? _quoteError;
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
    setState(() => _drop = p);
    await _changed();
  }

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
      r = _round
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

  Map<String, dynamic> _trip() => mygigTripJson(
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
        final q = await ref.read(mygigRepositoryProvider).quote(_trip());
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
      setState(() => _lookup = const MygigLookup());
      _fixPayAndWay();
      return;
    }
    _lookupTimer = Timer(const Duration(milliseconds: 450), () async {
      try {
        final l = await ref.read(mygigRepositoryProvider).lookup(v, lat: _origin?.latitude, lng: _origin?.longitude);
        if (!mounted || _phone.text != v) return;
        setState(() => _lookup = l);
        _fixPayAndWay();
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
    return [
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
            leading: Icon(Icons.location_on, color: t.colorScheme.error),
            title: Text(_drop!.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: const Text('Drop-off'),
            trailing: IconButton(tooltip: 'Change drop-off', icon: const Icon(Icons.edit), onPressed: _editDrop),
          ),
          if (_stops.length < mygigMaxStops)
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
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: Text(
            _routing ? 'Finding the route…' : q == null ? 'Working out the price…' : '${q.km.toStringAsFixed(1)} km · ${q.minutes} min',
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
        Text(q == null ? '' : mygigMoney(q.total), key: const ValueKey('mygig-total'), style: t.textTheme.headlineSmall),
      ]),
      if (_quoteError != null) Text(_quoteError!, style: TextStyle(color: t.colorScheme.error)),
      if (q != null) MygigPriceLines(quote: q, what: 'myGiG', bags: _bags, stops: _stops.length, round: _round),
      if (q != null && q.guard)
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
      Text('A fixed price for the passenger. Tolls and parking are added at the end.', style: t.textTheme.bodySmall),
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
      if (_pay == MygigPay.link)
        Text('The passenger pays on their phone by card, FPX or DuitNow when the trip ends. If they don’t, take cash.',
            style: t.textTheme.bodySmall),
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
    );
    final label = switch (_way) {
      null => 'Choose how they accept',
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
