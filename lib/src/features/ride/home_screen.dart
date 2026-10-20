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
import '../../core/overlay_back.dart';
import '../../core/payment_types.dart';
import '../../core/book_for.dart';
import '../../core/commission.dart' show Geo;
import '../../core/driver_eta.dart';
import '../../core/fare.dart';
import '../../core/fare_info.dart' show demandIncludesNote, demandUplift, demandUpliftLabel, fareRateLines;
import '../../core/scheduled_rides.dart';
import '../../core/search_timer.dart';
import '../../core/smart_address.dart' show isCoordinateLabel;
import '../../core/fare_tariff.dart';
import '../../core/fare_coins.dart';
import '../../core/fare_offer.dart';
import '../../core/format.dart';
import '../../core/place_gates.dart';
import '../../core/airport_areas.dart' show AirportArea;
import '../../core/airport_queue.dart';
import '../../data/airport_repository.dart';
import '../../data/place_gates_repository.dart' show airportAreasProvider;
import 'airport_door_sheet.dart';
import '../../core/region_pricing.dart';
import '../../core/service_tree.dart';
import '../../core/ride_bidding.dart';
import '../../core/ride_request_metadata.dart';
import '../../core/ride_rebook.dart';
import '../../core/home_sections.dart';
import '../../core/ride_confirm.dart';
import '../../core/ride_stops.dart';
import '../../core/sheet_min_height.dart';
import '../../widgets/side_menu_host.dart';
import '../../widgets/side_menu_tiles.dart';
import '../../widgets/toll_booths.dart';
import '../../core/route_estimate.dart';
import '../../data/scheduled_ride_repository.dart';
import '../../data/app_display_repository.dart';
import '../../data/coin_trade_repository.dart';
import '../../data/device_access.dart';
import '../../data/fare_coin_store.dart';
import '../../data/fare_tariff_repository.dart';
import '../../data/geo_service.dart';
import '../../data/live_tables.dart';
import '../../data/location_source.dart';
import '../../data/permission_probe.dart';
import '../../core/app_permissions.dart' show PermState;
import '../../core/permission_ask.dart';
import '../permissions/permission_actions.dart' show askPermission;
import '../../data/models.dart';
import '../../data/route_estimate_repository.dart';
import '../../data/ride_pet_repository.dart' show petConfigProvider;
import '../../data/ride_option_providers.dart';
import '../../core/ride_option_charges.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/map_drag_pin.dart';
import '../../widgets/map_recenter.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/map_type_button.dart';
import '../../widgets/ride_map.dart';
import 'pickup_time_sheet.dart';
import 'scheduled_rides_screen.dart';
import 'auto_accept.dart';
import 'book_for_sheet.dart';
import 'confirm_parts.dart';
import 'offer_fare_screen.dart';
import 'demo_ride.dart' show demoRiderProvider, demoRidesProvider;
import 'home_parts.dart';
import 'promo_parts.dart';
import '../../core/promo_codes.dart' show PromoCheckResult, PromoOffer, promoReasonText;
import '../../data/promo_repository.dart';
import 'place_search.dart';
import 'ride_tracking_screen.dart' show rideStreamProvider;
import '../meter/meter_auto_launch.dart';
import 'unavailable_sheet.dart';
import '../../admin/screens/commerce/get_coin.dart' show rideRewardCoins;
import '../../core/my_ride.dart' show FavouriteDriver, myRideMaxTargets;
import '../my_ride/my_ride_parts.dart';
import '../my_qr/direct_booking.dart';
import '../../core/my_qr.dart' show QrBookingError;
import '../../core/early_end.dart' show serviceTypeIds;
import '../my_ride/my_ride_settings.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/web_overlay_back.dart';

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

/// How long the AI fare estimate is waited for (PERF-33: was 30 s). The
/// confirm step shows "Calculating fare" meanwhile; past this, the standard
/// tariff's fare shows instead, and an AI answer later still is ignored.
const aiEstimateTimeout = Duration(seconds: 5);

/// A point of a trip GET.ride can't serve ([UnavailableAt]; [stop] is the
/// stop's index when it is a stop).
typedef TripGap = ({UnavailableAt at, int stop, CoverageGap gap, String? region, RegionBlock block});

