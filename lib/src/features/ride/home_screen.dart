import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../config.dart';
import '../../core/app_display.dart';
import '../../core/payment_types.dart';
import '../../core/book_for.dart';
import '../../core/commission.dart' show Geo;
import '../../core/driver_eta.dart';
import '../../core/fare.dart';
import '../../core/fare_tariff.dart';
import '../../core/fare_coins.dart';
import '../../core/fare_offer.dart';
import '../../core/format.dart';
import '../../core/place_gates.dart';
import '../../core/ride_request_metadata.dart';
import '../../core/home_sections.dart';
import '../../core/ride_confirm.dart';
import '../../core/ride_stops.dart';
import '../../widgets/side_menu_host.dart';
import '../../widgets/side_menu_tiles.dart';
import '../../widgets/toll_booths.dart';
import '../../core/route_estimate.dart';
import '../../data/app_display_repository.dart';
import '../../data/coin_trade_repository.dart';
import '../../data/device_access.dart';
import '../../data/fare_coin_store.dart';
import '../../data/fare_tariff_repository.dart';
import '../../data/geo_service.dart';
import '../../data/models.dart';
import '../../data/route_estimate_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/map_drag_pin.dart';
import '../../widgets/map_recenter.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/map_type_button.dart';
import '../../widgets/ride_map.dart';
import 'auto_accept.dart';
import 'book_for_sheet.dart';
import 'confirm_parts.dart';
import 'offer_fare_screen.dart';
import 'home_parts.dart';
import 'place_search.dart';
import 'ride_tracking_screen.dart' show rideStreamProvider;
import '../meter/meter_auto_launch.dart';
import '../../admin/screens/commerce/get_coin.dart' show rideRewardCoins;

enum _PinTarget { none, pickup, drop }

/// Rider home: pick pickup + destination, choose a service, book.
/// The nearest online drivers to a pickup, per vehicle type (0111); empty
/// when none is near or it can't be read.
final nearbyDriversProvider = FutureProvider.autoDispose.family<Map<String, double>, (double, double)>((ref, at) async {
  try {
    return await ref.watch(rideRepositoryProvider).nearbyDrivers(at.$1, at.$2);
  } catch (_) {
    return const {};
  }
});

/// A pickup to about 100 m, so a nudged pin doesn't ask again.
(double, double) roundedPoint(LatLng p) => ((p.latitude * 1000).round() / 1000, (p.longitude * 1000).round() / 1000);

/// Street level (inDrive's home map): what the home map opens and recentres
/// at, with the pickup in the middle and the nearby streets around it.
const homeStreetZoom = 17.0;

