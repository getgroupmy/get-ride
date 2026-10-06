import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../config.dart';
import '../../core/app_display.dart';
import '../../core/fare.dart';
import '../../core/fare_coins.dart';
import '../../core/fare_offer.dart';
import '../../core/format.dart';
import '../../core/place_gates.dart';
import '../../core/ride_request_metadata.dart';
import '../../core/home_sections.dart';
import '../../core/ride_stops.dart';
import '../../widgets/side_menu_tiles.dart';
import '../../widgets/toll_booths.dart';
import '../../core/route_estimate.dart';
import '../../data/app_display_repository.dart';
import '../../data/coin_trade_repository.dart';
import '../../data/device_access.dart';
import '../../data/fare_coin_store.dart';
import '../../data/geo_service.dart';
import '../../data/models.dart';
import '../../data/route_estimate_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/ride_map.dart';
import 'fare_offer_controls.dart';
import 'home_parts.dart';
import 'place_search.dart';
import '../meter/meter_auto_launch.dart';
import '../../admin/screens/commerce/get_coin.dart' show formatCoins, rideRewardCoins;

enum _PinTarget { none, pickup, drop }

/// Rider home: pick pickup + destination, choose a service, book.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  LatLng? _me;
  Place? _here;
  Place? _pickup;
  Place? _drop;

  /// Stops on the way, in order (up to [maxRideStops]).
  final List<Place> _stops = [];
  RouteInfo? _route;
  RouteEstimate? _ai;
  int _routeSeq = 0;
  String? _serviceName;

  /// What the booking sheet offers: the admin Vehicle Services catalogue,
  /// or the built-in list while it loads or when it cannot be read.
  List<RideService> get _services => ref.read(rideServicesProvider).value ?? rideServices;

  /// The chosen service, or the first one offered.
  RideService get _service {
    final services = _services;
    return services.firstWhere((s) => s.name == _serviceName, orElse: () => services.first);
  }
  String _payment = 'Cash';
  bool _useCoins = false;

  /// The rider's GET.coin balance and the admin rate, for the "Use GET.coin"
  /// switch. Null while loading or when it can't be read: no switch then.
  ({double balance, double rate})? get _coins {
    final q = ref.read(coinTradeQuoteProvider).value;
    return q == null ? null : (balance: q.coinBalance, rate: q.settings.coinsPerCurrency);
  }
  final _note = TextEditingController();
  _PinTarget _pinTarget = _PinTarget.none;
  bool _booking = false;

  /// The rider's own fare offer on the selected service, against the
  /// recommended fare, where bidding is on at the pickup (Expo ride-confirm).
  double _adjust = 0;
  bool _biddingOn = false;
  LatLng? _biddingAt;
  bool _routing = false;
  RideRequest? _ongoing;

  /// Admin → Display → On-map vehicle icons: simulated cars around the
  /// pickup, as Expo drew them (not real drivers).
  List<DemoCar> _cars = const [];
  LatLng? _carsAround;
  String? _carsFor;
  Timer? _carsTimer;
  final _rnd = math.Random();

  void _syncCars(bool on) {
    final center = _pickup?.point ?? _me;
    if (!on || center == null || _drop != null) {
      _carsTimer?.cancel();
      _carsTimer = null;
      if (_cars.isNotEmpty) _cars = const [];
      return;
    }
    final service = _service;
    final moved = _carsAround == null ||
        (_carsAround!.latitude - center.latitude).abs() + (_carsAround!.longitude - center.longitude).abs() >
            demoCarRadius;
    if (moved || _carsFor != service.name || _cars.isEmpty) {
      _carsAround = center;
      _carsFor = service.name;
      _cars = spawnDemoCars(center.latitude, center.longitude,
          demoCarCount(_services.indexWhere((s) => s.name == service.name)), _rnd);
    }
    _carsTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final c = _carsAround;
      if (!mounted || c == null) return;
      setState(() => _cars = [for (final car in _cars) stepDemoCar(car, c.latitude, c.longitude, _rnd)]);
    });
  }

  @override
  void initState() {
    super.initState();
    _locate();
    _checkOngoing();
    // A TEKSI driver whose rate card asks for it lands on the meter, once
    // per launch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybeAutoLaunchMeter(context, ref);
    });
  }

  @override
  void dispose() {
    _carsTimer?.cancel();
    _note.dispose();
    super.dispose();
  }

  Future<void> _checkOngoing() async {
    try {
      final r = await ref.read(rideRepositoryProvider).ongoingForRider();
      if (mounted) setState(() => _ongoing = r);
    } catch (_) {}
  }

  Future<void> _locate() async {
    final p = await currentPosition();
    if (p == null || !mounted) return;
    setState(() => _me = p);
    final place = await ref.read(geoServiceProvider).reverse(p);
    if (!mounted) return;
    setState(() {
      _here = place;
      _pickup ??= place;
    });
    _updateRoute();
  }

  Future<void> _updateRoute() async {
    final a = _pickup, b = _drop;
    final seq = ++_routeSeq;
    // A new route is a new recommended fare: any offer starts again from it.
    _adjust = 0;
    if (a != null) unawaited(_checkBidding(a.point));
    if (a == null || b == null) {
      setState(() {
        _route = null;
        _ai = null;
      });
      return;
    }
    setState(() {
      _routing = true;
      _ai = null;
    });
    // The map route draws the line; the AI's traffic-aware estimate, when
    // there is one, is what the fare is priced on (Expo ride-confirm). It
    // only knows pickup to drop-off, so a trip with stops is priced on the
    // route through them instead.
    final via = [for (final p in _stops) p.point];
    final aiFuture =
        via.isEmpty ? ref.read(routeEstimateRepositoryProvider).estimate(a.point, b.point) : Future.value(null);
    final r = await ref.read(geoServiceProvider).route(a.point, b.point, via: via);
    if (!mounted || seq != _routeSeq) return;
    setState(() {
      _route = r;
      _routing = false;
    });
    final ai = await aiFuture;
    if (mounted && seq == _routeSeq) setState(() => _ai = ai);
  }

  ({double distanceKm, double durationMin})? get _basis {
    final r = _route;
    return r == null ? null : fareBasis(routeKm: r.distanceKm, routeMin: r.durationMin, ai: _ai);
  }

  Future<void> _addStop() async {
    if (_stops.length >= maxRideStops) return;
    final pick = await showPlaceSearch(
      context,
      title: 'Add a stop',
      near: _me ?? _pickup?.point,
      usage: GateUsage.drop,
    );
    if (pick == null || !mounted) return;
    final place = pick.place;
    if (place == null) return showInfo(context, 'Search for the stop by name or address.');
    setState(() => _stops.add(place));
    _updateRoute();
  }

  void _removeStop(int index) {
    setState(() => _stops.removeAt(index));
    _updateRoute();
  }

  Future<void> _choose(_PinTarget target) async {
    final pick = await showPlaceSearch(
      context,
      title: target == _PinTarget.pickup ? 'Pickup' : 'Where to?',
      near: _me ?? _pickup?.point,
      current: _here,
      usage: target == _PinTarget.pickup ? GateUsage.pickup : GateUsage.drop,
    );
    if (pick == null || !mounted) return;
    if (pick.pickOnMap) {
      setState(() => _pinTarget = target);
      showInfo(context, 'Tap the map to set the ${target == _PinTarget.pickup ? 'pickup' : 'destination'}');
      return;
    }
    setState(() => target == _PinTarget.pickup ? _pickup = pick.place : _drop = pick.place);
    _updateRoute();
  }

  Future<void> _onMapTap(LatLng p) async {
    final target = _pinTarget;
    if (target == _PinTarget.none) return;
    setState(() => _pinTarget = _PinTarget.none);
    final place = await ref.read(geoServiceProvider).reverse(p);
    if (!mounted) return;
    setState(() => target == _PinTarget.pickup ? _pickup = place : _drop = place);
    _updateRoute();
  }

  /// Whether riders may set their own fare at [pickup]; checked once per
  /// pickup. Unknown is off, which is today's fixed fare.
  Future<void> _checkBidding(LatLng pickup) async {
    if (_biddingAt == pickup) return;
    _biddingAt = pickup;
    var on = false;
    try {
      on = await ref
          .read(rideRepositoryProvider)
          .biddingEnabledFor(pickup, () => ref.read(geoServiceProvider).reverseArea(pickup));
    } catch (_) {}
    if (mounted && _biddingAt == pickup) setState(() => _biddingOn = on);
  }

  double _recommendedFor(RideService s) {
    final b = _basis;
    return b == null ? 0 : calculateFare(b.distanceKm, b.durationMin, multiplier: s.multiplier);
  }

  /// What [s] is booked at: the rider's offer on the selected service where
  /// bidding is on, else the recommended fare.
  double _fareFor(RideService s, {bool? biddingOn}) {
    final recommended = _recommendedFor(s);
    if (s.name != _service.name) return recommended;
    return offeredFare(recommended: recommended, adjust: _adjust, biddingOn: biddingOn ?? _biddingOn);
  }

  Future<void> _book() async {
    final a = _pickup, b = _drop, r = _basis;
    if (a == null || b == null || r == null) return;
    if (await ref.read(deviceBlockedProvider.future)) {
      if (mounted) showInfo(context, '$serviceNotAvailable. This device is not permitted to place a request.');
      return;
    }
    if (!(await ref.read(appDisplayProvider.future)).serviceEnabled) {
      if (mounted) showInfo(context, serviceComingSoonMessage);
      return;
    }
    setState(() => _booking = true);
    try {
      final profile = await ref.read(profileProvider.future);
      final rides = ref.read(rideRepositoryProvider);
      // One geocode of the pickup serves the bidding check and the row's
      // geography; it and the IP lookup run alongside the bidding check.
      final areaLookup = ref.read(geoServiceProvider).reverseArea(a.point);
      final ipLookup = rides.publicIp();
      final offerMe = await rides.biddingEnabledFor(a.point, () => areaLookup);
      AreaInfo? area;
      try {
        area = await areaLookup.timeout(const Duration(seconds: 5));
      } catch (_) {}
      final metadata = rideRequestMetadata(
        area: area,
        ipAddress: await ipLookup,
        gender: profile?.raw['gender'] as String?,
        riderPhoto: profile?.avatarUrl,
      );
      final req = await rides.createRequest(
            service: _service.name,
            pickupName: a.name,
            pickupAddress: a.address,
            pickupLat: a.point.latitude,
            pickupLng: a.point.longitude,
            dropName: b.name,
            dropAddress: b.address,
            dropLat: b.point.latitude,
            dropLng: b.point.longitude,
            distanceKm: r.distanceKm,
            durationMin: r.durationMin.round(),
            // The booking-time check decides: an offer made where bidding has
            // since turned out to be off goes out at the recommended fare.
            fare: _fareFor(_service, biddingOn: offerMe),
            paymentMode: _payment,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            riderName: profile?.name,
            riderPhone: profile?.phone,
            deviceOs: kIsWeb ? 'web' : defaultTargetPlatform.name,
            offerMe: offerMe,
            stops: List.of(_stops),
            metadata: metadata,
          );
      final coins = _coins;
      if (_useCoins && coins != null && fareCoinOffer(_fareFor(_service, biddingOn: offerMe), coins.balance, coins.rate) != null) {
        try {
          await ref.read(fareCoinChoiceStoreProvider).choose(req.id);
        } catch (_) {}
      }
      if (mounted) context.push('/ride/${req.id}').then((_) => _checkOngoing());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  /// The Expo home parts shown before a destination is chosen, as Admin →
  /// Display Settings switches them: vehicle-type bar, search bar, recent
  /// places and the service boxes.
  Widget _homeParts(HomeSections sections, Map<String, dynamic> blob, AppDisplay? display) {
    final serviceOn = display?.serviceEnabled ?? true;
    final recent = sections.recentPlaces ? (ref.watch(recentPlacesProvider).value ?? const <Place>[]) : const <Place>[];
    final boxes = sections.serviceBoxes
        ? serviceBoxViews(
            blob,
            serviceNames: ref.watch(serviceBoxNamesProvider).value ?? const {},
            serviceEnabled: serviceOn,
            newBadge: sections.newBadge,
          )
        : const <ServiceBoxView>[];
    void comingSoon(String body) => showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Coming Soon'),
            content: Text(body),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
          ),
        );
    void whereTo() => serviceOn ? _choose(_PinTarget.drop) : comingSoon(serviceComingSoonMessage);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (sections.vehicleBar) ...[
        VehicleTypeBar(
          services: _services,
          selected: _service,
          onSelect: (s) => setState(() => _serviceName = s.name),
        ),
        const SizedBox(height: 12),
      ],
      if (!sections.addressBar)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.trip_origin, color: Colors.green.shade700),
          title: Text(_pickup?.name ?? 'Set pickup'),
          onTap: () => _choose(_PinTarget.pickup),
        ),
      if (sections.searchBar)
        HomeSearchPill(onTap: whereTo)
      else
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.location_on, color: Colors.red.shade700),
          title: const Text('Where to?'),
          onTap: whereTo,
        ),
      if (recent.isNotEmpty) ...[
        const SizedBox(height: 4),
        HomeRecentPlaces(
          places: recent,
          onTap: (p) {
            if (!serviceOn) return comingSoon(serviceComingSoonMessage);
            setState(() => _drop = p);
            _updateRoute();
          },
        ),
      ],
      if (boxes.isNotEmpty) ...[
        const SizedBox(height: 16),
        ServiceBoxesGrid(
          boxes: boxes,
          onOpen: (b) => b.route == null ? comingSoon(serviceBoxComingSoon(b.title)) : openAppRoute(context, b.route!),
        ),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final display = ref.watch(appDisplayProvider).value;
    final blob = ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{};
    final sections = HomeSections.fromSettings(blob);
    _syncCars(sections.vehicleMarkers);
    final serviceIndex = _services.indexWhere((s) => s.name == _service.name);
    final ai = _ai;
    final tolls = display?.showAiTollBooths ?? true
        ? tollMarks(ai, [for (final p in _route?.points ?? const <LatLng>[]) (lat: p.latitude, lng: p.longitude)])
        : const <TollMark>[];
    final map = Stack(children: [
      RideMap(
        me: _me,
        pickup: _pickup?.point,
        drop: _drop?.point,
        stops: [for (final p in _stops) p.point],
        route: _route?.points ?? const [],
        onTap: _onMapTap,
        extraMarkers: [
          for (final c in _cars) demoCarMarker(c, serviceIndex),
          for (final m in tolls) tollMarker(m, onTap: ai == null ? null : () => showTollBooths(context, ai)),
        ],
      ),
      if (_pinTarget != _PinTarget.none)
        Positioned(
          top: 16,
          left: 16,
          right: 16,
          child: SafeArea(
            child: Material(
              borderRadius: BorderRadius.circular(12),
              elevation: 3,
              child: ListTile(
                leading: const Icon(Icons.touch_app),
                title: Text('Tap the map to set the ${_pinTarget == _PinTarget.pickup ? 'pickup' : 'destination'}'),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _pinTarget = _PinTarget.none),
                ),
              ),
            ),
          ),
        ),
      if (sections.addressBar && _drop == null && _pinTarget == _PinTarget.none)
        Positioned(
          top: 16,
          left: 72,
          right: 72,
          child: SafeArea(
            child: Center(child: PickupPill(place: _pickup, onTap: () => _choose(_PinTarget.pickup))),
          ),
        ),
      if (display?.recenterButton ?? true)
        Positioned(
        right: 16,
        bottom: wide ? 16 : null,
        top: wide ? null : 16,
        child: SafeArea(
          child: FloatingActionButton.small(
            heroTag: 'locate',
            onPressed: _locate,
            child: const Icon(Icons.my_location),
          ),
        ),
      ),
    ]);

    ref.watch(rideServicesProvider); // rebuild when the catalogue arrives
    ref.watch(coinTradeQuoteProvider); // and when the GET.coin balance does
    final panel = _BookingPanel(
      ongoing: _ongoing,
      pickup: _pickup,
      drop: _drop,
      route: _route,
      ai: _ai,
      showTolls: display?.showAiTollCharges ?? true,
      showBooths: display?.showAiTollBooths ?? true,
      routing: _routing,
      services: _services,
      service: _service,
      payment: _payment,
      coins: _coins,
      useCoins: _useCoins,
      onUseCoins: (v) => setState(() => _useCoins = v),
      note: _note,
      booking: _booking,
      fareFor: _fareFor,
      onPickup: () => _choose(_PinTarget.pickup),
      onDrop: () => _choose(_PinTarget.drop),
      onSwap: () {
        setState(() {
          final t = _pickup;
          _pickup = _drop;
          _drop = t;
          // The way back visits the stops the other way round.
          final back = _stops.reversed.toList();
          _stops
            ..clear()
            ..addAll(back);
        });
        _updateRoute();
      },
      stops: _stops,
      onAddStop: _addStop,
      onRemoveStop: _removeStop,
      onService: (s) => setState(() {
        if (s.name != _serviceName) _adjust = 0;
        _serviceName = s.name;
      }),
      fareOffer: _biddingOn && _basis != null && !_routing
          ? FareOfferRow(
              recommended: _recommendedFor(_service),
              adjust: _adjust,
              money: (v) => formatMoney(v, AppConfig.currency),
              onAdjust: (v) => setState(() => _adjust = v),
            )
          : null,
      onPayment: (p) => setState(() => _payment = p),
      onBook: _book,
      onOpenOngoing: () => context.push('/ride/${_ongoing!.id}').then((_) => _checkOngoing()),
      idle: _drop == null ? _homeParts(sections, blob, display) : null,
      earnRate: ref.watch(coinTradeQuoteProvider).value?.settings.earnCoinsPerCurrency ?? 0,
    );

    if (wide) {
      return Scaffold(
        body: Row(children: [
          SizedBox(width: 420, child: SafeArea(child: SingleChildScrollView(child: panel))),
          const VerticalDivider(width: 1),
          Expanded(child: map),
        ]),
      );
    }
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(child: map),
        DraggableScrollableSheet(
          initialChildSize: 0.45,
          minChildSize: 0.22,
          maxChildSize: 0.92,
          builder: (context, scroll) => Material(
            elevation: 8,
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: SingleChildScrollView(
              controller: scroll,
              child: Column(children: [
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                panel,
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _BookingPanel extends StatelessWidget {
  const _BookingPanel({
    required this.ongoing,
    required this.pickup,
    required this.drop,
    this.stops = const [],
    this.onAddStop,
    this.onRemoveStop,
    required this.route,
    this.ai,
    this.showTolls = true,
    this.showBooths = true,
    required this.routing,
    required this.services,
    required this.service,
    required this.payment,
    this.coins,
    this.useCoins = false,
    this.onUseCoins,
    required this.note,
    required this.booking,
    required this.fareFor,
    required this.onPickup,
    required this.onDrop,
    required this.onSwap,
    required this.onService,
    this.fareOffer,
    required this.onPayment,
    required this.onBook,
    required this.onOpenOngoing,
    this.idle,
    this.earnRate = 0,
  });

  /// GC earned per unit of fare (Admin → Get Coin → earn rate).
  final double earnRate;

  final RideRequest? ongoing;
  final Place? pickup;
  final Place? drop;
  final List<Place> stops;
  final VoidCallback? onAddStop;
  final ValueChanged<int>? onRemoveStop;
  final RouteInfo? route;
  final RouteEstimate? ai;
  final bool showTolls;
  final bool showBooths;
  final bool routing;
  final List<RideService> services;
  final RideService service;
  final String payment;
  final ({double balance, double rate})? coins;
  final bool useCoins;
  final ValueChanged<bool>? onUseCoins;
  final TextEditingController note;
  final bool booking;
  final double Function(RideService) fareFor;
  final VoidCallback onPickup, onDrop, onSwap, onBook, onOpenOngoing;
  final ValueChanged<RideService> onService;

  /// The −/+ fare offer for the selected service, where bidding is on.
  final Widget? fareOffer;
  final ValueChanged<String> onPayment;

  /// What the panel shows before a destination is chosen (the Expo home
  /// parts); null keeps the plain pickup / destination card.
  final Widget? idle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (ongoing != null) ...[
          Card(
            color: t.colorScheme.primaryContainer,
            child: ListTile(
              leading: const Icon(Icons.local_taxi),
              title: Text(ongoing!.status.label),
              subtitle: Text('${ongoing!.pickupLabel} → ${ongoing!.dropLabel}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right),
              onTap: onOpenOngoing,
            ),
          ),
          const SizedBox(height: 12),
        ],
        ?idle,
        if (idle == null) Text('Where are you going?', style: t.textTheme.titleLarge),
        if (idle == null) const SizedBox(height: 12),
        if (idle == null) Card(
          child: Column(children: [
            ListTile(
              leading: Icon(Icons.trip_origin, color: Colors.green.shade700),
              title: Text(pickup?.name ?? 'Set pickup'),
              subtitle: pickup == null
                  ? null
                  : Text(pickup!.address, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: onPickup,
            ),
            Row(children: [
              const Expanded(child: Divider(indent: 56)),
              IconButton(tooltip: 'Swap', icon: const Icon(Icons.swap_vert), onPressed: onSwap),
            ]),
            for (var i = 0; i < stops.length; i++)
              ListTile(
                key: ValueKey('stop-$i'),
                leading: CircleAvatar(
                  radius: 12,
                  backgroundColor: Colors.orange.shade800,
                  child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 12)),
                ),
                title: Text(stops[i].name),
                subtitle: Text(stops[i].address, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  key: ValueKey('stop-remove-$i'),
                  tooltip: 'Remove ${stopLabel(i).toLowerCase()}',
                  icon: const Icon(Icons.close),
                  onPressed: () => onRemoveStop?.call(i),
                ),
              ),
            ListTile(
              leading: Icon(Icons.location_on, color: Colors.red.shade700),
              title: Text(drop?.name ?? 'Where to?'),
              subtitle:
                  drop == null ? null : Text(drop!.address, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: onDrop,
            ),
            if (drop != null && stops.length < maxRideStops && onAddStop != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('add-stop'),
                  onPressed: onAddStop,
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: Text(stops.isEmpty ? 'Add a stop' : 'Add another stop'),
                ),
              ),
          ]),
        ),
        if (routing) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
        if (route != null && !routing) ...[
          const SizedBox(height: 12),
          RouteBasisLine(route: route!, ai: ai),
          if (showTolls && ai?.tollsToShow != null)
            Text(
              'Est. toll charges ${formatMoney(ai!.tollsToShow, AppConfig.currency)}, not included in the fare',
              key: const ValueKey('route-tolls'),
              style: t.textTheme.bodySmall,
            ),
          if (showBooths && tollBoothCount(ai) > 0)
            InkWell(
              key: const ValueKey('route-toll-booths'),
              onTap: () => showTollBooths(context, ai!),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  const Icon(Icons.toll, size: 16, color: Color(0xFFF59E0B)),
                  const SizedBox(width: 6),
                  Text('Est. toll booths: ${tollBoothCount(ai)}',
                      style: t.textTheme.bodySmall?.copyWith(decoration: TextDecoration.underline)),
                ]),
              ),
            ),
          const SizedBox(height: 8),
          for (final s in services)
            Card(
              key: ValueKey('service-${s.name}'),
              color: s.name == service.name ? t.colorScheme.secondaryContainer : null,
              child: ListTile(
                leading: Icon(s.name == 'Teksi' ? Icons.local_taxi : Icons.directions_car),
                title: Text(s.name),
                subtitle: Text('${s.description} · ${s.seats} seats'),
                trailing: Text(formatMoney(fareFor(s), AppConfig.currency),
                    style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                onTap: () => onService(s),
              ),
            ),
          ?fareOffer,
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'Cash', icon: Icon(Icons.payments_outlined), label: Text('Cash')),
              ButtonSegment(
                  value: 'Get Pay', icon: Icon(Icons.account_balance_wallet_outlined), label: Text('Wallet')),
            ],
            selected: {payment},
            onSelectionChanged: (v) => onPayment(v.first),
          ),
          if (coins != null && fareCoinOffer(fareFor(service), coins!.balance, coins!.rate) != null)
            SwitchListTile(
              key: const ValueKey('use-coins'),
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.toll_outlined),
              title: const Text('Use GET.coin'),
              subtitle: Text(fareCoinSubtitle(
                on: useCoins,
                fare: fareFor(service),
                coinBalance: coins!.balance,
                coinsPerCurrency: coins!.rate,
                currency: AppConfig.currency,
              )),
              value: useCoins,
              onChanged: onUseCoins,
            ),
          const SizedBox(height: 12),
          TextField(
            controller: note,
            decoration: const InputDecoration(labelText: 'Note to driver (optional)'),
          ),
          if (earnRate > 0 && rideRewardCoins(fareFor(service), earnRate) > 0) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Chip(
                key: const ValueKey('booking-coin-earn'),
                avatar: const Icon(Icons.toll, size: 16, color: Color(0xFFB45309)),
                label: Text('Earn ${formatCoins(rideRewardCoins(fareFor(service), earnRate))} on this booking'),
              ),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: booking || ongoing != null ? null : onBook,
            child: booking
                ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(ongoing != null
                    ? 'You already have a ride in progress'
                    : 'Book ${service.name} · ${formatMoney(fareFor(service), AppConfig.currency)}'),
          ),
        ],
      ]),
    );
  }
}

/// The distance and time the fares are priced on. When they came from the
/// AI Fare Service (`ai-route-proxy`, traffic-aware) the line says so with
/// the AI mark; the plain road route has none.
class RouteBasisLine extends StatelessWidget {
  const RouteBasisLine({super.key, required this.route, this.ai});

  final RouteInfo route;
  final RouteEstimate? ai;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final a = ai;
    final text = a == null
        ? '${formatDistance(route.distanceKm)} · ${formatDuration(route.durationMin)}'
        : '${formatDistance(a.distanceKm)} · ${formatDuration(a.durationMin)} with traffic';
    return Row(children: [
      Flexible(child: Text(text, key: const ValueKey('route-basis'), style: t.textTheme.bodyMedium)),
      if (a != null) ...[
        const SizedBox(width: 6),
        Tooltip(
          message: 'Estimated by the AI Fare Service',
          child: Container(
            key: const ValueKey('route-ai'),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: t.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.auto_awesome, size: 14, color: t.colorScheme.onPrimaryContainer),
              const SizedBox(width: 3),
              Text(
                'AI',
                style: t.textTheme.labelSmall?.copyWith(
                  color: t.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ]),
          ),
        ),
      ],
    ]);
  }
}