/// Whether the pickup box stands at the top of the map instead of above the
/// pin: on a phone on its side, where the map above the sheet is too short.
bool homePillAtTop(Size size) => size.width > size.height && size.height < 500;

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

  // ---- Airports (0249) ----
  /// The doors chosen for a pickup at, or a drop-off at, an airport.
  AirportDoor? _pickupDoor;
  AirportDoor? _dropDoor;

  /// The server's airport fare for the confirm step, and what it was asked for.
  AirportQuote? _airportQuote;
  String? _airportQuoteKey;

  // ---- Promo codes (0242) ----
  /// The codes that apply to the trip on the confirm step.
  List<PromoOffer> _promoOffers = const [];

  /// The code the ride will be booked with, and whether it applied by itself.
  PromoOffer? _promo;
  bool _promoAuto = false;

  /// The rider took the auto-applied code off: it isn't put back.
  bool _promoRemoved = false;

  /// [_promo] was typed: a code hidden from the app isn't among the offers,
  /// so it is checked again when the trip changes.
  bool _promoTyped = false;

  /// The trip [_promoOffers] were read for, and the read in flight.
  String? _promoKey;
  int _promoSeq = 0;
  Timer? _promoTimer;

  /// The home bar: the rider stands in an auto-apply code's pickup area,
  /// as last asked at [_promoZoneAt].
  bool _promoZone = false;
  LatLng? _promoZoneAt;

  /// The confirm step's address card, measured so the route is framed in
  /// the map left between its bottom edge and the sheet.
  final _confirmCard = GlobalKey();

  /// The card's bottom edge, down from the map's top (0 until measured).
  double _confirmCardBottom = 0;

  /// The room kept above and below the route on the confirm map, as last laid out.
  double _confirmFitTop = 160, _confirmFitBottom = 64;

  /// Stops on the way, in order (up to [maxRideStops]).
  final List<Place> _stops = [];
  RouteInfo? _route;
  RouteEstimate? _ai;
  int _routeSeq = 0;

  /// A stop being added: its own steps show, then what it adds.
  bool _addingStop = false;

  /// The home sheet's content, the items it shows all the way down and its
  /// first item (the search bar), measured for the sheet's least height
  /// ([_foldHeight], [_floorHeight]).
  final _panelKey = GlobalKey();
  final _foldKey = GlobalKey();
  final _floorKey = GlobalKey();

  /// The pickup and current place for an open route sheet: an address that
  /// arrives after it opened still fills its From and Current location.
  final _routeEnds = ValueNotifier<RouteSheetEnds>((from: null, current: null));

  void _syncRouteEnds() {
    final now = (from: _pickup, current: _here);
    if (_routeEnds.value != now) _routeEnds.value = now;
  }

  /// How tall the sheet must be, all the way down, to show every item that
  /// is switched on and shown: its handle, the search bar, the vehicle bar,
  /// an upcoming ride's card, the recent places and the service boxes, with
  /// the gaps between them (the automatic part of its least height). 0 until
  /// measured.
  double _foldHeight = 0;

  /// The least the sheet ever rests at, whatever the admin's adjustment:
  /// the handle and the search bar (or the Where to? row) whole.
  double _floorHeight = 0;

  /// Measures [_foldHeight] and [_floorHeight] after a frame; a change sets
  /// the sheet's least height again.
  void _measureFold() {
    if (!mounted) return;
    final panel = _panelKey.currentContext?.findRenderObject() as RenderBox?;
    final fold = _foldKey.currentContext?.findRenderObject() as RenderBox?;
    final floor = _floorKey.currentContext?.findRenderObject() as RenderBox?;
    if (panel == null || fold == null || !panel.attached || !fold.attached) return;
    // The handle above the content, and a margin under the last item.
    double foot(RenderBox b) => b.localToGlobal(Offset(0, b.size.height), ancestor: panel).dy + 22 + 16;
    final need = foot(fold);
    final least = floor != null && floor.attached ? foot(floor) : 0.0;
    if ((need - _foldHeight).abs() > 1 || (least - _floorHeight).abs() > 1) {
      setState(() {
        _foldHeight = need;
        _floorHeight = least;
      });
    }
  }
  String? _serviceName;

  /// What the booking sheet offers: the admin Vehicle Services catalogue,
  /// or the built-in list while it loads or when it cannot be read.
  List<RideService> get _catalogue => _knownCatalogue ?? rideServices;

  /// The current catalogue, else the one this device last showed (drawn at
  /// once while the current one is read); null when there is neither yet.
  List<RideService>? get _knownCatalogue =>
      ref.read(rideServicesProvider).value ?? ref.read(cachedRideServicesProvider).value;

  /// The services offered at the pickup now: the region's scheduled rules
  /// and Services switches may take some away. Never empty — where nothing
  /// would be left the catalogue stands, and booking says why it can't.
  List<RideService> get _services {
    final all = _catalogue;
    final open = [for (final s in all) if (_availableNow(s)) s];
    return open.isEmpty ? all : open;
  }

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

  /// Admin → Display → Ride Confirm Layout, read when booking: a row the
  /// admin hides books as off, whatever the rider last chose.
  ConfirmLayout get _confirmLayout =>
      ConfirmLayout.fromSettings(ref.read(displaySettingsBlobProvider).value ?? const <String, dynamic>{});
  bool get _useCoinsOn => _useCoins && _confirmLayout.showCoin;
  bool get _autoAcceptOn => _autoAccept && _confirmLayout.showAutoAccept;
  bool get _forOtherOn => _forOther && _confirmLayout.showBookForOther;

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

  /// How fares are priced at the pickup (Admin → Country / States / Cities):
  /// whole amounts, and the tax on top.
  RegionPricing _pricing = RegionPricing.none;

  /// The services the pickup's region switches on (Admin → Country /
  /// States / Cities); null when it does not restrict them.
  Set<String>? _regionServices;

  /// The pickup's region rules (Admin → Country / States / Cities): when a
  /// service is offered, bid on, taxed and surcharged.
  RegionRuleContext _rules = RegionRuleContext.empty;

  /// The Service Settings ids of [s]'s Service types (its names).
  Set<String> _typesOf(RideService s) =>
      s.serviceTypes.isEmpty ? const {} : serviceTypeIds(s, ref.read(serviceBoxNamesProvider).value ?? const {});

  /// The Service Settings types offered at the pickup now, for the home
  /// service boxes: the region's Services switches, and its scheduled
  /// availability rules where it has any.
  Set<String>? _boxServices(Map<String, String> types) {
    if (!_rules.hasRules) return _regionServices;
    final now = DateTime.now().toUtc();
    return {for (final id in types.keys) if (_rules.available(types: {id}, nowUtc: now)) id};
  }

  /// [s] and every sub-service above it (Admin → Vehicle Services → Under),
  /// for the regions' sub-service switches.
  List<String> _lineageOf(RideService s) {
    final id = s.id;
    if (id == null) return const [];
    final masters = ref.read(serviceBoxNamesProvider).value ?? const <String, String>{};
    final tree = ServiceTree.build(
      [for (final e in masters.entries) ServiceEntry(id: e.key, name: e.value, category: masterServiceCategory)],
      [
        for (final r in _catalogue)
          if (r.id != null)
            ServiceEntry(
              id: r.id!,
              name: r.name,
              category: 'vehicle-services',
              parentIds: r.parentIds,
              typeNames: r.serviceTypes,
            ),
      ],
    );
    return tree.lineage(id);
  }

  bool _availableNow(RideService s, [RegionRuleContext? rules]) => (rules ?? _rules).available(
        types: _typesOf(s),
        vehicleType: s.id,
        lineage: _lineageOf(s),
        nowUtc: DateTime.now().toUtc(),
      );

  /// Whether [s]'s fare may be bid on now: a rule for it, else the
  /// region's Bidding switch.
  bool _biddingFor(RideService s, {RegionRuleContext? rules, bool? fallback}) => (rules ?? _rules)
      .bidding(types: _typesOf(s), vehicleType: s.id, nowUtc: DateTime.now().toUtc(), fallback: fallback ?? _biddingOn);

  /// How [s] is priced now: the region's pricing with the scheduled taxes
  /// and surcharges in force for it.
  RegionPricing _pricingFor(RideService s, {RegionRuleContext? rules, RegionPricing? base}) =>
      (rules ?? _rules).pricingFor(base ?? _pricing, types: _typesOf(s), vehicleType: s.id, nowUtc: DateTime.now().toUtc());
  LatLng? _biddingAt;

  /// The pickup the bidding, pricing and rules shown were last read for.
  LatLng? _pricedAt;
  bool _routing = false;
  RideRequest? _ongoing;

  /// Rides on the go that the rider booked for other people; any number,
  /// and none of them stands in the way of a booking (migration 0107).
  List<RideRequest> _forOthers = const [];

  /// "Who's riding?": the rider, or someone else (name and phone).
  bool _forOther = false;

  /// A pickup time for a scheduled ride (0189); null books now.
  DateTime? _scheduleAt;
  final _otherName = TextEditingController();
  final _otherPhone = TextEditingController();

  /// My Ride (favourite drivers first): null until the rider moves the
  /// switch, when their setting decides; and the drivers they picked (null:
  /// every one that can be offered it).
  bool? _myRideOn;
  Set<String>? _myRidePick;

  /// Where the rider's favourites are measured from: the pickup, rounded
  /// like the nearby drivers' lookup.
  ({double lat, double lng})? get _myRideAt {
    final p = _pickup?.point;
    if (p == null) return null;
    final (lat, lng) = roundedPoint(p);
    return (lat: lat, lng: lng);
  }

  List<FavouriteDriver> get _myRideFavourites {
    final at = _myRideAt;
    return at == null ? const [] : ref.read(bookingFavouritesProvider(at)).value ?? const [];
  }

  /// The favourites a booking now goes to first; empty with My Ride off.
  List<String> _myRideTargets(List<FavouriteDriver> favourites, MyRideSettings s) {
    if (!_confirmLayout.showMyRide || !(_myRideOn ?? s.onByDefault)) return const [];
    final pick = _myRidePick;
    if (pick == null) return defaultMyRideTargets(favourites, s.maxKm);
    return [
      for (final d in myRidePickOrder(favourites))
        if (pick.contains(d.driverId) && myRidePickable(d, s.maxKm)) d.driverId,
    ].take(myRideMaxTargets).toList();
  }

  /// The switch: on asks which drivers (dismissing leaves it off).
  Future<void> _pickMyRide(List<FavouriteDriver> favourites, MyRideSettings s) async {
    final current = _myRideTargets(favourites, s);
    final picked = await showMyRidePicker(
      context,
      drivers: favourites,
      selected: current.isNotEmpty ? current.toSet() : defaultMyRideTargets(favourites, s.maxKm).toSet(),
      maxKm: s.maxKm,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _myRideOn = picked.isNotEmpty;
      _myRidePick = picked.isEmpty ? null : picked;
    });
  }
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

  /// Bumped as the demo cars step: only the map rebuilds for them.
  final _carsTick = ValueNotifier<int>(0);

  /// The home map as last built, and what it was built from: the sheet's
  /// providers and settings rebuild the screen around it, not the map
  /// ([_homeMap]).
  Widget? _rideMap;
  List<Object?>? _rideMapDeps;

  /// [build]'s map, or the one already built while [deps] are unchanged.
  Widget _homeMap(List<Object?> deps, Widget Function() build) {
    if (_rideMap == null || !listEquals(deps, _rideMapDeps)) {
      _rideMapDeps = deps;
      _rideMap = build();
    }
    return _rideMap!;
  }

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
      _cars = [for (final car in _cars) stepDemoCar(car, c.latitude, c.longitude, _rnd)];
      _carsTick.value++;
    });
  }

  /// Back from the background: the rides on the go as they are now (one
  /// may have been taken, expired or booked from another device meanwhile).
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _locate();
    _checkOngoing();
    _lifecycle = AppLifecycleListener(onResume: () {
      _checkOngoing();
      _checkPromoZone(force: true);
    });
    // A ride to book again (its driver cancelled): filled in on the confirm
    // step, for the rider to send.
    ref.listenManual(rideRebookProvider, (_, next) {
      if (next != null) WidgetsBinding.instance.addPostFrameCallback((_) => _rebook());
    }, fireImmediately: true);
    // A TEKSI driver whose rate card asks for it lands on the meter, once
    // per launch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybeAutoLaunchMeter(context, ref);
    });
  }

  /// Moves on every change here, so a page opened over this one with a copy
  /// of the trip ("Offer your fare") follows its stops and fare.
  final _changes = ValueNotifier<int>(0);

  /// On the web, the confirm step has a browser history entry: Back steps
  /// back to the search as the back arrow does (web_overlay_back.dart).
  final _confirmBack = OverlayBackSlot(() => webOverlayBack);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _changes.value++;
    _confirmBack.set(_drop != null, _backFromConfirm);
  }

  @override
  void dispose() {
    _routeEnds.dispose();
    _confirmBack.set(false, _leaveConfirm);
    _changes.dispose();
    _carsTick.dispose();
    _carsTimer?.cancel();
    _lifecycle?.dispose();
    _promoTimer?.cancel();
    _expiry?.cancel();
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
        _armExpiry();
      }
    } catch (_) {}
  }

  /// Runs out the rider's open request on time while the app is open, even
  /// away from its ride screen; the server's job (0139) does it within a
  /// minute when nothing is open. The ride's stream then takes the card
  /// away and [_showExpired] says why.
  Timer? _expiry;
  String? _expiryFor;

  void _armExpiry() {
    final r = _ongoing;
    final id = r != null && r.status == RideStatus.open ? r.id : null;
    if (id == _expiryFor) return;
    _expiry?.cancel();
    _expiry = null;
    _expiryFor = id;
    if (r == null || id == null || r.createdAt == null) return;
    final left = searchTimeLeft(searchElapsed(r.createdAt, DateTime.now()), AppConfig.requestExpiry);
    _expiry = Timer(left + const Duration(seconds: 1), () async {
      if (!mounted) return;
      try {
        await ref.read(rideRepositoryProvider).expireStaleOpen();
      } catch (_) {}
    });
  }

  /// "Request expired" on the home screen (the ride screen says the same when
  /// it is the one open).
  bool _expiredShownFor(String id) => !_expiredShown.add(id);
  final _expiredShown = <String>{};

  void _showExpired(RideRequest r) {
    if (_expiredShownFor(r.id) || ModalRoute.of(context)?.isCurrent != true) return;
    showAppDialog<void>(id: 'home.show-expired',
      context: context,
      builder: (c) => AlertDialog(
        key: const ValueKey('home-request-expired'),
        title: const Text('Request expired'),
        content: Text(
          r.offerMe
              ? "We couldn't find a driver in time. Try again, perhaps with a higher fare."
              : "We couldn't find a driver in time. Please try again.",
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
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
    unawaited(_locateAsked());
  }

  /// Tapped, so location refused or switched off is asked for again, or,
  /// where the phone won't ask any more, explained with the way to Settings.
  Future<void> _locateAsked() async {
    final probe = ref.read(permissionProbeProvider);
    final (on, state) = await probe.location();
    if (!on || state == PermState.denied || state == PermState.notAsked) {
      if (!mounted) return;
      await askPermission(context, probe, AskKind.location);
      if (!mounted) return;
    }
    await _locate(recenter: true);
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

  /// The rider and the pickup on the last known (or a quick) fix at once,
  /// then moved onto the accurate one when it comes (PERF-4): the pickup
  /// only while it is still the one set here and no destination is chosen.
  Future<void> _locate({bool recenter = false}) async {
    Place? set;
    await for (final p in locateFastThenFine(ref.read(locationSourceProvider))) {
      if (!mounted) return;
      setState(() => _me = p);
      _checkPromoZone();
      if (recenter && recenterMap(_map, p, zoom: homeStreetZoom, offset: _focusOffset)) _pinOnto(p);
      final place = await ref.read(geoServiceProvider).reverse(p);
      if (!mounted) return;
      setState(() {
        _here = place;
        if (_pickup == null || (identical(_pickup, set) && _drop == null)) _pickup = set = place;
      });
      _updateRoute();
    }
  }

  /// The first point of the trip GET.ride can't serve (outside every
  /// region, or in a blocked one), once the route's check has answered.
  TripGap? _gap;

  /// Checks the pickup, each stop and the destination against the regions
  /// (Admin → Country / States / Cities): the first one GET.ride can't
  /// serve, or null.
  Future<TripGap?> _findGap(Place a, List<Place> stops, Place b) async {
    final rides = ref.read(rideRepositoryProvider);
    final geo = ref.read(geoServiceProvider);
    Future<({CoverageGap gap, BiddingRegion? region})?> check(LatLng p, {required bool pickup}) async {
      try {
        return await rides.coverageAt(p, () => geo.reverseArea(p), pickup: pickup);
      } catch (_) {
        return null;
      }
    }

    final points = [a, ...stops, b];
    final found = await Future.wait([
      for (final (i, p) in points.indexed) check(p.point, pickup: i == 0),
    ]);
    for (var i = 0; i < points.length; i++) {
      final g = found[i];
      if (g == null) continue;
      return (
        at: i == 0 ? UnavailableAt.pickup : (i == points.length - 1 ? UnavailableAt.drop : UnavailableAt.stop),
        stop: i - 1,
        gap: g.gap,
        region: g.region?.name,
        block: g.region?.block ?? RegionBlock.both,
      );
    }
    return null;
  }

  /// Bolt's "currently unavailable": slides up with the way out — change
  /// the pickup or destination, or drop the stop.
  void _showGap(TripGap g) => unawaited(showServiceUnavailable(
        context,
        at: g.at,
        gap: g.gap,
        region: g.region,
        block: g.block,
        onChange: () {
          switch (g.at) {
            case UnavailableAt.pickup:
              _choose(_PinTarget.pickup);
            case UnavailableAt.drop:
              _choose(_PinTarget.drop);
            case UnavailableAt.stop:
              if (g.stop >= 0 && g.stop < _stops.length) setState(() => _stops.removeAt(g.stop));
              _updateRoute();
          }
        },
      ));

  Future<void> _checkCoverage(int seq, Place a, List<Place> stops, Place b) async {
    final g = await _findGap(a, stops, b);
    if (!mounted || seq != _routeSeq) return;
    setState(() => _gap = g);
    if (g != null) _showGap(g);
  }

  /// [onRouted] is told once the map route is in, before the AI's estimate.
  Future<void> _updateRoute({VoidCallback? onRouted}) async {
    final a = _pickup, b = _drop;
    final seq = ++_routeSeq;
    // A new route is a new recommended fare: any offer starts again from it.
    _adjust = 0;
    _gap = null;
    if (a != null) unawaited(_checkBidding(a.point));
    if (a == null || b == null) {
      setState(() {
        _route = null;
        _ai = null;
      });
      return;
    }
    // Whether GET.ride serves the trip at all, alongside the route.
    unawaited(_checkCoverage(seq, a, List.of(_stops), b));
    setState(() {
      _routing = true;
      _ai = null;
    });
    // The map route draws the line; the AI's traffic-aware estimate, when
    // there is one, is what the fare is priced on (Expo ride-confirm). A
    // trip with stops is asked about through them, in their order, so adding
    // or rearranging stops prices (and judges high or low) the trip again.
    final via = [for (final p in _stops) p.point];
    // The proxy may try several keys; past this (or on an error) the map
    // route prices it with the standard tariff, and an AI answer that comes
    // later still is dropped with the timed-out future.
    final aiFuture = ref
        .read(routeEstimateRepositoryProvider)
        .estimateDetailed(a.point, b.point, via: via)
        .timeout(aiEstimateTimeout, onTimeout: () => null);
    final r = await ref.read(geoServiceProvider).route(a.point, b.point, via: via);
    if (!mounted || seq != _routeSeq) return;
    setState(() => _route = r);
    onRouted?.call();
    // Both before the fare shows ("Calculating fare" stays up through the AI
    // estimate, PERF-33: for 5 s at most): the fare shown, and booked, is
    // the one fare for this route and never changes a moment later.
    ({RouteEstimate? estimate, bool unavailable})? ai;
    try {
      ai = await aiFuture;
    } catch (_) {
      ai = null;
    }
    if (!mounted || seq != _routeSeq) return;
    setState(() {
      // Only an estimate through every stop prices this trip.
      _ai = estimateCoversStops(ai?.estimate, via.length) ? ai?.estimate : null;
      _routing = false;
    });
    if (ai != null && ai.unavailable && mounted) {
      unawaited(showAppDialog<void>(id: 'home.update-route',
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
      // A stop, on the trip it joins.
      fieldLabel: 'Stop',
      routeLine: addStopRouteLine(_pickup, _stops, _drop),
    );
    if (pick == null || !mounted) return;
    final place = pick.place;
    if (place == null) return showInfo(context, 'Search for the stop by name or address.');
    // What the trip was before the stop, to show what it adds and to go
    // back to on Cancel.
    final before = (route: _route, ai: _ai, adjust: _adjust, fare: _fareFor(_service), minutes: _basis?.durationMin);
    final step = ValueNotifier(addStopSteps[0]);
    final progress = showAddStopProgress(context, step);
    setState(() {
      _addingStop = true;
      _stops.add(place);
    });
    await _updateRoute(onRouted: () => step.value = addStopSteps[1]);
    step.value = addStopSteps[2];
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    await progress;
    step.dispose();
    if (!mounted) return;
    setState(() => _addingStop = false);
    final after = _basis;
    final extra = _fareFor(_service) - before.fare;
    // Admin → Display → "Ask before adding a stop" off: added at once.
    final ask = ConfirmLayout.fromSettings(
      ref.read(displaySettingsBlobProvider).value ?? const <String, dynamic>{},
    ).confirmAddStop;
    if (after != null && !ask) return;
    final add = after != null &&
        await confirmAddStop(
          context,
          stopName: place.name,
          extraFare: extra <= 0 ? 'No extra cost' : '+${_fareMoney(extra)}',
          extraMinutes: after.durationMin - (before.minutes ?? after.durationMin),
        );
    if (!mounted || add) return;
    if (after == null) showInfo(context, "Couldn't work out the route through that stop.");
    // Cancelled: the trip as it was, without asking for its route again.
    _routeSeq++;
    setState(() {
      _stops.remove(place);
      _route = before.route;
      _ai = before.ai;
      _adjust = before.adjust;
      _routing = false;
    });
  }

  /// [rideRebookProvider]'s trip on the confirm step: the same pickup,
  /// stops, drop-off, vehicle and payment, and the same fare offered again
  /// where the rider may offer one (else the fare priced now). Sent, as any
  /// booking, by the rider's own tap.
  Future<void> _rebook() async {
    if (!mounted) return;
    final trip = ref.read(rideRebookProvider.notifier).take();
    if (trip == null) return;
    setState(() {
      _pickup = trip.pickup;
      _stops
        ..clear()
        ..addAll(trip.stops.take(maxRideStops));
      _drop = trip.drop;
      if (trip.service != null) _serviceName = trip.service;
      if (trip.payment != null) _paymentPick = trip.payment!;
    });
    final seq = _routeSeq + 1;
    await _updateRoute();
    final fare = trip.fare;
    if (!mounted || seq != _routeSeq || fare == null || !_biddingFor(_service)) return;
    setState(() => _adjust = fare - _recommendedFor(_service));
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

  /// What was typed for the destination now on the map ('' or null when
  /// it was picked without typing), for the search to open on again.
  String? _dropQuery;

  /// [again]: the trip Back on the confirm step came from, its destination
  /// and stops, searched again from what was typed for it.
  Future<void> _choose(_PinTarget target, {({Place to, String query, List<Place> stops})? again}) async {
    final pickup = target == _PinTarget.pickup;
    // One route sheet for both ends: From over To, opened on the one tapped.
    _syncRouteEnds();
    final pick = await showPlaceSearch(
      context,
      title: 'Enter your route',
      near: _me ?? _pickup?.point,
      current: _here,
      usage: GateUsage.drop,
      from: _pickup,
      to: again?.to ?? _drop,
      routeEnds: true,
      startOnFrom: pickup,
      live: _routeEnds,
      initialQuery: again?.query ?? '',
    );
    if (pick == null || !mounted) return;
    // A new destination for the trip Back came from keeps its stops.
    if (again != null && !pick.from && !pick.pickOnMap && _drop == null && _stops.isEmpty) {
      _stops.addAll(again.stops);
    }
    if (!pickup && !pick.from) _dropQuery = pick.query;
    // The route's "From", changed in the same dialog: the pickup.
    final toPickup = pickup || pick.from;
    if (pick.pickOnMap) {
      setState(() => _pinTarget = toPickup ? _PinTarget.pickup : target);
      showInfo(context, 'Tap the map to set the ${toPickup ? 'pickup' : 'destination'}');
      return;
    }
    setState(() {
      if (toPickup) {
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
    if (target != _PinTarget.pickup) _dropQuery = null;
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

  /// An admin changed a region (bidding, pricing, services, its rules): the
  /// pickup's are read again, so the open booking sheet follows at once.
  void _regionsChanged() {
    ref.read(rideRepositoryProvider).forgetRegions();
    _biddingAt = null;
    final a = _pickup;
    if (a != null) unawaited(_checkBidding(a.point));
  }

  /// Whether riders may set their own fare at [pickup]; checked once per
  /// pickup (and again when an admin changes a region). Unknown is off,
  /// which is today's fixed fare.
  Future<void> _checkBidding(LatLng pickup) async {
    if (_biddingAt == pickup) return;
    _biddingAt = pickup;
    _pickupArea = null;
    // One geocode of the pickup serves the bidding check and the tariff.
    final area = ref.read(geoServiceProvider).reverseArea(pickup);
    unawaited(area.then((a) {
      if (mounted && _biddingAt == pickup) setState(() => _pickupArea = a);
    }, onError: (_) {}));
    final rides = ref.read(rideRepositoryProvider);
    // Each on its own: an unreadable pricing never switches bidding off.
    Future<T> orElse<T>(Future<T> Function() f, T fallback) async {
      try {
        return await f();
      } catch (_) {
        return fallback;
      }
    }

    final onF = orElse(() => rides.biddingEnabledFor(pickup, () => area), false);
    final pricingF = orElse(() => rides.pricingFor(pickup, () => area), RegionPricing.none);
    final servicesF = orElse(() => rides.servicesFor(pickup, () => area), null);
    final rulesF = orElse(() => rides.ruleContextFor(pickup, () => area), RegionRuleContext.empty);
    final on = await onF;
    final pricing = await pricingF;
    final services = await servicesF;
    final rules = await rulesF;
    if (!mounted || _biddingAt != pickup) return;
    // Read again for the same pickup (a region changed, or the live link
    // came back after the screen was unlocked) while the pickup's place
    // can't be looked up: what it was priced at stays, rather than a fare
    // without its rounding until the next read.
    if (_pricedAt == pickup && await orElse(() => area, null) == null) return;
    if (!mounted || _biddingAt != pickup) return;
    setState(() {
      _pricedAt = pickup;
      _rules = rules;
      _biddingOn = on;
      _pricing = pricing;
      _regionServices = services;
    });
  }

  /// The booking tariff card for [s] at the pickup (Admin → Fare tariffs):
  /// its own card, its service type's, or one for every service; null for
  /// the built-in TEKSI tariff.
  FareTariff? _tariffFor(RideService s) {
    final a = _pickupArea;
    return resolveFareTariff(
      ref.read(fareTariffsProvider).value ?? const [],
      Geo(country: a?.country, state: a?.state, city: a?.city, suburb: a?.suburb),
      vehicleService: s.id,
      serviceTypes: _typesOf(s),
    );
  }

  /// The currency the trip is quoted and booked in: the selected service's
  /// card's.
  String get _currency => _tariffFor(_service)?.currency ?? AppConfig.currency;

  /// [s]'s fare on the AI's traffic-aware basis, before the options' charges.
  double _routeFareFor(RideService s) {
    final b = _basis;
    return b == null
        ? 0
        : quoteFare(_tariffFor(s), b.distanceKm, b.durationMin, multiplier: s.multiplier, fallbackCurrency: AppConfig.currency)
            .fare;
  }

  /// The options as they can be booked now: what the admin no longer offers
  /// (Display Settings → Ride Options) is off.
  RideOptions get _bookable =>
      ref.read(rideOptionsConfigProvider).allowed(_options, catalogue: ref.read(assistanceCatalogueProvider));

  /// What the rider's pets and assistance add to a route fare of [fare]
  /// (Admin → Display Settings → Ride Options; nothing until set).
  List<OptionChargeLine> _optionChargesOn(double fare) => rideOptionCharges(
        _bookable,
        fare,
        pets: ref.read(petConfigProvider),
        assistance: ref.read(assistanceCatalogueProvider),
      );

  /// [s]'s recommended fare: the route's, plus what the options add, so the
  /// vehicle cards, the offer and the booked fare all include them.
  double _recommendedFor(RideService s) {
    if (_basis == null) return 0;
    final route = _routeFareFor(s);
    return _pricing.roundFare(route + optionChargesTotal(_optionChargesOn(route)));
  }

  /// [s]'s fare priced on the plain road route, without the AI's traffic:
  /// what it would be off the trend (with the options, as the fare is).
  double _usualFor(RideService s) {
    final r = _route;
    if (r == null) return 0;
    final route =
        quoteFare(_tariffFor(s), r.distanceKm, r.durationMin, multiplier: s.multiplier, fallbackCurrency: AppConfig.currency)
            .fare;
    return _pricing.roundFare(route + optionChargesTotal(_optionChargesOn(route)));
  }

  /// The fare promo codes work on: less the option charges when the admin
  /// keeps them out of the discount (Ride Options → Charges); the server
  /// does the same (migration 0248).
  double get _promoFare {
    final fare = _fareFor(_service);
    if (ref.read(optionChargeRulesProvider).promo) return fare;
    final left = fare - optionChargesTotal(_optionCharges);
    return left < 0 ? 0 : (left * 100).roundToDouble() / 100;
  }

  /// The selected service's option charges, as stamped on the ride.
  List<OptionChargeLine> get _optionCharges => _basis == null ? const [] : _optionChargesOn(_routeFareFor(_service));

  /// "Pet charge RM10 · Assistance charge RM5", under the fares; null for
  /// none.
  String? get _optionChargesNote => optionChargesText(
        _optionCharges,
        (v) => formatMoney(v, _currency, v == v.roundToDouble() ? 0 : _pricing.fareDecimals),
      );

  /// What high demand adds to [s]'s recommended fare: the fare on the AI's
  /// traffic-aware basis over the same on the plain route, while the trend
  /// is up; null otherwise.
  ({double amount, double factor})? _upliftFor(RideService s) {
    if (_ai?.trend?.direction != FareTrendDirection.up || _basis == null) return null;
    return demandUplift(_recommendedFor(s), _usualFor(s));
  }

  /// What [s] is booked at: the rider's offer on the selected service where
  /// bidding is on, else the recommended fare — rounded as the region prices
  /// fares (a whole amount, rounded up, where it asks for one).
  double _fareFor(RideService s, {bool? biddingOn}) {
    final recommended = _recommendedFor(s);
    if (s.name != _service.name) return recommended;
    return _pricing.roundFare(offeredFare(recommended: recommended, adjust: _adjust, biddingOn: biddingOn ?? _biddingFor(s)));
  }

  /// A fare as the region shows it: without decimals where fares are whole.
  String _fareMoney(double v) => formatMoney(v, _currency, _pricing.fareDecimals);

  /// The selected service's surcharges and taxes on its fare, one per line
  /// ("+ Night surcharge: RM 2.00"); null when there are none.
  String? _chargeLines() {
    final lines = _pricingFor(_service).linesFor(_fareFor(_service));
    final airport = _airportQuoteNow();
    if (lines.isEmpty && airport == null) return null;
    return [
      // The airport fare, as the server books it (0249): how it is made up,
      // its charges and the total.
      if (airport != null) ...[
        for (final l in airport.lines) '${l.charge ? '+ ' : ''}${l.label}: ${formatMoney(l.amount, _currency)}',
        'Airport fare: ${formatMoney(airport.total, _currency)}',
      ],
      for (final l in lines) '+ ${l.label}: ${formatMoney(l.amount, _currency)}',
    ].join('\n');
  }

  /// The server's airport fare for the trip on the confirm step, when it
  /// starts or ends at an airport; asked for again when the trip, service
  /// or fare changes. Null until it answers, or with no airport.
  AirportQuote? _airportQuoteNow() {
    final a = _pickup, b = _drop, basis = _basis;
    if (a == null || b == null || basis == null) return null;
    // The fare as booked, option charges in it (0248): the server takes them
    // out for the airport fare and adds them back after its minimum.
    final normal = _fareFor(_service);
    final options = [for (final c in _optionCharges) c.toJson()];
    final key = '${a.point.latitude},${a.point.longitude}|${b.point.latitude},${b.point.longitude}|'
        '${_service.name}|${basis.distanceKm.toStringAsFixed(2)}|$normal|$options';
    if (key == _airportQuoteKey) return _airportQuote;
    _airportQuoteKey = key;
    _airportQuote = null;
    final areas = ref.read(airportAreasProvider).value ?? const [];
    if (airportAt(areas, a.point) == null && airportAt(areas, b.point) == null) return null;
    final area = _pickupArea;
    ref
        .read(airportRepositoryProvider)
        .quote(
          pickup: a.point,
          drop: b.point,
          service: _service.name,
          km: basis.distanceKm,
          normalFare: normal,
          country: area?.country,
          state: area?.state,
          city: area?.city,
          suburb: area?.suburb,
          optionCharges: options,
        )
        .then((q) {
          if (mounted && _airportQuoteKey == key) setState(() => _airportQuote = q);
        })
        .catchError((_) {});
    return null;
  }

  /// Before booking: the door at each end that is at an airport which asks
  /// for one (0249). False when the rider closed a door sheet.
  Future<bool> _chooseAirportDoors() async {
    final a = _pickup, b = _drop;
    if (a == null || b == null) return true;
    List<AirportArea> areas;
    try {
      areas = await ref.read(airportAreasProvider.future);
    } catch (_) {
      return true;
    }
    final atPickup = airportAt(areas, a.point), atDrop = airportAt(areas, b.point);
    if (atPickup == null && atDrop == null) {
      _pickupDoor = _dropDoor = null;
      return true;
    }
    final doors = await ref.read(airportDoorsProvider.future).catchError((_) => const <AirportDoor>[]);
    final settings = await ref.read(airportSettingsProvider.future).catchError((_) => const <String, AirportSettings>{});
    Future<AirportDoor?> ask(AirportArea airport, AirportSide side, Place at, AirportDoor? current) async {
      final list = doorsFor(doors, airport.id, side);
      final s = settings[airport.id];
      if (list.isEmpty) return null;
      if (current != null && list.any((d) => d.id == current.id)) return current;
      // A door picked in the place search (its gate) counts as chosen.
      final fromSearch = list.where((d) =>
          d.lat == at.point.latitude && d.lng == at.point.longitude && at.name.endsWith(d.name)).firstOrNull;
      if (fromSearch != null) return fromSearch;
      if (s != null && !s.doorRequired(side)) return null;
      if (!mounted) return null;
      return showAirportDoorSheet(
        context,
        airportName: airport.name,
        side: side,
        doors: list,
        charge: s?.chargeFor(side),
        currency: _currency,
      );
    }

    AirportDoor? pick, drop;
    if (atPickup != null) {
      pick = await ask(atPickup, AirportSide.pick, a, _pickupDoor);
      final required = doorsFor(doors, atPickup.id, AirportSide.pick).isNotEmpty &&
          (settings[atPickup.id]?.pickDoorRequired ?? true);
      if (pick == null && required) return false;
    }
    if (atDrop != null) {
      drop = await ask(atDrop, AirportSide.drop, b, _dropDoor);
      final required = doorsFor(doors, atDrop.id, AirportSide.drop).isNotEmpty &&
          (settings[atDrop.id]?.dropDoorRequired ?? true);
      if (drop == null && required) return false;
    }
    if (mounted) {
      setState(() {
        _pickupDoor = pick;
        _dropDoor = drop;
      });
    }
    return true;
  }

  /// A fixed-fare vehicle's (i) (inDrive's): what [s] is priced on at the
  /// pickup, with this trip's coins, tolls, taxes and fare trend.
  void _showFareInfo(RideService s, RouteEstimate? ai, bool showTolls, String? earn) {
    showFareInfo(
      context,
      FareInfoSheet(
        service: s,
        rates: fareRateLines(_tariffFor(s), s, fallbackCurrency: AppConfig.currency),
        earn: earn,
        tollCharges: showTolls && ai?.tollsToShow != null
            ? formatMoney(ai!.tollsToShow, _currency)
            : null,
        // No trip yet (the home bar's (i)): no fare to work a tax out on.
        tax: _basis == null ? null : _chargeLines(),
        trend: ai?.trend,
      ),
    );
  }

  /// "Offer your fare" (inDrive's page): the fare typed in, with the
  /// payment, auto-accept and entrance alongside; "Find a driver" there
  /// books straight away.
  Future<void> _openOfferFare() async {
    final style = currencyStyles[_currency.trim().toUpperCase()];
    // What the page holds as it changes: kept when it is left by the iOS
    // edge swipe, which pops it with no result.
    OfferFareResult? latest;
    final pushed = await Navigator.of(context).push<OfferFareResult>(
      AppPageRoute(id: 'home.open-offer-fare',
        // Rebuilt on every change here: a stop added, removed or moved there
        // changes the route label and, once the route is worked out, the fare.
        builder: (_) => ValueListenableBuilder<int>(
          valueListenable: _changes,
          builder: (_, _, _) => OfferFareScreen(
            recommended: _recommendedFor(_service),
            current: _recommendedFor(_service) + _adjust,
            currencyLabel: (style?.symbol ?? _currency).trim(),
            money: _fareMoney,
            fareDecimals: _pricing.fareDecimals,
            payment: _payment,
            payments: _payments,
            autoAccept: _autoAcceptOn,
            entrance: _entrance,
            pickupName: _pickup?.name ?? 'Pickup',
            routeLabel: _stops.isEmpty ? (_drop?.name ?? 'Destination') : '${_stops.length + 1} route stops',
            onRoute: _drop == null
                ? null
                : () => showRouteStopsSheet(context, destinations: [..._stops, _drop!], onChanged: _setDestinations),
            onAddStop: _stops.length < maxRideStops ? _addStop : null,
            optionsOn: _options.any,
            // Always there: Comments stays when every option is hidden.
            onOptions: (c) => showRideOptionsSheet(
              c,
              options: _options,
              onChanged: (o) => setState(() => _options = o),
              note: _note,
              petConfig: ref.read(petConfigProvider),
              config: ref.read(rideOptionsConfigProvider),
              assistance: ref.read(assistanceCatalogueProvider),
            ),
            onChanged: (v) => latest = v,
          ),
        ),
      ),
    );
    final r = pushed ?? latest;
    if (r == null || !mounted) return;
    setState(() {
      if (r.fare != null) _adjust = r.fare! - _recommendedFor(_service);
      _paymentPick = r.payment;
      _autoAccept = r.autoAccept;
      _entrance = r.entrance;
    });
    final canFind = !_booking &&
        !_routing &&
        _basis != null &&
        !(_forOtherOn && bookedFor(_otherName.text, _otherPhone.text) == null);
    if (r.find && canFind) await _find();
  }

  Future<void> _book() async {
    final a = _pickup, b = _drop, r = _basis;
    if (a == null || b == null || r == null) return;
    final forWhom = _forOtherOn ? bookedFor(_otherName.text, _otherPhone.text) : null;
    if (_forOtherOn && forWhom == null) {
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
    // Checked again as it is booked: a region blocked since, or a trip
    // booked before the route's check answered, never goes out.
    final gap = await _findGap(a, List.of(_stops), b);
    if (gap != null) {
      if (mounted) {
        setState(() => _gap = gap);
        _showGap(gap);
      }
      return;
    }
    if (!mounted) return;
    final myRideSettings = ref.read(myRideSettingsProvider).value ?? const MyRideSettings();
    // GET.now: a scanned driver's code books that driver alone, without
    // My Ride's favourites.
    final direct = ref.read(directBookingProvider);
    final myRideTargets = direct != null ? const <String>[] : _myRideTargets(_myRideFavourites, myRideSettings);
    setState(() => _booking = true);
    try {
      final profile = await ref.read(profileProvider.future);
      final rides = ref.read(rideRepositoryProvider);
      // One geocode of the pickup serves the bidding check and the row's
      // geography; it and the IP lookup run alongside the bidding check.
      final areaLookup = ref.read(geoServiceProvider).reverseArea(a.point);
      final ipLookup = rides.publicIp();
      final regionOn = await rides.biddingEnabledFor(a.point, () => areaLookup);
      // The booking-time pricing, as the bidding switch: whole fares and tax
      // go on the row, so every screen after it prices the ride the same.
      var base = _pricing;
      try {
        base = await rides.pricingFor(a.point, () => areaLookup);
      } catch (_) {}
      var rules = _rules;
      try {
        rules = await rides.ruleContextFor(a.point, () => areaLookup);
      } catch (_) {}
      if (mounted && (base != _pricing || !identical(rules, _rules))) {
        setState(() {
          _pricing = base;
          _rules = rules;
        });
      }
      // The rules at the moment of booking decide: a service whose hours
      // have just ended is not booked, and its bidding and charges are now's.
      final scheduleAt = _scheduleAt;
      if (scheduleAt != null) {
        final c = await ref.read(scheduledRidesConfigProvider.future);
        final problem = !c.enabled
            ? 'Scheduled rides are not available.'
            : pickupTimeProblem(scheduleAt, DateTime.now(), c);
        if (problem != null) {
          if (mounted) showInfo(context, problem);
          return;
        }
      } else if (!_availableNow(_service, rules)) {
        if (mounted) showInfo(context, '${_service.name} is not available here right now.');
        return;
      }
      final offerMe = _biddingFor(_service, rules: rules, fallback: regionOn);
      final pricing = _pricingFor(_service, rules: rules, base: base);
      // What the admin still offers, and what it adds to the fare.
      final options = _bookable;
      final optionCharges = _optionCharges;
      // The admin's names for the options: in the note, and stamped on the
      // ride so the driver reads it as it was booked.
      final optionsConfig = ref.read(rideOptionsConfigProvider);
      final optionNames = optionsConfig.namesFor(options);
      // One of the admin's demo riders (Admin → Display Settings → Demo
      // riders): the request stays on this phone, where the demo drivers
      // answer it. Nothing is written, pushed or seen by a real driver. A
      // booking for later, or for one scanned driver, is a real one.
      if (scheduleAt == null && direct == null && ref.read(demoRiderProvider)) {
        final req = ref.read(demoRidesProvider.notifier).create({
          'rider_id': ref.read(currentUserIdProvider),
          'rider_name': profile?.name,
          'service': _service.name,
          'payment_mode': _payment,
          'pickup_name': a.name,
          'pickup_address': a.address,
          'pickup_lat': a.point.latitude,
          'pickup_lng': a.point.longitude,
          'drop_name': b.name,
          'drop_address': b.address,
          'drop_lat': b.point.latitude,
          'drop_lng': b.point.longitude,
          'distance_km': double.parse(r.distanceKm.toStringAsFixed(2)),
          'duration_min': r.durationMin.round(),
          'fare': _fareFor(_service, biddingOn: offerMe),
          'ride_fare': _fareFor(_service, biddingOn: offerMe),
          'currency': _currency,
          'passengers': options.passengers,
          if (options.pets.isNotEmpty) 'pets': [for (final p in options.pets) p.toJson()],
          if (options.assistance != null) 'assistance': options.assistance!.toJson(),
          if (optionCharges.isNotEmpty) 'option_charges': [for (final c in optionCharges) c.toJson()],
          if (optionNames.isNotEmpty) 'option_names': optionNames,
          'offer_me': offerMe,
          if (_stops.isNotEmpty) 'stops': [for (final p in _stops.take(maxRideStops)) stopToJson(p)],
          if (forWhom != null) 'booked_for_name': forWhom.name,
          if (forWhom != null) 'booked_for_phone': forWhom.phone,
          if (pricing != RegionPricing.none) ...pricing.toRideColumns(),
        });
        if (mounted) context.push('/ride/${req.id}').then((_) => _checkOngoing());
        return;
      }
      AreaInfo? area;
      try {
        area = await areaLookup.timeout(const Duration(seconds: 5));
      } catch (_) {}
      final metadata = {
        ...rideRequestMetadata(
          area: area,
          ipAddress: await ipLookup,
          gender: profile?.raw['gender'] as String?,
          riderPhoto: profile?.avatarUrl,
        ),
        // The doors chosen at an airport (0249; checked and named by the server).
        if (_pickupDoor case final d?) 'pickup_door_id': d.id,
        if (_dropDoor case final d?) 'drop_door_id': d.id,
      };
      final booked = await rides.createRequest(
            scheduleAt: scheduleAt,
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
            passengers: options.passengers,
            note: driverNote(options: options, entrance: _entrance, note: _note.text, names: optionsConfig.renamed),
            pets: options.pets,
            assistance: options.assistance,
            optionCharges: optionCharges,
            optionNames: optionNames,
            riderName: profile?.name,
            riderPhone: profile?.phone,
            deviceOs: kIsWeb ? 'web' : defaultTargetPlatform.name,
            offerMe: offerMe,
            autoAcceptFare: _autoAcceptOn && offerMe ? _fareFor(_service, biddingOn: offerMe) : null,
            stops: List.of(_stops),
            metadata: metadata,
            bookedFor: forWhom,
            currency: _currency,
            pricing: pricing,
            timezone: rules.timezone,
            targetDriverIds: myRideTargets,
            myRideMaxKm: myRideTargets.isEmpty ? null : myRideSettings.maxKm,
            directQrToken: scheduleAt == null ? direct?.token : null,
            // Checked again by the server: at booking, and for a ride for
            // later at its pickup time and again when it is dispatched.
            promoCodeId: _promo?.codeId,
          );
      final later = booked.later;
      final promoSent = _promo;
      if (later != null && promoSent != null && later.promoCode == null && mounted) {
        showInfo(context, 'Promo ${promoSent.code} was not applied. ${promoReasonText(later.promoError)}');
      }
      if (later != null) {
        ref.invalidate(myScheduledRidesProvider);
        ref.invalidate(owedFeesProvider);
        if (!mounted) return;
        setState(() => _scheduleAt = null);
        _leaveConfirm();
        await showNotice(
          context,
          title: 'Ride scheduled',
          message:
              'Pickup ${pickupLabel(confirmedPickupAt(later, scheduleAt))}'
              '${later.bookedForName == null ? '' : ' for ${later.bookedForName}'}. '
              "We'll find your driver before then and let you know.",
        );
        if (mounted) context.push('/trips/scheduled');
        return;
      }
      final req = booked.now!;
      if (direct != null) {
        ref.read(directBookingNamesProvider.notifier).remember(req.id, direct.driverName);
        ref.read(directBookingProvider.notifier).clear();
      }
      if (_autoAcceptOn && offerMe) {
        ref.read(autoAcceptProvider.notifier).set(req.id, _fareFor(_service, biddingOn: offerMe));
      }
      final coins = _coins;
      if (_useCoinsOn && coins != null && fareCoinOffer(_fareFor(_service, biddingOn: offerMe), coins.balance, coins.rate) != null) {
        try {
          await ref.read(fareCoinChoiceStoreProvider).choose(req.id);
        } catch (_) {}
      }
      // The server checks the code again: one that no longer applies is
      // dropped and the ride is booked at its full fare.
      final sent = _promo;
      if (sent != null && req.promo == null && mounted) {
        showInfo(context, 'Promo ${sent.code} was not applied. ${promoReasonText(req.raw['promo_error'] as String?)}');
      }
      if (mounted) context.push('/ride/${req.id}').then((_) => _checkOngoing());
    } on DuplicateRideRequest catch (e) {
      // Nothing was sent: take the rider to the request they already have.
      if (!mounted) return;
      showInfo(context, e.toString());
      await _checkOngoing();
      final open = e.forOthers ? null : _ongoing;
      if (mounted && open != null) context.push('/ride/${open.id}').then((_) => _checkOngoing());
    } on QrBookingError catch (e) {
      // Nothing was stored and no driver told: the code can't book now, so
      // the booking goes back to an ordinary one for the rider to send.
      ref.read(directBookingProvider.notifier).clear();
      if (mounted) await showNotice(context, title: "Couldn't book this driver", message: e.toString());
    } on ServiceUnavailableError catch (e) {
      // The database's own check refused it (0125): the same sheet.
      if (!mounted) return;
      final gap = (
        at: switch (e.at) {
          'pickup' => UnavailableAt.pickup,
          'stop' => UnavailableAt.stop,
          _ => UnavailableAt.drop,
        },
        stop: e.stop,
        gap: e.gap,
        region: e.region,
        block: RegionBlock.both,
      );
      setState(() => _gap = gap);
      _showGap(gap);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  /// Back on the confirm step (its arrow, the system's or the browser's):
  /// off the trip and into the route search again, on what was typed for
  /// the destination (else its name), so a wrong pick is put right without
  /// typing it all again. Closing the search leaves the home map.
  void _backFromConfirm() {
    final drop = _drop;
    final stops = [..._stops];
    final typed = _dropQuery?.trim() ?? '';
    _leaveConfirm();
    if (drop == null) return;
    final query = typed.isNotEmpty ? typed : (isCoordinateLabel(drop.name) ? '' : drop.name);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _drop != null) return;
      unawaited(_choose(_PinTarget.drop, again: (to: drop, query: query, stops: stops)));
    });
  }

  // ---- Promo codes (0242) ----

  /// A demo rider's trips stay on the phone: no promo is asked for.
  bool get _promoOff => ref.read(demoRiderProvider);

  /// The home bar: asked again on a meaningful move or when the app comes
  /// back, never on every fix.
  Future<void> _checkPromoZone({bool force = false}) async {
    final at = _me;
    if (at == null || _promoOff || !promoZoneRecheckDue(_promoZoneAt, at, force: force)) return;
    _promoZoneAt = at;
    bool inZone;
    try {
      inZone = await ref.read(promoRepositoryProvider).zoneHere(at.latitude, at.longitude);
    } catch (_) {
      return;
    }
    if (mounted && inZone != _promoZone) setState(() => _promoZone = inZone);
  }

  /// The confirm step's trip, when its fare is known: the offers are read
  /// again (debounced) whenever it changes.
  void _syncPromos(bool confirming) {
    final a = _pickup, b = _drop;
    // A ride for later too: its codes are judged at its pickup time.
    final ready = confirming && a != null && b != null && _basis != null && !_routing && !_promoOff;
    if (!ready) {
      if (_promoKey != null || _promoOffers.isNotEmpty || _promo != null) {
        _promoTimer?.cancel();
        _promoSeq++;
        _promoKey = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _promoOffers = const [];
            _promo = null;
            _promoAuto = false;
            _promoTyped = false;
            if (!confirming) _promoRemoved = false;
          });
        });
      }
      return;
    }
    final fare = _promoFare;
    final at = _scheduleAt;
    final key = _promoKeyFor(a.point, b.point, fare, at);
    if (key == _promoKey) return;
    _promoKey = key;
    _promoTimer?.cancel();
    _promoTimer =
        Timer(const Duration(milliseconds: 400), () => _loadPromos(key, a.point, b.point, _service.name, fare, at));
  }

  String _promoKeyFor(LatLng a, LatLng b, double fare, DateTime? at) =>
      '${promoTripKey(pickup: a, drop: b, service: _service.name, fare: fare)}|${at?.toUtc().toIso8601String() ?? 'now'}';

  /// A ride for later: the codes for its pickup time, on the same promo
  /// sheet, before it is booked. False when the rider closed the sheet
  /// (nothing is booked).
  Future<bool> _promosForLater(DateTime at) async {
    final a = _pickup, b = _drop;
    if (a == null || b == null || _promoOff) return true;
    final fare = _promoFare;
    final key = _promoKeyFor(a.point, b.point, fare, at);
    _promoTimer?.cancel();
    _promoKey = key;
    await _loadPromos(key, a.point, b.point, _service.name, fare, at);
    if (!mounted) return false;
    if (_promoOffers.isEmpty && _promo == null) return true;
    final choice = await showPromoCodeSheet(
      context,
      offers: _promoOffers,
      applied: _promo,
      fare: fare,
      currency: _currency,
      onCheck: _checkPromo,
      laterAt: at,
    );
    if (choice == null || !mounted) return false;
    setState(() {
      _promo = choice.offer;
      _promoAuto = false;
      _promoRemoved = choice.offer == null;
    });
    return true;
  }

  Future<void> _loadPromos(String key, LatLng a, LatLng b, String service, double fare, DateTime? pickupAt) async {
    final seq = ++_promoSeq;
    List<PromoOffer> offers;
    try {
      offers = await ref.read(promoRepositoryProvider).offers(
            pickupLat: a.latitude,
            pickupLng: a.longitude,
            dropLat: b.latitude,
            dropLng: b.longitude,
            service: service,
            fare: fare,
            pickupAt: pickupAt,
          );
    } catch (_) {
      offers = const [];
    }
    // A typed code that isn't listed (hidden from the app): asked again.
    final typed = _promoTyped ? _promo : null;
    if (typed != null && !offers.any((o) => o.codeId == typed.codeId)) {
      try {
        final r = await _checkPromo(typed.code);
        if (r.ok) offers = [...offers, r.offer!];
      } catch (_) {}
    }
    if (!mounted || seq != _promoSeq || key != _promoKey) return;
    final next = promoAfterOffers(offers, current: _promo, currentAuto: _promoAuto, removed: _promoRemoved);
    setState(() {
      _promoOffers = offers;
      _promo = next.promo;
      _promoTyped = typed != null && next.promo?.codeId == typed.codeId;
      _promoAuto = next.auto;
    });
  }

  Future<PromoCheckResult> _checkPromo(String code) async {
    final a = _pickup, b = _drop;
    if (a == null || b == null) return const PromoCheckResult.refused('outside_area');
    return ref.read(promoRepositoryProvider).check(
          code,
          pickupLat: a.point.latitude,
          pickupLng: a.point.longitude,
          dropLat: b.point.latitude,
          dropLng: b.point.longitude,
          service: _service.name,
          fare: _promoFare,
          pickupAt: _scheduleAt,
        );
  }

  Future<void> _openPromoSheet() async {
    final choice = await showPromoCodeSheet(
      context,
      offers: _promoOffers,
      applied: _promo,
      fare: _fareFor(_service),
      currency: _currency,
      onCheck: _checkPromo,
    );
    if (choice == null || !mounted) return;
    setState(() {
      final o0 = choice.offer;
      _promoTyped = o0 != null && !_promoOffers.any((x) => x.codeId == o0.codeId);
      _promo = choice.offer;
      _promoAuto = false;
      _promoRemoved = choice.offer == null;
      // A typed code that isn't among the offers yet is shown with them.
      final o = choice.offer;
      if (o != null && !_promoOffers.any((x) => x.codeId == o.codeId)) _promoOffers = [..._promoOffers, o];
    });
  }

  /// Off the trip, back to the home map.
  void _leaveConfirm() {
    setState(() {
      _promoRemoved = false;
      _drop = null;
      _stops.clear();
      _routeMoved = false;
    });
    _updateRoute();
  }

  /// The route button: the whole trip back in view.
  /// Where the confirm card's bottom edge falls on the map; a new fit
  /// when it moved (the card grew with a stop, or the map's height changed).
  void _measureConfirmCard() {
    if (!mounted) return;
    final card = _confirmCard.currentContext?.findRenderObject();
    final map = _pin.currentContext?.findRenderObject();
    if (card is! RenderBox || map is! RenderBox || !card.hasSize || !map.hasSize) return;
    final bottom = card.localToGlobal(Offset(0, card.size.height)).dy - map.localToGlobal(Offset.zero).dy;
    if ((bottom - _confirmCardBottom).abs() > 1) setState(() => _confirmCardBottom = bottom);
  }

  void _showWholeRoute(double bottom) {
    final pts = [
      ?_pickup?.point,
      for (final s in _stops) s.point,
      ?_drop?.point,
      ...?_route?.points,
    ];
    if (pts.length > 1) {
      _map.fitCamera(
        CameraFit.coordinates(
          coordinates: pts,
          padding: EdgeInsets.fromLTRB(64, _confirmFitTop, 64, _confirmFitBottom + bottom),
          maxZoom: 16,
        ),
      );
    }
    setState(() => _routeMoved = false);
  }

  /// "Later": the pickup time from the Choose date and time sheet; null
  /// (nothing booked) when it is closed.
  Future<DateTime?> _pickLater(ScheduledRidesConfig c) {
    final fee = schedulingFee(_fareFor(_service), c);
    return showPickupTimeSheet(context, c, note: fee > 0 ? '+ ${formatMoney(fee, _currency)} scheduling fee' : null);
  }

  /// The booking for the time confirmed on that sheet.
  Future<void> _bookLater(DateTime at) async {
    if (!mounted) return;
    setState(() => _scheduleAt = at);
    try {
      // The codes for that pickup time, to keep, change or take off first.
      if (!await _promosForLater(at)) return;
      await _find();
    } finally {
      if (mounted && _scheduleAt != null) setState(() => _scheduleAt = null);
    }
  }

  /// "Find a driver" (or Now). One ride of the rider's own at a time (Expo's
  /// alert); rides for others are not held back by it.
  Future<void> _find() async {
    if (!_forOtherOn && _scheduleAt == null && _ongoing != null) {
      final open = await showAppDialog<bool>(id: 'home.find',
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
    // Already known to be outside GET.ride's regions: say so again, at once.
    final gap = _gap;
    if (gap != null) return _showGap(gap);
    // At an airport: which door (0249).
    if (!await _chooseAirportDoors() || !mounted) return;
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
            regionServices: _boxServices(ref.watch(serviceBoxNamesProvider).value ?? const {}),
          )
        : const <ServiceBoxView>[];
    void comingSoon(String body) => showAppDialog<void>(id: 'home.coming-soon',
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Coming Soon'),
            content: Text(body),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
          ),
        );
    void whereTo() => serviceOn ? _choose(_PinTarget.drop) : comingSoon(serviceComingSoonMessage);
    void toRecent(Place p) {
      if (!serviceOn) return comingSoon(serviceComingSoonMessage);
      _dropQuery = null;
      setState(() => _drop = p);
      _updateRoute();
    }

    // The two most recent places stay in view with the sheet all the way
    // down (portrait as on its side); any more only with the sheet up.
    final firstRecent = recent.take(homeRecentAtRest).toList();
    final moreRecent = recent.skip(homeRecentAtRest).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Where to first: the destination leads, over the vehicles. However
      // low the admin sets the sheet, it stays whole (the floor).
      KeyedSubtree(
        key: _floorKey,
        child: sections.searchBar
            ? HomeSearchPill(onTap: whereTo)
            : ListTile(
                key: const ValueKey('home-where-to'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.location_on, color: Colors.red.shade700),
                title: const Text('Where to?'),
                onTap: whereTo,
              ),
      ),
      const SizedBox(height: 12),
      if (sections.vehicleBar) ...[
        // Until a catalogue is known -- this read's, or the one this device
        // showed last time -- a skeleton: the built-in names and car icons
        // would read as the real services and then change.
        if (ref.watch(rideServicesProvider).hasValue || ref.watch(cachedRideServicesProvider).value != null)
          VehicleTypeBar(
            services: _services,
            selected: _service,
            onSelect: (s) => setState(() => _serviceName = s.name),
            // As the confirm step's, without the trip's high-fare note,
            // tolls, coins or taxes: there is no trip yet.
            onInfo: (s) => _showFareInfo(s, null, false, null),
          )
        else
          const VehicleTypeBarSkeleton(),
        const SizedBox(height: 4),
      ],
      if (!sections.addressBar)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.trip_origin, color: Colors.green.shade700),
          title: Text(_pickup?.name ?? 'Set pickup'),
          onTap: () => _choose(_PinTarget.pickup),
        ),
      // The fold reaches the foot of the last item shown: the upcoming-ride
      // card, the first recent places and the service boxes, so the sheet
      // all the way down shows every item switched on whole, clear of the
      // home indicator (plus Admin → Display → Bottom sheet minimum height).
      KeyedSubtree(
        key: _foldKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const UpcomingRideCard(),
            if (firstRecent.isNotEmpty) HomeRecentPlaces(places: firstRecent, onTap: toRecent),
            if (boxes.isNotEmpty) ...[
              const SizedBox(height: 16),
              ServiceBoxesGrid(
                boxes: boxes,
                onOpen: (b) =>
                    b.route == null ? comingSoon(serviceBoxComingSoon(b.title)) : openAppRoute(context, b.route!),
              ),
            ],
          ],
        ),
      ),
      // Recent places past the first ones only with the sheet up.
      if (moreRecent.isNotEmpty)
        MapSheetUpOnly(child: HomeRecentPlaces(places: moreRecent, onTap: toRecent)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    // An open route sheet follows the pickup and the current place.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncRouteEnds();
    });
    ref.listenLive(liveRegionTables, _regionsChanged);
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
        final was = _ongoing?.status.db;
        setState(() => _ongoing = r.status.isOngoing ? r : null);
        _armExpiry();
        // Nobody took it: say so here, where the rider is, rather than only
        // on the ride screen they may never open again.
        if (requestJustExpired(was, r.status.db)) _showExpired(r);
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
    // A phone on its side (844 × 390): the pickup box sits at the top, not
    // above the pin, where the short map cut it off.
    final pillAtTop = homePillAtTop(MediaQuery.sizeOf(context));
    // A destination chosen: the confirm step (Expo ride-confirm).
    final confirming = _drop != null;
    final layout = ConfirmLayout.fromSettings(blob);
    // A fare off the usual, fixed or offered (bidding): inDrive's demand
    // band in the promo bar's place.
    final demand = _basis != null && !_routing ? _ai?.trend : null;
    // The promo bar (0242) only when a code fits the trip: one applied, or
    // some to pick from. A demo rider's trips get none.
    _syncPromos(confirming);
    final showPromo = layout.promoBar && (_promo != null || _promoOffers.isNotEmpty);
    // The back and route buttons stand clear of the promo bar's visible top.
    // With the promo bar on too, both stand: the band over the bar.
    final bothBars = demand != null && showPromo;
    final aboveBar = showPromo || demand != null
        ? SheetTopBar.visibleHeight +
              (bothBars ? DemandPromoBars.extraHeight : 0) +
              (layout.promoBarInFront ? SheetTopBar.tuck : 0) +
              12 -
              layout.promoBarOffset
        : 12.0;
    // On the confirm map the route is framed between the address card and
    // the promo bar on the sheet, with room for the marks standing over it.
    if (confirming && _pinTarget == _PinTarget.none) {
      final cardBottom = _confirmCardBottom > 0 ? _confirmCardBottom : 150.0;
      _confirmFitTop = cardBottom + 12 + confirmPickupTop;
      _confirmFitBottom = aboveBar + 16 + confirmPickupDot;
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureConfirmCard());
    }
    // Places that move with the sheet: [build] gets how far up it reaches.
    Widget aboveSheet(Widget Function(double inset) build) => Positioned.fill(
      child: Builder(builder: (c) => MapBottomInset.listen(c, (inset) => Stack(children: [build(inset)]))),
    );
    // How far the bars' feet run behind the sheet: past its rounded top
    // corners, however deep the admin made them.
    final footUnder = SheetTopBar.footUnder(SurfaceStyle.ofPage(context).number('mapSheetRadius'));
    // The promo bar (0242): the code applied, or the codes that fit.
    Widget confirmPromoBar(double foot) => ConfirmPromoBar(
          offers: _promoOffers,
          applied: _promo,
          auto: _promoAuto,
          fare: _fareFor(_service),
          currency: _currency,
          onTap: _openPromoSheet,
          foot: foot,
        );
    // A fare off the usual takes the bar's place: inDrive's demand band,
    // opening why. The promo bar stays under it, so a code can still be used.
    Widget bars(double foot) => demand == null
        ? confirmPromoBar(foot)
        : bothBars
        ? DemandPromoBars(
            trend: demand,
            onDemand: () => showDemandSheet(context, demand, factor: _upliftFor(_service)?.factor),
            promo: confirmPromoBar(foot),
          )
        : DemandBanner(
            trend: demand,
            onTap: () => showDemandSheet(context, demand, factor: _upliftFor(_service)?.factor),
            foot: foot,
          );
    // The discount bar; in front of the sheet it is drawn on the sheet's
    // layer instead of the map's (Admin → Display → Discount bar in front).
    Widget promoBar() => aboveSheet((inset) {
          final offset = layout.promoBarOffset;
          // In front it stands whole on the sheet's top edge.
          if (layout.promoBarInFront) {
            return Positioned(left: 0, right: 0, bottom: inset - offset, child: bars(SheetTopBar.tuck));
          }
          // Behind, its foot runs under the sheet's top edge. Moved down by
          // the admin more of it is behind; moved up, the foot grows by as
          // much, so it still reaches behind the sheet with no map between.
          return Positioned(
            left: 0,
            right: 0,
            bottom: inset - footUnder - math.max(0.0, offset),
            child: bars(footUnder + math.max(0.0, -offset)),
          );
        });
    // The bar in front stands on the sheet's top edge, whose corners are
    // rounded: under the sheet a foot of the bar's fill runs from behind the
    // bar down past them, so no map shows there.
    Widget promoBarFoot() => aboveSheet((inset) {
          final t = Theme.of(context);
          return Positioned(
            left: 0,
            right: 0,
            bottom: inset - footUnder,
            height: math.max(0.0, footUnder + 8 - layout.promoBarOffset),
            child: IgnorePointer(
              child: ColoredBox(
                key: const ValueKey('confirm-bar-foot'),
                color: showPromo ? ConfirmPromoBar.fillFor(t, applied: _promo != null) : demandBandColor(t),
              ),
            ),
          );
        });
    // Home: the rider stands in a promo zone (an auto-apply code about the pickup).
    Widget promoZoneBar() => aboveSheet(
          (inset) => Positioned(
            left: 0,
            right: 0,
            bottom: inset - SheetTopBar.tuck,
            child: const PromoZoneBar(),
          ),
        );
    // Admin → Display → Map Layout, while the pickup is being set.
    final mapLayout = confirming ? const HomeMapLayout() : HomeMapLayout.fromSettings(blob);
    _refocusOnLayoutChange(mapLayout);
    final satellite = ref.watch(mapSatelliteProvider);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final autoFit = !_pinMoving && (_drop != null || _pickup == null || _pickup!.point != _dragged);
    final fitTop = confirming ? _confirmFitTop : 64.0;
    final fitBottom = confirming ? _confirmFitBottom : 64.0;
    final map = Stack(children: [
      Positioned(
        // Map height: the map reaches above the top of the screen.
        top: -mapLayout.mapExtra,
        left: 0,
        right: 0,
        bottom: 0,
        child: RepaintBoundary(
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
            // Built again only when something it shows changes (the demo
            // cars step on their own tick).
            child: ValueListenableBuilder(
              valueListenable: _carsTick,
              builder: (_, _, _) => _homeMap([
                _me, _pickup, _pinMoving, confirming, wide, _routeMoved, autoFit, fitTop, fitBottom, _drop?.point,
                _route, satellite, _cars, serviceIndex, showPill, screenWidth, mapLayout.pillGap, ai, tolls.length,
                _stops.length, for (final p in _stops) p.point,
              ], () => RideMap(
              controller: _map,
              me: _me,
              pickup: _pickup?.point,
              showPickup: !_pinMoving,
              hideCredit: _pinMoving,
              dotPins: confirming,
              focusPickup: !wide,
              pointZoom: homeStreetZoom,
              onGesture: confirming && !_routeMoved ? () => setState(() => _routeMoved = true) : null,
              autoFit: autoFit,
              fitTop: fitTop,
              fitBottom: fitBottom,
              drop: _drop?.point,
              stops: [for (final p in _stops) p.point],
              route: _route?.points ?? const [],
              onTap: _onMapTap,
              satellite: satellite,
              extraMarkers: [
                for (final c in _cars) demoCarMarker(c, serviceIndex),
                // The pickup box stands 5 px above the pickup pin and moves with
                // it; it hides while the pin is lifted, until it lands.
                if (showPill && _pickup != null && !_pinMoving && !pillAtTop)
                  labelAbovePin(
                    _pickup!.point,
                    PickupPill(place: _pickup, onTap: () => _choose(_PinTarget.pickup)),
                    width: math.min(320, screenWidth - 32),
                    // Address bar height.
                    gap: mapLayout.pillGap,
                  ),
                for (final m in tolls) tollMarker(m, onTap: ai == null ? null : () => showTollBooths(context, ai)),
              ],
            )),
            ),
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
                  tooltip: 'Stop picking on the map',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _pinTarget = _PinTarget.none),
                ),
              ),
            ),
          ),
        ),
      // With no pickup on the map yet there is no pin to stand on: the box
      // waits at the top until there is. A phone on its side keeps it there
      // too, beside the menu button: above the pin it ran off the top.
      if (showPill && (_pickup == null || (pillAtTop && !_pinMoving)))
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
            // Clear of the notch on a phone on its side.
            right: 16 + MediaQuery.paddingOf(context).right,
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
      if (confirming && !wide && (showPromo || demand != null) && !layout.promoBarInFront) promoBar(),
      if (!confirming && !wide && _promoZone && _pinTarget == _PinTarget.none && !_promoOff) promoZoneBar(),
      if (confirming && _pinTarget == _PinTarget.none)
        Positioned(
          top: 16 + layout.address.$2,
          // On its side Back stands at the card's left (see below).
          left: 16 + layout.address.$1 + (pillAtTop ? 56 : 0),
          right: 16 - layout.address.$1,
          child: SafeArea(
            child: ConfirmAddressCard(
              key: _confirmCard,
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
      // On a phone on its side the map above the sheet is too short for
      // Back to stand over it (it landed on the route card): it waits at
      // the top left, beside the card and clear of the notch.
      if (confirming && !wide && pillAtTop)
        Positioned(
          left: 16,
          top: 16 + layout.address.$2,
          child: SafeArea(
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              shape: const CircleBorder(),
              elevation: 3,
              child: IconButton(
                key: const ValueKey('confirm-back'),
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: _backFromConfirm,
              ),
            ),
          ),
        ),
      // On a wide screen Back heads the panel instead (see below).
      if (confirming && !wide && !pillAtTop)
        aboveSheet(
          (inset) => Positioned(
            left: 16 + MediaQuery.paddingOf(context).left + layout.back.$1,
            bottom: (wide ? 16 : inset + aboveBar) - layout.back.$2,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              shape: const CircleBorder(),
              elevation: 3,
              child: IconButton(
                key: const ValueKey('confirm-back'),
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: _backFromConfirm,
              ),
            ),
          ),
        ),
      if (confirming && _routeMoved)
        aboveSheet(
          (inset) => Positioned(
            right: 16 + MediaQuery.paddingOf(context).right - layout.recenter.$1,
            bottom: (wide ? mapAttributionClearance : inset + aboveBar) - layout.recenter.$2,
            child: RouteFitButton(
              key: const ValueKey('confirm-route'),
              onPressed: () => _showWholeRoute(wide ? 0 : inset),
            ),
          ),
        ),
    ]);

    ref.watch(rideServicesProvider); // rebuild when the catalogue arrives
    ref.watch(cachedRideServicesProvider); // or the device's copy, first
    ref.watch(serviceBoxNamesProvider); // and the Service types its rules name
    ref.watch(paymentChoicesProvider); // and when Admin → Payment Type changes
    ref.watch(coinTradeQuoteProvider); // and when the GET.coin balance does
    ref.watch(fareTariffsProvider); // re-quote when the tariff cards arrive
    final earnRate = ref.watch(coinTradeQuoteProvider).value?.settings.earnCoinsPerCurrency ?? 0;
    final coins = _coins;
    final coinOffer = coins == null ? null : fareCoinOffer(_fareFor(_service), coins.balance, coins.rate);
    final otherName = _otherName.text.trim();
    // My Ride: only with a favourite who can be offered the ride.
    final myRideAt = confirming ? _myRideAt : null;
    final myRideFavs = myRideAt == null
        ? const <FavouriteDriver>[]
        : ref.watch(bookingFavouritesProvider(myRideAt)).value ?? const <FavouriteDriver>[];
    final myRideSettings = myRideAt == null ? const MyRideSettings() : myRideSettingsOf(ref);
    final myRideTargets = _myRideTargets(myRideFavs, myRideSettings);
    final myRideOn = myRideTargets.isNotEmpty;
    final direct = ref.watch(directBookingProvider);
    final scheduleConfig = ref.watch(scheduledRidesConfigProvider).value ?? ScheduledRidesConfig.off;
    final owed = scheduleConfig.enabled ? ref.watch(owedFeesProvider).value ?? 0 : 0.0;
    final footer = confirming && _route != null
        ? ConfirmFooter(
            // Always there: Comments stays when every option is hidden.
            onOptions: () => showRideOptionsSheet(
              context,
              options: _options,
              onChanged: (o) => setState(() => _options = o),
              note: _note,
              petConfig: ref.read(petConfigProvider),
              config: ref.read(rideOptionsConfigProvider),
              assistance: ref.read(assistanceCatalogueProvider),
            ).then((_) {
              if (mounted) setState(() {}); // the note may have changed
            }),
            optionsOn: _bookable.any,
            chargesNote: _optionChargesNote,
            payment: _payment,
            payments: _payments,
            onPayment: () async {
              final p = await showPaymentSheet(context, _payment, payments: _payments);
              if (p != null && mounted) setState(() => _paymentPick = p);
            },
            // Offers only come where bidding is on for this service.
            autoAcceptLabel: layout.showAutoAccept && _biddingFor(_service) ? 'Auto-accept offer of ${_fareMoney(_fareFor(_service))}' : null,
            autoAccept: _autoAccept,
            onAutoAccept: (v) => setState(() => _autoAccept = v),
            label: _forOtherOn
                ? 'Find a driver for ${otherName.isEmpty ? 'someone else' : otherName}'
                : direct != null
                ? 'Book ${direct.driverName}'
                : 'Find a driver',
            onFind: _booking ||
                    _routing ||
                    _basis == null ||
                    (_forOtherOn && bookedFor(_otherName.text, _otherPhone.text) == null)
                ? null
                : _find,
            coinTitle: coinOffer == null || !layout.showCoin ? null : 'Use GET.coin',
            coinSubtitle: coinOffer == null || !layout.showCoin
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
            pickLater: scheduleConfig.enabled && direct == null ? () => _pickLater(scheduleConfig) : null,
            onLater: _bookLater,
            owedNote: owed > 0 ? '+ ${formatMoney(owed, _currency)} late fee from an earlier booking' : null,
            whoRiding: !layout.showBookForOther ? null : _WhoRiding(
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
            myRide: direct != null
                ? DirectBookingConfirmRow(
                    booking: direct,
                    onCancel: () => ref.read(directBookingProvider.notifier).clear(),
                  )
                : layout.showMyRide && myRideFavs.any((d) => d.available)
                ? MyRideConfirmRow(
                    on: myRideOn,
                    names: myRideOn ? myRideNames(myRideTargets, myRideFavs) : null,
                    onChanged: (v) => v ? _pickMyRide(myRideFavs, myRideSettings) : setState(() => _myRideOn = false),
                    onEdit: () => _pickMyRide(myRideFavs, myRideSettings),
                  )
                : null,
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
      fareAdjusted: _biddingFor(_service) && _adjust != 0,
      bidding: _biddingFor(_service),
      onFareInfo: _basis != null && !_routing ? (s) => _showFareInfo(
              s,
              ai,
              display?.showAiTollCharges ?? true,
              coinEarnLabel(rideRewardCoins(_fareFor(s), earnRate)),
            ) : null,
      etaFor: etaFor,
      upliftFor: (s) {
        final u = _upliftFor(s);
        return u == null ? null : _fareMoney(u.amount);
      },
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
      fareDecimals: _pricing.fareDecimals,
      onPickup: () => _choose(_PinTarget.pickup),
      onDrop: () => _choose(_PinTarget.drop),
      onService: (s) => setState(() {
        if (s.name != _serviceName) _adjust = 0;
        _serviceName = s.name;
      }),
      fare: _basis != null && !_routing
          ? ConfirmFareSection(
              recommended: _recommendedFor(_service),
              adjust: _biddingFor(_service) ? _adjust : 0,
              money: _fareMoney,
              bidding: _biddingFor(_service),
              onAdjust: (v) => setState(() => _adjust = v),
              onEdit: _openOfferFare,
              earn: coinEarnLabel(rideRewardCoins(_fareFor(_service), earnRate)),
              tollBooths: display?.showAiTollBooths ?? true ? tollBoothCount(ai) : 0,
              onTollBooths: ai == null ? null : () => showTollBooths(context, ai),
              tollCharges: (display?.showAiTollCharges ?? true) && ai?.tollsToShow != null
                  ? formatMoney(ai!.tollsToShow, _currency)
                  : null,
              tax: _chargeLines(),
              trend: ai?.trend,
            )
          : null,
      onEditFare: _biddingFor(_service) && _basis != null && !_routing ? _openOfferFare : null,
      onOpenOngoing: () => context.push('/ride/${_ongoing!.id}').then((_) => _checkOngoing()),
      idle: _drop == null ? _homeParts(sections, blob, display) : null,
      footer: wide ? footer : null,
    );

    // While the fare is being worked out (Expo's "Calculating fare").
    Widget calculating(Widget body) => Stack(children: [
          Positioned.fill(child: body),
          // Adding a stop shows its own steps instead.
          if (confirming && _routing && !_addingStop) const Positioned.fill(child: CalculatingFareOverlay()),
        ]);
    if (wide) {
      return Scaffold(
        body: calculating(Row(children: [
          SizedBox(
            width: 420,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Back at the head of the fare panel, not adrift on the map.
                  if (confirming)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                      child: Row(children: [
                        IconButton(
                          key: const ValueKey('confirm-back'),
                          tooltip: 'Back',
                          icon: const Icon(Icons.arrow_back),
                          onPressed: _backFromConfirm,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            'Choose your ride',
                            style: Theme.of(context).textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ]),
                    ),
                  Expanded(child: SingleChildScrollView(child: panel)),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: map),
        ])),
      );
    }
    // Above Android's navigation bar and iPhone's home indicator alike, so
    // the search bar is never under the system's swipe.
    final navLift = footer == null ? MediaQuery.viewPaddingOf(context).bottom : 0.0;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final navLiftFraction = screenHeight > 0 ? navLift / screenHeight : 0.0;
    if (!confirming) WidgetsBinding.instance.addPostFrameCallback((_) => _measureFold());
    final page = Scaffold(
      body: calculating(PopScope(
        // Back on the confirm step leaves it, as its back arrow does.
        canPop: !confirming,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && confirming) _backFromConfirm();
        },
        child: LayoutBuilder(builder: (context, box) {
          // All the way down, the sheet shows every item switched on (the
          // fold), however tall the screen, moved by the admin's Bottom sheet
          // minimum height; never less than the search bar whole, never more
          // than the sheet's highest. A share until it is measured.
          final sheetTop = (MapSheetLayout.defaultMax - navLiftFraction) * box.maxHeight;
          final least = !confirming && _foldHeight > 0 && box.maxHeight > 0
              ? math.min(
                  MapSheetLayout.defaultMax - navLiftFraction,
                  effectiveSheetMin(
                        auto: _foldHeight,
                        adjust: sheetMinAdjust(blob, homeSheetMinAdjustKey),
                        floor: _floorHeight,
                        max: sheetTop,
                      ) /
                      box.maxHeight,
                )
              : 0.22;
          // A phone on its side (844 × 390): the confirm sheet starts lower,
          // so the map and the pickup above it keep their room.
          final landscapePhone = box.maxWidth > box.maxHeight && box.maxHeight < 500;
          // Never so high that the sheet covers the route card over the map
          // (on its side at large text the card is most of the strip).
          final cardFit = confirming && _confirmCardBottom > 0 && box.maxHeight > 0
              ? 1 - (_confirmCardBottom + 8) / box.maxHeight
              : 1.0;
          final confirmMin = math.max(0.25, math.min(landscapePhone ? 0.4 : 0.5, cardFit));
          final confirmStart = math.max(confirmMin, math.min(landscapePhone ? 0.4 : 0.55, cardFit));
          // The most the vehicles may raise the sheet at rest: the route card
          // and the bars standing on the sheet's edge stay clear above it, and
          // so does the map the bars ride on; until the card is measured, the
          // share the sheet always rested at.
          final contentCap = _confirmCardBottom > 0 && box.maxHeight > 0
              ? math.max(
                  confirmMin,
                  math.min(
                    1 - MapSheetLayout.defaultMapMinFraction,
                    1 - (_confirmCardBottom + 8 + aboveBar) / box.maxHeight,
                  ),
                )
              : confirmMin;
          return MapSheetLayout(
          map: map,
          // Android's own buttons (three-button navigation, drawn over the
          // app edge to edge) would cover the sheet's foot — the search bar —
          // where no footer sits above them: the sheet rises by their height.
          sheet: KeyedSubtree(
            key: _panelKey,
            child: navLift > 0 ? Padding(padding: EdgeInsets.only(bottom: navLift), child: panel) : panel,
          ),
          min: (confirming ? confirmMin : least) + navLiftFraction,
          // The confirm sheet all the way down shows its vehicles and the
          // distance line over them (its rest line, [confirmMin] only until
          // measured), moved by the admin's Bottom sheet minimum height; never
          // so high that the route card over the map is covered.
          minFromContent: confirming,
          minAdjust: confirming ? sheetMinAdjust(blob, confirmSheetMinAdjustKey) : 0,
          minCap: confirming ? contentCap : null,
          minFloor: confirming ? confirmSheetMinFloor.toDouble() : null,
          revealMax: confirming && cardFit < 1 ? math.max(confirmStart, cardFit) : null,
          // The main screen's sheet starts fully down; the rider drags it up.
          initial: (confirming ? confirmStart : least) + navLiftFraction,
          hidden: _pinMoving,
          // navLift above already keeps the sheet's foot clear of the system bar.
          padBottom: false,
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
          front: confirming && !wide && (showPromo || demand != null) && layout.promoBarInFront ? Stack(children: [promoBar()]) : null,
          behind: confirming && !wide && (showPromo || demand != null) && layout.promoBarInFront
              ? Stack(children: [promoBarFoot()])
              : null,
        );
        }),
      )),
    );
    // No app bar to set the status bar: its icons follow the theme.
    return ThemedStatusBar(child: page);
  }
}