/// How long the confirm screen waits for the AI fare estimate.
const aiEstimateTimeout = Duration(seconds: 30);

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
  /// The rider's pick; [_payment] is what is booked, the pick only while
  /// Admin → Payment Type still offers it.
  String _paymentPick = 'Cash';
  List<PaymentChoice> get _payments => ref.read(paymentChoicesProvider).value ?? builtInPayments;
  String get _payment => resolvePayment(_paymentPick, _payments);
  bool _useCoins = false;

  /// The rider's GET.coin balance and the admin rate, for the "Use GET.coin"
  /// switch. Null while loading or when it can't be read: no switch then.
  ({double balance, double rate})? get _coins {
    final q = ref.read(coinTradeQuoteProvider).value;
    return q == null ? null : (balance: q.coinBalance, rate: q.settings.coinsPerCurrency);
  }
  final _note = TextEditingController();

  /// The home map's camera, so the recenter button can move it.
  final _map = MapController();
  _PinTarget _pinTarget = _PinTarget.none;
  bool _booking = false;

  /// The pickup pin is up off the map while the rider drags the map under
  /// it ([MapDragPin]); its marker and the box above it hide meanwhile.
  bool _pinMoving = false;

  /// The confirm step's extras (Expo ride-confirm): the entrance the
  /// driver should come to, "Auto-accept offer of RM x", and whether the
  /// map was moved off the route (which shows the route button).
  String _entrance = '';
  bool _autoAccept = false;

  /// From the Options sheet: a child seat, more than four riding.
  RideOptions _options = const RideOptions();
  bool _routeMoved = false;

  /// The last pickup set by dragging the map: the map doesn't reframe on
  /// it, since the rider just put the camera where they want it.
  LatLng? _dragged;

  /// The rider's own fare offer on the selected service, against the
  /// recommended fare, where bidding is on at the pickup (Expo ride-confirm).
  double _adjust = 0;
  bool _biddingOn = false;
  LatLng? _biddingAt;
  bool _routing = false;
  RideRequest? _ongoing;

  /// Rides on the go that the rider booked for other people; any number,
  /// and none of them stands in the way of a booking (migration 0107).
  List<RideRequest> _forOthers = const [];

  /// "Who's riding?": the rider, or someone else (name and phone).
  bool _forOther = false;
  final _otherName = TextEditingController();
  final _otherPhone = TextEditingController();
  /// Where the pickup is, for the tariff card that prices it (0109); null
  /// until the geocoder answers, when the master card (if any) applies.
  AreaInfo? _pickupArea;

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
    _otherName.dispose();
    _otherPhone.dispose();
    _map.dispose();
    super.dispose();
  }

  Future<void> _checkOngoing() async {
    try {
      final all = await ref.read(rideRepositoryProvider).ridesOnTheGo();
      if (mounted) {
        setState(() {
          _ongoing = ownRide(all);
          _forOthers = ridesForOthers(all);
        });
      }
    } catch (_) {}
  }

  /// The recenter button: back onto the last known fix at once, then onto
  /// a fresh one. The map only follows the first fix by itself, so without
  /// the move the button refreshed the location and left the map where the
  /// rider had scrolled it.
  ///
  /// On the home map it also puts the pickup there: the pin floats up and
  /// drops on the fix, as if the map had been dragged under it.
  void _recenter() {
    if (recenterMap(_map, _me, zoom: homeStreetZoom, offset: _focusOffset)) _pinOnto(_me!);
    unawaited(_locate(recenter: true));
  }

  /// Where the pin and the rider are kept: the middle of the map above the
  /// sheet when it is all the way down (inDrive's), not the map's centre.
  Offset get _focusOffset {
    final c = _pin.currentContext;
    return c == null ? Offset.zero : MapBottomInset.focusOffset(c);
  }

  final _pin = GlobalKey<MapDragPinState>();

  /// The pin's place as Admin → Display last set it.
  (double, double, double)? _pinPlace;

  /// An admin moving the pin (Drop pin height / left-right, Map height)
  /// while the rider looks at the map: the pickup slides to its new place
  /// at once, rather than at the next recenter.
  void _refocusOnLayoutChange(HomeMapLayout layout) {
    final place = (layout.pinShift.$1, layout.pinShift.$2, layout.mapExtra);
    final before = _pinPlace;
    _pinPlace = place;
    if (before == null || before == place || _drop != null || _pinMoving) return;
    final at = _pickup?.point;
    if (at == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _drop != null || _pinMoving) return;
      try {
        recenterMap(_map, at, zoom: _map.camera.zoom, offset: _focusOffset);
      } catch (_) {} // the map not drawn yet: its first fit puts the pin there
    });
  }

  /// The pickup pin dropped on [p], where the pin is draggable (no
  /// destination yet) and the pickup is not already there.
  void _pinOnto(LatLng p) {
    if (_drop != null || _pinTarget != _PinTarget.none) return;
    if (_pickup != null && const Distance()(_pickup!.point, p) < 5) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _pin.currentState?.dropAt(p));
  }

  Future<void> _locate({bool recenter = false}) async {
    final p = await currentPosition();
    if (p == null || !mounted) return;
    setState(() => _me = p);
    if (recenter && recenterMap(_map, p, zoom: homeStreetZoom, offset: _focusOffset)) _pinOnto(p);
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
    // there is one, is what the fare is priced on (Expo ride-confirm). A
    // trip with stops is asked about through them, in their order, so adding
    // or rearranging stops prices (and judges high or low) the trip again.
    final via = [for (final p in _stops) p.point];
    // The proxy may try several keys; past this the map route prices it.
    final aiFuture = ref
        .read(routeEstimateRepositoryProvider)
        .estimateDetailed(a.point, b.point, via: via)
        .timeout(aiEstimateTimeout, onTimeout: () => null);
    final r = await ref.read(geoServiceProvider).route(a.point, b.point, via: via);
    if (!mounted || seq != _routeSeq) return;
    setState(() => _route = r);
    // Both before the fare shows (Expo's "Calculating fare" overlay stays up
    // through the AI estimate): the fare is never shown, or booked, on the
    // map route only to change a moment later.
    final ai = await aiFuture;
    if (!mounted || seq != _routeSeq) return;
    setState(() {
      // Only an estimate through every stop prices this trip.
      _ai = estimateCoversStops(ai?.estimate, via.length) ? ai?.estimate : null;
      _routing = false;
    });
    if (ai != null && ai.unavailable && mounted) {
      unawaited(showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          key: const ValueKey('traffic-unavailable'),
          title: const Text(trafficUnavailableTitle),
          content: const Text(trafficUnavailableMessage),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      ));
    }
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

  /// The places after the pickup, in their new order (the destinations
  /// sheet): the last is the destination, the rest the stops on the way.
  void _setDestinations(List<Place> places) {
    if (places.isEmpty) return;
    setState(() {
      _stops
        ..clear()
        ..addAll(places.take(places.length - 1));
      _drop = places.last;
    });
    _updateRoute();
  }

  Future<void> _choose(_PinTarget target) async {
    final pickup = target == _PinTarget.pickup;
    final pick = await showPlaceSearch(
      context,
      title: pickup ? 'Pickup' : 'Enter your route',
      near: _me ?? _pickup?.point,
      current: _here,
      usage: pickup ? GateUsage.pickup : GateUsage.drop,
      // inDrive's "From" above the destination field.
      from: pickup ? null : _pickup,
    );
    if (pick == null || !mounted) return;
    if (pick.pickOnMap) {
      setState(() => _pinTarget = target);
      showInfo(context, 'Tap the map to set the ${pickup ? 'pickup' : 'destination'}');
      return;
    }
    setState(() {
      if (pickup) {
        _pickup = pick.place;
        // A saved place's entrance is where to wait.
        if (pick.entrance.isNotEmpty) _entrance = pick.entrance;
      } else {
        _drop = pick.place;
      }
    });
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

  /// The map was dragged under the pickup pin and it dropped at [p]: that
  /// is the pickup now, named once the geocoder answers.
  Future<void> _onPinDropped(LatLng p) async {
    setState(() {
      _dragged = p;
      _pickup = Place(name: 'Finding address…', address: '', point: p);
    });
    final place = await ref.read(geoServiceProvider).reverse(p);
    // A later drag, search or swap has moved the pickup on since.
    if (!mounted || _pickup?.point != p) return;
    setState(() => _pickup = place);
    _updateRoute();
  }

  /// Whether riders may set their own fare at [pickup]; checked once per
  /// pickup. Unknown is off, which is today's fixed fare.
  Future<void> _checkBidding(LatLng pickup) async {
    if (_biddingAt == pickup) return;
    _biddingAt = pickup;
    _pickupArea = null;
    // One geocode of the pickup serves the bidding check and the tariff.
    final area = ref.read(geoServiceProvider).reverseArea(pickup);
    unawaited(area.then((a) {
      if (mounted && _biddingAt == pickup) setState(() => _pickupArea = a);
    }, onError: (_) {}));
    var on = false;
    try {
      on = await ref.read(rideRepositoryProvider).biddingEnabledFor(pickup, () => area);
    } catch (_) {}
    if (mounted && _biddingAt == pickup) setState(() => _biddingOn = on);
  }

  /// The booking tariff card for the pickup (Admin → Fare tariffs), or null
  /// for the built-in TEKSI tariff.
  FareTariff? get _tariff {
    final a = _pickupArea;
    return resolveFareTariff(
      ref.read(fareTariffsProvider).value ?? const [],
      Geo(country: a?.country, state: a?.state, city: a?.city, suburb: a?.suburb),
    );
  }

  /// The currency the trip is quoted and booked in: the card's.
  String get _currency => _tariff?.currency ?? AppConfig.currency;

  double _recommendedFor(RideService s) {
    final b = _basis;
    return b == null
        ? 0
        : quoteFare(_tariff, b.distanceKm, b.durationMin, multiplier: s.multiplier, fallbackCurrency: AppConfig.currency)
            .fare;
  }

  /// What [s] is booked at: the rider's offer on the selected service where
  /// bidding is on, else the recommended fare.
  double _fareFor(RideService s, {bool? biddingOn}) {
    final recommended = _recommendedFor(s);
    if (s.name != _service.name) return recommended;
    return offeredFare(recommended: recommended, adjust: _adjust, biddingOn: biddingOn ?? _biddingOn);
  }

  /// "Offer your fare" (inDrive's page): the fare typed in, with the
  /// payment, auto-accept and entrance alongside; "Find a driver" there
  /// books straight away.
  Future<void> _openOfferFare() async {
    final recommended = _recommendedFor(_service);
    final style = currencyStyles[_currency.trim().toUpperCase()];
    final r = await Navigator.of(context).push<OfferFareResult>(
      MaterialPageRoute(
        builder: (_) => OfferFareScreen(
          recommended: recommended,
          current: recommended + _adjust,
          currencyLabel: (style?.symbol ?? _currency).trim(),
          money: (v) => formatMoney(v, _currency),
          payment: _payment,
          payments: _payments,
          autoAccept: _autoAccept,
          entrance: _entrance,
          pickupName: _pickup?.name ?? 'Pickup',
          routeLabel: _stops.isEmpty ? (_drop?.name ?? 'Destination') : '${_stops.length + 1} route stops',
          onRoute: _drop == null
              ? null
              : () => showRouteStopsSheet(context, destinations: [..._stops, _drop!], onChanged: _setDestinations),
          onAddStop: _stops.length < maxRideStops ? _addStop : null,
          optionsOn: _options.any,
          onOptions: (c) => showRideOptionsSheet(
            c,
            options: _options,
            onChanged: (o) => setState(() => _options = o),
            note: _note,
          ),
        ),
      ),
    );
    if (r == null || !mounted) return;
    setState(() {
      if (r.fare != null) _adjust = r.fare! - recommended;
      _paymentPick = r.payment;
      _autoAccept = r.autoAccept;
      _entrance = r.entrance;
    });
    final canFind = !_booking &&
        !_routing &&
        _basis != null &&
        !(_forOther && bookedFor(_otherName.text, _otherPhone.text) == null);
    if (r.find && canFind) await _find();
  }

  Future<void> _book() async {
    final a = _pickup, b = _drop, r = _basis;
    if (a == null || b == null || r == null) return;
    final forWhom = _forOther ? bookedFor(_otherName.text, _otherPhone.text) : null;
    if (_forOther && forWhom == null) {
      showInfo(context, bookForProblem(_otherName.text, _otherPhone.text) ?? "Enter the passenger's details.");
      return;
    }
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
            passengers: _options.passengers,
            note: driverNote(options: _options, entrance: _entrance, note: _note.text),
            riderName: profile?.name,
            riderPhone: profile?.phone,
            deviceOs: kIsWeb ? 'web' : defaultTargetPlatform.name,
            offerMe: offerMe,
            stops: List.of(_stops),
            metadata: metadata,
            bookedFor: forWhom,
            currency: _currency,
          );
      if (_autoAccept) {
        ref.read(autoAcceptProvider.notifier).set(req.id, _fareFor(_service, biddingOn: offerMe));
      }
      final coins = _coins;
      if (_useCoins && coins != null && fareCoinOffer(_fareFor(_service, biddingOn: offerMe), coins.balance, coins.rate) != null) {
        try {
          await ref.read(fareCoinChoiceStoreProvider).choose(req.id);
        } catch (_) {}
      }
      if (mounted) context.push('/ride/${req.id}').then((_) => _checkOngoing());
    } on DuplicateRideRequest catch (e) {
      // Nothing was sent: take the rider to the request they already have.
      if (!mounted) return;
      showInfo(context, e.toString());
      await _checkOngoing();
      final open = e.forOthers ? null : _ongoing;
      if (mounted && open != null) context.push('/ride/${open.id}').then((_) => _checkOngoing());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  /// The confirm step's back arrow: off the trip, back to the home map.
  void _leaveConfirm() {
    setState(() {
      _drop = null;
      _stops.clear();
      _routeMoved = false;
    });
    _updateRoute();
  }

  /// The route button: the whole trip back in view.
  void _showWholeRoute(double bottom) {
    final pts = [
      ?_pickup?.point,
      for (final s in _stops) s.point,
      ?_drop?.point,
      ...?_route?.points,
    ];
    if (pts.length > 1) {
      _map.fitCamera(
        CameraFit.coordinates(coordinates: pts, padding: EdgeInsets.fromLTRB(64, 160, 64, 64 + bottom), maxZoom: 16),
      );
    }
    setState(() => _routeMoved = false);
  }

  /// "Find a driver". One ride of the rider's own at a time (Expo's alert);
  /// rides for others are not held back by it.
  Future<void> _find() async {
    if (!_forOther && _ongoing != null) {
      final open = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          key: const ValueKey('ride-in-progress'),
          title: const Text('Ride in progress'),
          content: const Text('You already have a ride in progress. Finish or cancel it before booking another.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('OK')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('View ride')),
          ],
        ),
      );
      if (open == true && mounted && _ongoing != null) {
        context.push('/ride/${_ongoing!.id}').then((_) => _checkOngoing());
      }
      return;
    }
    await _book();
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
        // Until the catalogue lands, a skeleton: the built-in names and car
        // icons would read as the real services and then change.
        if (ref.watch(rideServicesProvider).hasValue)
          VehicleTypeBar(
            services: _services,
            selected: _service,
            onSelect: (s) => setState(() => _serviceName = s.name),
          )
        else
          const VehicleTypeBarSkeleton(),
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
    // The ride card follows its ride: a ride that is cancelled, expires or
    // ends (on this device or anywhere else) leaves the home screen, and one
    // that moves on shows its new status, however the rider came back here
    // (the tracking screen's Done goes straight home, so the push it was
    // opened with never reports back).
    final ongoing = _ongoing;
    if (ongoing != null) {
      ref.listen(rideStreamProvider(ongoing.id), (_, next) {
        final r = next.value;
        if (r == null || !mounted || _ongoing?.id != r.id) return;
        setState(() => _ongoing = r.status.isOngoing ? r : null);
      });
    }
    // The same for every ride booked for someone else.
    for (final other in _forOthers) {
      ref.listen(rideStreamProvider(other.id), (_, next) {
        final r = next.value;
        if (r == null || !mounted || !_forOthers.any((o) => o.id == r.id)) return;
        setState(() => _forOthers = [
              for (final o in _forOthers)
                if (o.id != r.id)
                  o
                else if (r.status.isOngoing)
                  r,
            ]);
      });
    }
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
    final showPill = sections.addressBar && _drop == null && _pinTarget == _PinTarget.none;
    // A destination chosen: the confirm step (Expo ride-confirm).
    final confirming = _drop != null;
    final layout = ConfirmLayout.fromSettings(blob);
    // The back and route buttons stand clear of the promo bar's visible top.
    final aboveBar = layout.promoBar
        ? PromoBanner.visibleHeight + (layout.promoBarInFront ? PromoBanner.tuck : 0) + 12 - layout.promoBarOffset
        : 12.0;
    // Places that move with the sheet: [build] gets how far up it reaches.
    Widget aboveSheet(Widget Function(double inset) build) => Positioned.fill(
      child: Builder(builder: (c) => MapBottomInset.listen(c, (inset) => Stack(children: [build(inset)]))),
    );
    // The discount bar; in front of the sheet it is drawn on the sheet's
    // layer instead of the map's (Admin → Display → Discount bar in front).
    Widget promoBar() => aboveSheet(
          (inset) => Positioned(
            left: 0,
            right: 0,
            // Behind, its foot tucks under the sheet's top edge; in front it
            // stands whole on that edge.
            bottom: inset - (layout.promoBarInFront ? 0 : PromoBanner.tuck) - layout.promoBarOffset,
            child: PromoBanner(onTap: () => showPromoSheet(context)),
          ),
        );
    // Admin → Display → Map Layout, while the pickup is being set.
    final mapLayout = confirming ? const HomeMapLayout() : HomeMapLayout.fromSettings(blob);
    _refocusOnLayoutChange(mapLayout);
    final map = Stack(children: [
      Positioned(
        // Map height: the map reaches above the top of the screen.
        top: -mapLayout.mapExtra,
        left: 0,
        right: 0,
        bottom: 0,
        child: MapFocusShift(
          // Drop pin height / left-right: where the pin is kept.
          shift: Offset(mapLayout.pinShift.$1, mapLayout.pinShift.$2),
          child: MapDragPin(
            key: _pin,
            controller: _map,
            pin: _pickup?.point,
            // Dragging the map sets the pickup until a destination is chosen.
            enabled: _drop == null && _pinTarget == _PinTarget.none,
            onMoving: (v) {
              if (mounted && v != _pinMoving) setState(() => _pinMoving = v);
            },
            onDropped: _onPinDropped,
            child: RideMap(
              controller: _map,
              me: _me,
              pickup: _pickup?.point,
              showPickup: !_pinMoving,
              hideCredit: _pinMoving,
              dotPins: confirming,
              focusPickup: !wide,
              pointZoom: homeStreetZoom,
              onGesture: confirming && !_routeMoved ? () => setState(() => _routeMoved = true) : null,
              autoFit: !_pinMoving && (_drop != null || _pickup == null || _pickup!.point != _dragged),
              drop: _drop?.point,
              stops: [for (final p in _stops) p.point],
              route: _route?.points ?? const [],
              onTap: _onMapTap,
              satellite: ref.watch(mapSatelliteProvider),
              extraMarkers: [
                for (final c in _cars) demoCarMarker(c, serviceIndex),
                // The pickup box stands 5 px above the pickup pin and moves with
                // it; it hides while the pin is lifted, until it lands.
                if (showPill && _pickup != null && !_pinMoving)
                  labelAbovePin(
                    _pickup!.point,
                    PickupPill(place: _pickup, onTap: () => _choose(_PinTarget.pickup)),
                    width: math.min(320, MediaQuery.sizeOf(context).width - 32),
                    // Address bar height.
                    gap: mapLayout.pillGap,
                  ),
                for (final m in tolls) tollMarker(m, onTap: ai == null ? null : () => showTollBooths(context, ai)),
              ],
            ),
          ),
        ),
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
      // With no pickup on the map yet there is no pin to stand on: the box
      // waits at the top until there is.
      if (showPill && _pickup == null)
        Positioned(
          top: 16 + math.max(0, mapLayout.pillOffset),
          left: 72,
          right: 72,
          child: SafeArea(
            child: Center(child: PickupPill(place: _pickup, onTap: () => _choose(_PinTarget.pickup))),
          ),
        ),
      // The menu button (Expo's top-left hamburger): the side menu, on
      // phones, where there is no tab bar. It slides off with the others.
      if (SideMenuHost.of(context) != null && !confirming)
        Positioned(
          left: 16,
          top: 16,
          child: IgnorePointer(
            ignoring: _pinMoving,
            child: AnimatedSlide(
              offset: Offset(0, _pinMoving ? -3 : 0),
              duration: MapSheetLayout.hideDuration,
              curve: _pinMoving ? Curves.easeIn : Curves.easeOut,
              child: AnimatedOpacity(
                opacity: _pinMoving ? 0 : 1,
                duration: MapSheetLayout.hideDuration,
                child: SafeArea(
                  child: Builder(
                    builder: (context) => FloatingActionButton.small(
                      key: const ValueKey('home-menu'),
                      heroTag: 'home-menu',
                      tooltip: 'Menu',
                      onPressed: () => SideMenuHost.of(context)?.open(),
                      child: const Icon(Icons.menu),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      // Bottom right, riding just above the sheet as on the driver's map: the
      // map type over recenter. While the map is dragged under the pickup
      // pin they slide down off it with the sheet, and back after.
      if (!confirming)
        aboveSheet(
          (inset) => Positioned(
            right: 16,
            // Recenter button height: at least that far up, still above the sheet.
            bottom: math.max(mapAttributionClearance + inset, mapLayout.recenterBottom ?? 0),
            child: IgnorePointer(
              ignoring: _pinMoving,
              child: AnimatedSlide(
                key: const ValueKey('map-buttons'),
                offset: Offset(0, _pinMoving ? 3 : 0),
                duration: MapSheetLayout.hideDuration,
                curve: _pinMoving ? Curves.easeIn : Curves.easeOut,
                child: AnimatedOpacity(
                  opacity: _pinMoving ? 0 : 1,
                  duration: MapSheetLayout.hideDuration,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const MapTypeButton(),
                      if (display?.recenterButton ?? true) ...[
                        const SizedBox(height: 8),
                        RecenterButton(onPressed: _recenter),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      // Behind the sheet: its top shows above it, which overlaps the rest.
      if (confirming && !wide && layout.promoBar && !layout.promoBarInFront) promoBar(),
      if (confirming && _pinTarget == _PinTarget.none)
        Positioned(
          top: 16 + layout.address.$2,
          left: 16 + layout.address.$1,
          right: 16 - layout.address.$1,
          child: SafeArea(
            child: ConfirmAddressCard(
              pickup: _pickup,
              drop: _drop!,
              stops: _stops,
              duration: _routing ? '' : confirmDuration(_basis?.durationMin),
              entrance: _entrance,
              onPickup: () => _choose(_PinTarget.pickup),
              onDrop: () => _choose(_PinTarget.drop),
              onEntrance: () async {
                final v = await showEntranceSheet(context, _entrance);
                if (v != null && mounted) setState(() => _entrance = v);
              },
              onStops: () => showRouteStopsSheet(
                context,
                destinations: [..._stops, _drop!],
                onChanged: _setDestinations,
              ),
              onAddStop: _stops.length < maxRideStops ? _addStop : null,
            ),
          ),
        ),
      if (confirming)
        aboveSheet(
          (inset) => Positioned(
            left: 16 + layout.back.$1,
            bottom: (wide ? 16 : inset + aboveBar) - layout.back.$2,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              shape: const CircleBorder(),
              elevation: 3,
              child: IconButton(
                key: const ValueKey('confirm-back'),
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: _leaveConfirm,
              ),
            ),
          ),
        ),
      if (confirming && _routeMoved)
        aboveSheet(
          (inset) => Positioned(
            right: 16 - layout.recenter.$1,
            bottom: (wide ? mapAttributionClearance : inset + aboveBar) - layout.recenter.$2,
            child: RouteFitButton(
              key: const ValueKey('confirm-route'),
              onPressed: () => _showWholeRoute(wide ? 0 : inset),
            ),
          ),
        ),
    ]);

    ref.watch(rideServicesProvider); // rebuild when the catalogue arrives
    ref.watch(paymentChoicesProvider); // and when Admin → Payment Type changes
    ref.watch(coinTradeQuoteProvider); // and when the GET.coin balance does
    ref.watch(fareTariffsProvider); // re-quote when the tariff cards arrive
    final earnRate = ref.watch(coinTradeQuoteProvider).value?.settings.earnCoinsPerCurrency ?? 0;
    final coins = _coins;
    final coinOffer = coins == null ? null : fareCoinOffer(_fareFor(_service), coins.balance, coins.rate);
    final otherName = _otherName.text.trim();
    final footer = confirming && _route != null
        ? ConfirmFooter(
            onOptions: () => showRideOptionsSheet(
              context,
              options: _options,
              onChanged: (o) => setState(() => _options = o),
              note: _note,
            ).then((_) {
              if (mounted) setState(() {}); // the note may have changed
            }),
            optionsOn: _options.any,
            payment: _payment,
            payments: _payments,
            onPayment: () async {
              final p = await showPaymentSheet(context, _payment, payments: _payments);
              if (p != null && mounted) setState(() => _paymentPick = p);
            },
            autoAcceptLabel: 'Auto-accept offer of ${formatMoney(_fareFor(_service), _currency)}',
            autoAccept: _autoAccept,
            onAutoAccept: (v) => setState(() => _autoAccept = v),
            label: _forOther ? 'Find a driver for ${otherName.isEmpty ? 'someone else' : otherName}' : 'Find a driver',
            onFind: _booking ||
                    _routing ||
                    _basis == null ||
                    (_forOther && bookedFor(_otherName.text, _otherPhone.text) == null)
                ? null
                : _find,
            coinTitle: coinOffer == null ? null : 'Use GET.coin',
            coinSubtitle: coinOffer == null
                ? null
                : fareCoinSubtitle(
                    on: _useCoins,
                    fare: _fareFor(_service),
                    coinBalance: coins!.balance,
                    coinsPerCurrency: coins.rate,
                    currency: _currency,
                  ),
            useCoins: _useCoins,
            onUseCoins: (v) => setState(() => _useCoins = v),
            whoRiding: _WhoRiding(
              forOther: _forOther,
              name: _otherName,
              phone: _otherPhone,
              onChanged: (who) => setState(() {
                _forOther = who != null;
                if (who != null) {
                  _otherName.text = who.name;
                  _otherPhone.text = who.phone;
                }
              }),
            ),
          )
        : null;
    // The nearest drivers to the pickup, on the confirm step: real ones from
    // the server, else the demo cars on the map.
    final at = confirming ? _pickup?.point : null;
    final nearby = at == null
        ? const <String, double>{}
        : ref.watch(nearbyDriversProvider(roundedPoint(at))).value ?? const <String, double>{};
    int? etaFor(RideService s) {
      final km = nearestDriverKm(s, nearby) ??
          (at == null || _cars.isEmpty
              ? null
              : _cars.map((c) => const Distance().as(LengthUnit.Meter, at, LatLng(c.lat, c.lng)) / 1000).reduce(math.min));
      return km == null ? null : driverEtaMinutes(km);
    }

    final panel = _BookingPanel(
      disclaimerOffset: Offset(layout.disclaimer.$1, layout.disclaimer.$2),
      fareAdjusted: _biddingOn && _adjust != 0,
      etaFor: etaFor,
      currency: _currency,
      ongoing: _ongoing,
      forOthers: _forOthers,
      onOpenRide: (r) => context.push('/ride/${r.id}').then((_) => _checkOngoing()),
      pickup: _pickup,
      drop: _drop,
      route: _route,
      ai: _ai,
      routing: _routing,
      services: _services,
      service: _service,
      fareFor: _fareFor,
      onPickup: () => _choose(_PinTarget.pickup),
      onDrop: () => _choose(_PinTarget.drop),
      onService: (s) => setState(() {
        if (s.name != _serviceName) _adjust = 0;
        _serviceName = s.name;
      }),
      fare: _basis != null && !_routing
          ? ConfirmFareSection(
              recommended: _recommendedFor(_service),
              adjust: _biddingOn ? _adjust : 0,
              money: (v) => formatMoney(v, _currency),
              bidding: _biddingOn,
              onAdjust: (v) => setState(() => _adjust = v),
              onEdit: _openOfferFare,
              earn: coinEarnLabel(rideRewardCoins(_fareFor(_service), earnRate)),
              tollBooths: display?.showAiTollBooths ?? true ? tollBoothCount(ai) : 0,
              onTollBooths: ai == null ? null : () => showTollBooths(context, ai),
              tollCharges: (display?.showAiTollCharges ?? true) && ai?.tollsToShow != null
                  ? formatMoney(ai!.tollsToShow, _currency)
                  : null,
              trend: ai?.trend,
            )
          : null,
      onEditFare: _biddingOn && _basis != null && !_routing ? _openOfferFare : null,
      onOpenOngoing: () => context.push('/ride/${_ongoing!.id}').then((_) => _checkOngoing()),
      idle: _drop == null ? _homeParts(sections, blob, display) : null,
      footer: wide ? footer : null,
    );

    // While the fare is being worked out (Expo's "Calculating fare").
    Widget calculating(Widget body) => Stack(children: [
          Positioned.fill(child: body),
          if (confirming && _routing) const Positioned.fill(child: CalculatingFareOverlay()),
        ]);
    if (wide) {
      return Scaffold(
        body: calculating(Row(children: [
          SizedBox(width: 420, child: SafeArea(child: SingleChildScrollView(child: panel))),
          const VerticalDivider(width: 1),
          Expanded(child: map),
        ])),
      );
    }
    return Scaffold(
      body: calculating(PopScope(
        // Back on the confirm step leaves it, as its back arrow does.
        canPop: !confirming,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && confirming) _leaveConfirm();
        },
        child: MapSheetLayout(
          map: map,
          sheet: panel,
          min: confirming ? 0.5 : 0.22,
          // The main screen's sheet starts fully down; the rider drags it up.
          initial: confirming ? 0.55 : 0.22,
          hidden: _pinMoving,
          footer: footer,
          // Over the foot of the sheet, only while it is all the way up.
          aboveFooter: footer == null
              ? null
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  // Moved as Admin → Display → Disclaimer box sets it.
                  child: Transform.translate(
                    offset: Offset(layout.disclaimer.$1, layout.disclaimer.$2),
                    child: const ConfirmDisclaimer(),
                  ),
                ),
          front: confirming && !wide && layout.promoBar && layout.promoBarInFront ? Stack(children: [promoBar()]) : null,
        ),
      )),
    );
  }
}

class _BookingPanel extends StatelessWidget {
  const _BookingPanel({
    this.disclaimerOffset = Offset.zero,
    this.fareAdjusted = false,
    required this.ongoing,
    required this.pickup,
    required this.drop,
    required this.route,
    this.ai,
    required this.routing,
    required this.services,
    required this.service,
    required this.fareFor,
    required this.onPickup,
    required this.onDrop,
    required this.onService,
    this.fare,
    this.onEditFare,
    this.footer,
    required this.onOpenOngoing,
    this.idle,
    this.forOthers = const [],
    this.onOpenRide,
    this.currency = AppConfig.currency,
    this.etaFor,
  });

  /// Minutes for the nearest driver to reach the pickup, per vehicle; null
  /// when none is near.
  final int? Function(RideService)? etaFor;

  /// Rides on the go booked for other people, and how to open one.
  final List<RideRequest> forOthers;
  final ValueChanged<RideRequest>? onOpenRide;


  /// What the fares are quoted in: the pickup's tariff card's currency.
  final String currency;

  final RideRequest? ongoing;
  final Place? pickup;
  final Place? drop;
  final RouteInfo? route;
  final RouteEstimate? ai;

  /// Admin → Display → Disclaimer box height / left-right.
  final Offset disclaimerOffset;

  /// The rider has raised or lowered the chosen card's fare.
  final bool fareAdjusted;
  final bool routing;
  final List<RideService> services;
  final RideService service;
  final double Function(RideService) fareFor;
  final VoidCallback onPickup, onDrop, onOpenOngoing;
  final ValueChanged<RideService> onService;

  /// The fare inside the chosen vehicle's card ([ConfirmFareSection]).
  final Widget? fare;

  /// The chosen card's pencil: the rider's own fare, where bidding is on.
  final VoidCallback? onEditFare;

  /// The "Find a driver" bar, at the end of the panel where it isn't pinned
  /// to the screen (the wide layout).
  final Widget? footer;

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
        for (final r in forOthers) ...[
          Card(
            key: ValueKey('for-other-${r.id}'),
            child: ListTile(
              leading: const Icon(Icons.person_pin_circle_outlined),
              title: Text('For ${r.passengerName} · ${r.status.label}'),
              subtitle: Text('${r.pickupLabel} → ${r.dropLabel}', maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right),
              onTap: onOpenRide == null ? null : () => onOpenRide!(r),
            ),
          ),
          const SizedBox(height: 8),
        ],
        ?idle,
        // The confirm step (Expo ride-confirm): the addresses are on the
        // map, so the sheet opens on the vehicles.
        if (idle == null && drop == null) ...[
          Text('Where are you going?', style: t.textTheme.titleLarge),
          const SizedBox(height: 12),
          Card(
            child: Column(children: [
              ListTile(
                leading: Icon(Icons.trip_origin, color: Colors.green.shade700),
                title: Text(pickup?.name ?? 'Set pickup'),
                subtitle: pickup == null
                    ? null
                    : Text(pickup!.address, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: onPickup,
              ),
              const Divider(indent: 56),
              ListTile(
                leading: Icon(Icons.location_on, color: Colors.red.shade700),
                title: const Text('Where to?'),
                onTap: onDrop,
              ),
            ]),
          ),
        ],
        if (routing) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
        if (drop != null && route != null && !routing) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: RouteBasisLine(route: route!, ai: ai),
          ),
          for (final s in services)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: ConfirmServiceCard(
                service: s,
                price: formatMoney(fareFor(s), currency),
                selected: s.name == service.name,
                etaMinutes: etaFor?.call(s),
                onTap: () => onService(s),
                fare: s.name == service.name ? fare : null,
                onEdit: s.name == service.name ? onEditFare : null,
                // The arrows stand by the recommended fare: not on a card
                // whose fare the rider has raised or lowered.
                trend: s.name == service.name && fareAdjusted ? null : ai?.trend,
              ),
            ),
          // Who's riding is a toggle in the footer, under GET.coin; the note
          // to the driver is Options → Comments.
          const SizedBox(height: 28),
          // In the wide panel; on a phone it sits above the pinned footer.
          if (footer != null) ...[
            Transform.translate(offset: disclaimerOffset, child: const ConfirmDisclaimer()),
            const SizedBox(height: 16),
            footer!,
          ],
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

/// "Who's riding?" (a toggle under GET.coin, as inDrive's): off, the
/// rider; on, someone else, whose name and phone go on the request so the
/// driver meets and calls the right person. They are typed in a modal
/// ([showBookForSheet]); the row shows them, and its pen changes them.
class _WhoRiding extends StatelessWidget {
  const _WhoRiding({required this.forOther, required this.name, required this.phone, required this.onChanged});

  final bool forOther;
  final TextEditingController name, phone;

  /// Someone else with the details from the modal, or the rider (null).
  final ValueChanged<BookedFor?> onChanged;

  Future<void> _ask(BuildContext context) async {
    final who = await showBookForSheet(context, name: name.text, phone: phone.text);
    // Closed without Done: as it was (back off when nobody was set).
    if (who != null) {
      onChanged(who);
    } else if (!forOther || bookedFor(name.text, phone.text) == null) {
      onChanged(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final who = forOther ? bookedFor(name.text, phone.text) : null;
    return InkWell(
      key: const ValueKey('book-for-summary'),
      borderRadius: BorderRadius.circular(12),
      // Set: the row reopens the details to change them.
      onTap: who == null ? null : () => _ask(context),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, shape: BoxShape.circle),
            child: Icon(Icons.people_outline, size: 18, color: t.colorScheme.onSurface),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Book for someone else', style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                Text(
                  who == null ? 'Their name and phone go to the driver' : '${who.name} · ${who.phone}',
                  key: const ValueKey('book-for-who'),
                  style: t.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (who != null)
            IconButton(
              key: const ValueKey('book-for-edit'),
              tooltip: "Edit passenger's details",
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.edit_outlined, size: 18, color: t.colorScheme.onSurfaceVariant),
              onPressed: () => _ask(context),
            ),
          ConfirmSwitch(
            key: const ValueKey('who-riding'),
            value: forOther,
            onChanged: (v) => v ? _ask(context) : onChanged(null),
          ),
        ],
      ),
    );
  }
}