class _BookingPanel extends StatelessWidget {
  const _BookingPanel({
    this.disclaimerOffset = Offset.zero,
    this.fareAdjusted = false,
    this.bidding = false,
    this.onFareInfo,
    required this.ongoing,
    required this.pickup,
    required this.drop,
    required this.route,
    this.ai,
    required this.routing,
    required this.services,
    required this.service,
    required this.fareFor,
    this.fareDecimals = 2,
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
    this.upliftFor,
  });

  /// What high demand adds to a vehicle's fare (the uplift, formatted);
  /// null where it adds nothing.
  final String? Function(RideService)? upliftFor;

  /// The uplift beside [s]'s price ("+RM1"); none on a card whose fare the
  /// rider has raised or lowered, where the arrows go too.
  String? _upliftLabel(RideService s) {
    if (s.name == service.name && fareAdjusted) return null;
    final u = upliftFor?.call(s);
    return u == null ? null : demandUpliftLabel(u);
  }

  /// Minutes for the nearest driver to reach the pickup, per vehicle; null
  /// when none is near.
  final int? Function(RideService)? etaFor;

  /// Whether the chosen vehicle takes offers; without, the list is inDrive's
  /// fixed-fare one.
  final bool bidding;

  /// The (i) on the chosen fixed-fare vehicle.
  final ValueChanged<RideService>? onFareInfo;

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

  /// The decimals a fare is shown with (none where the region's are whole).
  final int fareDecimals;
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

  /// [child] as the sheet's floor ([MapSheetRestLine.floor]) where [on].
  static Widget _floorIf(bool on, Widget child) => on ? MapSheetRestLine(floor: true, child: child) : child;

  @override
  Widget build(BuildContext context) {
    String? s0Uplift() {
      final u = fareAdjusted ? null : upliftFor?.call(service);
      return u == null ? null : demandIncludesNote(u);
    }
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
              subtitle: Text('${ongoing!.pickupLabel} to ${ongoing!.dropLabel}',
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
              subtitle: Text('${r.pickupLabel} to ${r.dropLabel}', maxLines: 1, overflow: TextOverflow.ellipsis),
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
          // What the sheet shows all the way down: the distance line and
          // every vehicle (its rest line); however low the admin sets it, the
          // first vehicle stays whole (its floor).
          MapSheetRestLine(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: RouteBasisLine(
                  route: route!,
                  ai: ai,
                  // The fare line says when the chosen fare includes high demand.
                  demandNote: s0Uplift(),
                ),
              ),
              for (final (i, s) in services.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _floorIf(
                    i == 0,
                    ConfirmServiceCard(
                      service: s,
                      price: formatMoney(fareFor(s), currency, fareDecimals),
                      selected: s.name == service.name,
                      etaMinutes: etaFor?.call(s),
                      onTap: () => onService(s),
                      fare: s.name == service.name ? fare : null,
                      onEdit: s.name == service.name ? onEditFare : null,
                      fixed: !bidding,
                      onInfo: s.name == service.name && onFareInfo != null ? () => onFareInfo!(s) : null,
                      // The arrows stand by the recommended fare: not on a card
                      // whose fare the rider has raised or lowered.
                      trend: s.name == service.name && fareAdjusted ? null : ai?.trend,
                      uplift: _upliftLabel(s),
                    ),
                  ),
                ),
            ]),
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

/// What the AI mark on the route line means, on tap and to screen readers.
const routeAiExplainer = 'Fare and travel time worked out by AI from current traffic and demand';

/// The distance and time the fares are priced on. When they came from the
/// AI Fare Service (`ai-route-proxy`, traffic-aware) the line says so with
/// the AI mark; the plain road route has none.
class RouteBasisLine extends StatelessWidget {
  const RouteBasisLine({super.key, required this.route, this.ai, this.demandNote});

  final RouteInfo route;
  final RouteEstimate? ai;

  /// "Includes high demand +RM1" while the trend raises the chosen fare.
  final String? demandNote;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final a = ai;
    final text = a == null
        ? '${formatDistance(route.distanceKm)} · ${formatDuration(route.durationMin)}'
        : '${formatDistance(a.distanceKm)} · ${formatDuration(a.durationMin)} with traffic';
    final note = demandNote;
    final line = Row(children: [
      Flexible(child: Text(text, key: const ValueKey('route-basis'), style: t.textTheme.bodyMedium)),
      if (a != null) ...[
        const SizedBox(width: 6),
        // Tapped (or hovered, or long-pressed) it says what the AI did; a
        // screen reader reads the same with the mark.
        Tooltip(
          message: routeAiExplainer,
          triggerMode: TooltipTriggerMode.tap,
          showDuration: const Duration(seconds: 5),
          excludeFromSemantics: true,
          child: Semantics(
            container: true,
            label: 'AI estimate. $routeAiExplainer',
            excludeSemantics: true,
            child: ConstrainedBox(
              // A 44-high tap area around the small chip.
              constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
              child: Center(
                widthFactor: 1,
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
                    const SizedBox(width: 3),
                    Icon(Icons.info_outline, size: 14, color: t.colorScheme.onPrimaryContainer),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ],
    ]);
    if (note == null) return line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        line,
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            note,
            key: const ValueKey('route-demand-note'),
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurface, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
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
                  maxLines: 2,
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
