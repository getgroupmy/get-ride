// The Freight page (home service box "Freight", migration 0267): the cargo's
// pickup and destination, when, what it is, the vehicle size, the options
// (helpers, closed body, riding along: fixed charges by place), the payment,
// a photo and the rider's offer, then Create request. The request is a ride
// request of that size's service, bid on as any ride: drivers' offers come
// to My freight requests, and an accepted one opens the normal trip screens.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../config.dart';
import '../../core/book_for.dart';
import '../../core/commission.dart' show Geo;
import '../../core/early_end.dart' show serviceTypeIds;
import '../../core/fare_tariff.dart';
import '../../core/format.dart';
import '../../core/courier.dart' show deliveryStatusLabel, recipientPaysText;
import '../../core/freight.dart';
import '../../core/saved_drafts.dart';
import '../../core/option_charge.dart';
import '../../core/partner_type_rules.dart' show RegionScope;
import '../../core/payment_types.dart';
import '../../core/region_pricing.dart';
import '../../core/ride_bidding.dart' show standingOffer;
import '../../core/ride_chat.dart' show ridePhotoProblem;
import '../../core/ride_option_charges.dart';
import '../../core/ride_option_places.dart';
import '../../core/ride_option_settings.dart';
import '../../core/ride_request_metadata.dart';
import '../../core/scheduled_rides.dart';
import '../../data/app_display_repository.dart';
import '../../data/device_access.dart';
import '../../data/fare_tariff_repository.dart';
import '../../data/freight_repository.dart';
import '../../data/geo_service.dart';
import '../../data/models.dart';
import '../../data/photo_picker.dart';
import '../../data/ride_option_places_repository.dart';
import '../../data/ride_draft_store.dart';
import '../../data/ride_option_providers.dart';
import '../../data/scheduled_ride_repository.dart';
import '../../providers.dart';
import 'service_not_offered.dart';
import '../../widgets/chat_photo.dart' show choosePhotoSource;
import '../../widgets/common.dart' show showError, showInfo, showNotice;
import '../../widgets/page_style_host.dart';
import '../../widgets/media_image.dart' show MediaIcon;
import '../../widgets/search_select.dart' show ListSearchFilter, searchSelectMatches;
import 'confirm_parts.dart' show paymentLook;
import 'courier_parts.dart' show CourierCodeCard;
import 'delivery_look.dart';
import 'freight_parts.dart';
import 'map_place_picker.dart';
import 'pickup_time_sheet.dart';
import 'place_search.dart';
import 'scheduled_rides_screen.dart' show pickupLabel;
import 'searching_parts.dart' show OfferStack, SearchOfferView;

/// Opens the Freight page; with [resume], filled in as it was left
/// (Welcome back, saved_drafts.dart).
Future<void> openFreightPage(BuildContext context, {Map<String, Object?>? resume}) => Navigator.of(context)
    .push<void>(AppPageRoute(id: 'ride.freight', builder: (_) => FreightScreen(resume: resume)));

/// A loading or drop-off point: the place searched (or pinned) and booked,
/// and the house number and street as the rider typed them.
typedef FreightAddress = ({String details, Place place});

/// The longest house number and street the rider may type.
const freightAddressDetailsMax = 120;

/// "No. 12, Level 3, Menara KH": what the rider typed, then the place found
/// when it doesn't already say it.
String freightAddressLabel(FreightAddress a) {
  final name = a.place.name.trim();
  final details = a.details.trim();
  if (details.isEmpty) return name;
  if (name.isEmpty || details.toLowerCase().contains(name.toLowerCase())) return details;
  return '$details, $name';
}

/// The house number and street a search result gives, to fill the box in
/// for the rider to change: its address up to the postcode ("12, Jalan
/// Ampang" of "12, Jalan Ampang, 50450 Kuala Lumpur, Malaysia"), less the
/// building's name when it leads; empty when the address doesn't say.
String freightStreetOf(Place p) {
  var parts = [for (final s in p.address.split(',')) if (s.trim().isNotEmpty) s.trim()];
  final postcode = parts.indexWhere((s) => RegExp(r'(^|\s)\d{4,6}(\s|$)').hasMatch(s));
  if (postcode >= 0) {
    parts = parts.sublist(0, postcode);
  } else {
    parts = parts.length > 2 ? parts.sublist(0, parts.length - 2) : parts.take(parts.length - 1).toList();
  }
  // A building's name leading its address goes; a house number ("Lot 5") stays.
  final lead = parts.isEmpty ? '' : parts.first;
  if (parts.length > 1 && !RegExp(r'\d').hasMatch(lead) && lead.toLowerCase() == p.name.trim().toLowerCase()) {
    parts = parts.sublist(1);
  }
  final street = parts.join(', ');
  return street.length > freightAddressDetailsMax ? street.substring(0, freightAddressDetailsMax) : street;
}

/// The full address the driver reads: what the rider typed, then the
/// place's own address.
String freightAddressFull(FreightAddress a) {
  final details = a.details.trim();
  final address = a.place.address.trim();
  if (address.isEmpty) return details;
  if (details.isEmpty || address.toLowerCase().contains(details.toLowerCase())) return address;
  return '$details, $address';
}

/// Looks a place up for the Freight page: the app's place search (saved
/// places, gates, "Pin on the map"), or the map at once with [onMap].
/// Overridden in tests.
typedef FreightPlaceSearch = Future<Place?> Function(
  BuildContext context, {
  required String title,
  LatLng? near,
  bool onMap,
});

final freightPlaceSearchProvider = Provider<FreightPlaceSearch>((ref) => (context, {required title, near, onMap = false}) async {
  if (onMap) return pickPlaceOnMap(context, start: near);
  final pick = await showPlaceSearch(context, title: title, near: near, mode: PlaceSearchMode.address, fieldLabel: title);
  if (pick == null || !context.mounted) return null;
  return pick.pickOnMap ? pickPlaceOnMap(context, start: near) : pick.place;
});

/// What the server reads a pickup at: its geography, the place its Ride
/// Options are read at, how its fares are priced and its time zone.
typedef FreightPickupContext = ({AreaInfo? area, RegionScope place, RegionPricing pricing, String? timezone});

final freightPickupContextProvider = Provider<Future<FreightPickupContext> Function(LatLng)>((ref) => (p) async {
  AreaInfo? area;
  try {
    area = await ref.read(geoServiceProvider).reverseArea(p).timeout(const Duration(seconds: 6));
  } catch (_) {}
  var place = optionPlaceFromArea(area);
  try {
    place = await ref.read(rideOptionPlacesRepositoryProvider).placeAt(p, area) ?? place;
  } catch (_) {}
  final rides = ref.read(rideRepositoryProvider);
  var pricing = RegionPricing.none;
  try {
    pricing = await rides.pricingFor(p, () async => area);
  } catch (_) {}
  String? timezone;
  try {
    timezone = (await rides.ruleContextFor(p, () async => area)).timezone;
  } catch (_) {}
  return (area: area, place: place, pricing: pricing, timezone: timezone);
});

/// The road distance and time between two points; null when it can't be
/// worked out. Overridden in tests.
final freightRouteProvider = Provider<Future<({double km, double min})?> Function(LatLng, LatLng)>(
  (ref) => (a, b) async {
    try {
      final r = await ref.read(geoServiceProvider).route(a, b);
      return (km: r.distanceKm, min: r.durationMin);
    } catch (_) {
      return null;
    }
  },
);

class FreightScreen extends ConsumerStatefulWidget {
  const FreightScreen({super.key, this.initialTab = 0, this.resume});

  /// 0: Create request, 1: My requests.
  final int initialTab;

  /// A request left unfinished, to fill the form in with.
  final Map<String, Object?>? resume;

  @override
  ConsumerState<FreightScreen> createState() => _FreightScreenState();
}

class _FreightScreenState extends ConsumerState<FreightScreen> with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 2, vsync: this, initialIndex: widget.initialTab);
  FreightAddress? _pickup, _drop;
  FreightPickupTime _time = FreightPickupTime.soon;
  DateTime? _scheduleAt;
  String _description = '';
  String? _vehicleId;
  Set<RideOptionKind> _options = const {};
  String _payment = 'Cash';
  Uint8List? _photo;
  String? _photoPath;
  bool _uploading = false;
  double? _offer;
  double? _declared;
  bool _ack = false;
  FreightRecipient? _recipient;
  FreightPickupContext? _context;
  LatLng? _contextAt;
  ({double km, double min})? _route;
  bool _booking = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() {
      if (mounted) setState(() {});
    });
    try {
      _uid = ref.read(currentUserIdProvider);
    } catch (_) {}
    _saver = DraftSaver(SavedDraftKind.freight, ref.read(rideDraftStoreProvider), () => _uid);
    if (widget.resume case final r?) _restore(r);
  }

  @override
  void dispose() {
    _saver.dispose();
    _tabs.dispose();
    super.dispose();
  }

  // ---- Welcome back (saved_drafts.dart) ----
  late final DraftSaver _saver;
  String? _uid;

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _saver.changed(_saved());
  }

  /// The form as kept on the phone, once both ends are set. The confirmation
  /// about prohibited items and the cargo photo are asked for again.
  Map<String, Object?>? _saved() {
    final a = _pickup, b = _drop;
    if (a == null || b == null || !draftPlaceReal(a.place) || !draftPlaceReal(b.place)) return null;
    return {
      'pickup': draftAddressToJson(a.place, a.details),
      'drop': draftAddressToJson(b.place, b.details),
      'time': _time.name,
      'schedule_at': ?_scheduleAt?.toUtc().toIso8601String(),
      if (_description.isNotEmpty) 'description': _description,
      'vehicle_id': ?_vehicleId,
      'vehicle_name': ?(_vehicleId == null ? null : _vehicle?.name),
      if (_options.isNotEmpty) 'options': [for (final o in _options) o.name],
      'payment': _payment,
      'offer': ?_offer,
      if (_offer != null) 'currency': _currency,
      'declared': ?_declared,
      if (_recipient case final r?) 'recipient': {'name': r.name, 'phone': r.phone},
    };
  }

  void _restore(Map<String, Object?> m) {
    final a = draftAddressFromJson(m['pickup']), b = draftAddressFromJson(m['drop']);
    if (a != null) _pickup = a;
    if (b != null) _drop = b;
    _time = FreightPickupTime.values.where((t) => t.name == m['time']).firstOrNull ?? _time;
    final at = DateTime.tryParse('${m['schedule_at'] ?? ''}')?.toLocal();
    _scheduleAt = at != null && at.isAfter(DateTime.now()) ? at : null;
    if (_time == FreightPickupTime.scheduled && _scheduleAt == null) _time = FreightPickupTime.soon;
    _description = draftText(m['description']) ?? '';
    _vehicleId = draftText(m['vehicle_id']);
    final options = m['options'];
    _options = {
      if (options is List)
        for (final o in options) ?RideOptionKind.values.where((k) => k.name == o).firstOrNull,
    };
    _payment = draftText(m['payment']) ?? _payment;
    _offer = draftNumber(m['offer']);
    _declared = draftNumber(m['declared']);
    final r = m['recipient'];
    if (r is Map && draftText(r['phone']) != null) _recipient = (name: '${r['name'] ?? ''}', phone: '${r['phone']}');
  }

  List<FreightVehicle> get _vehicles => ref.read(freightVehiclesProvider).value ?? const [];

  /// The size chosen, else the first one (as the sample shows "Van (S)").
  FreightVehicle? get _vehicle {
    final all = _vehicles;
    if (all.isEmpty) return null;
    return all.firstWhere((v) => v.id == _vehicleId, orElse: () => all.first);
  }

  RideOptionsConfig get _config => ref.read(rideOptionsConfigProvider);

  RideOptionsHere get _here {
    final places = ref.read(rideOptionPlacesProvider).value ??
        OptionPlaces.fromBlob(ref.read(displaySettingsBlobProvider).value ?? const <String, dynamic>{});
    return places.here(_context?.place ?? RegionScope.all);
  }

  /// The options the rider can pick for the size chosen, at the pickup.
  List<RideOptionKind> get _offered => freightOptionsHere(_config, _here, vehicleId: _vehicle?.id);

  /// The options picked that are still offered.
  Set<RideOptionKind> get _picked => _options.intersection(_offered.toSet());

  List<OptionChargeLine> get _charges => freightOptionCharges(_picked, _here, _config, offer: _offer ?? 0);

  FareTariff? get _tariff {
    final v = _vehicle;
    if (v == null) return null;
    final a = _context?.area;
    return resolveFareTariff(
      ref.read(fareTariffsProvider).value ?? const [],
      Geo(country: a?.country, state: a?.state, city: a?.city, suburb: a?.suburb),
      vehicleService: v.id,
      serviceTypes: serviceTypeIds(v.service, ref.read(serviceBoxNamesProvider).value ?? const {}),
    );
  }

  /// The pickup country's currency (its tariff card's).
  String get _currency => _tariff?.currency ?? AppConfig.currency;

  RegionPricing get _pricing => _context?.pricing ?? RegionPricing.none;

  /// The pickup's waiting rules, cancel fee and declared value cap.
  FreightPlaceValues get _placeValues => freightPlaceValues(
    ref.read(rideOptionPlacesProvider).value ?? OptionPlaces.none,
    _context?.place ?? RegionScope.all,
  );

  String _money(double v) => formatMoney(v, _currency, v == v.roundToDouble() ? 0 : _pricing.fareDecimals);

  /// The fare estimate for this trip and size; null until both ends are set.
  double? get _recommended {
    final r = _route, v = _vehicle;
    if (r == null || v == null) return null;
    return _pricing.roundFare(quoteFare(_tariff, r.km, r.min, multiplier: v.multiplier, rates: v.rates, fallbackCurrency: AppConfig.currency).fare);
  }

  /// The pickup's context (read again only for a new pickup) and the
  /// route, once both ends are set.
  Future<void> _ends() async {
    final a = _pickup, b = _drop;
    final seq = ++_seq;
    if (a != null && _contextAt != a.place.point) {
      final c = await ref.read(freightPickupContextProvider)(a.place.point);
      if (!mounted || seq != _seq) return;
      setState(() {
        _context = c;
        _contextAt = a.place.point;
      });
    }
    if (a == null || b == null) {
      setState(() => _route = null);
      return;
    }
    final r = await ref.read(freightRouteProvider)(a.place.point, b.place.point);
    if (!mounted || seq != _seq) return;
    setState(() => _route = r);
  }

  Future<void> _address({required bool pickup}) async {
    final picked = await showAppSheet<FreightAddress>(id: 'ride.freight-address',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _AddressSheet(pickup: pickup, initial: pickup ? _pickup : _drop),
    );
    if (picked == null || !mounted) return;
    setState(() => pickup ? _pickup = picked : _drop = picked);
    unawaited(_ends());
  }

  Future<void> _schedule() async {
    ScheduledRidesConfig c;
    try {
      c = await ref.read(scheduledRidesConfigProvider.future);
    } catch (_) {
      c = const ScheduledRidesConfig();
    }
    if (!mounted) return;
    if (!c.enabled) return showInfo(context, 'Scheduled rides are not available.');
    final fare = freightFare(_offer ?? 0, _charges);
    final fee = schedulingFee(fare, c);
    final at = await showPickupTimeSheet(
      context,
      c,
      initial: _scheduleAt,
      note: fee > 0 ? '+ ${_money(fee)} scheduling fee' : null,
    );
    if (at == null || !mounted) return;
    setState(() {
      _scheduleAt = at;
      _time = FreightPickupTime.scheduled;
    });
  }

  Future<void> _describe() async {
    final text = await showAppSheet<String>(id: 'ride.freight-cargo',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _DescriptionSheet(initial: _description),
    );
    if (text != null && mounted) setState(() => _description = text.trim());
  }

  Future<void> _chooseVehicle() async {
    final vehicles = _vehicles;
    final closedOnly = _picked.contains(RideOptionKind.closedBody);
    final id = await showAppSheet<String>(id: 'ride.freight-vehicle',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _VehicleSheet(vehicles: vehicles, selected: _vehicle?.id, closedOnly: closedOnly),
    );
    if (id != null && mounted) setState(() => _vehicleId = id);
  }

  void _toggle(RideOptionKind k) {
    final next = toggleFreightOption(_picked, k);
    final v = _vehicle;
    // A closed body books the covered sizes only: move to the first one.
    if (k == RideOptionKind.closedBody && next.contains(k) && v != null && !v.closedBody) {
      final covered = _vehicles.where((x) => x.closedBody).firstOrNull;
      if (covered == null) return showInfo(context, 'No closed body vehicle is offered yet.');
      setState(() {
        _vehicleId = covered.id;
        _options = next;
      });
      showInfo(context, 'Changed to ${covered.name}, a closed body vehicle.');
      return;
    }
    setState(() => _options = next);
  }

  Future<void> _explainOptions() => showAppSheet<void>(id: 'ride.freight-options-info',
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _OptionsInfoSheet(
      options: _offered,
      config: _config,
      charge: (k) => freightChargeText(_here.freight(k), _money),
    ),
  );

  Future<void> _photoPick() async {
    if (_uploading) return;
    final source = await choosePhotoSource(context, camera: ref.read(photoCameraAvailableProvider));
    if (source == null || !mounted) return;
    final PickedPhoto? photo;
    try {
      photo = await ref.read(photoPickerProvider)(source);
    } catch (_) {
      if (mounted) {
        showInfo(
          context,
          source == PhotoSource.camera
              ? "Couldn't open the camera. Check that GET.ride may use it in Settings."
              : "Couldn't open your photos. Check that GET.ride may use them in Settings.",
        );
      }
      return;
    }
    if (photo == null || !mounted) return;
    final problem = ridePhotoProblem(photo.bytes.length);
    if (problem != null) return showInfo(context, problem);
    setState(() {
      _uploading = true;
      _photo = photo!.bytes;
      _photoPath = null;
    });
    try {
      final path = await ref.read(freightCargoPhotoUploadProvider)(photo.bytes, photo.name);
      if (mounted && identical(_photo, photo.bytes)) setState(() => _photoPath = path);
    } catch (e) {
      if (mounted) {
        setState(() => _photo = null);
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _offerFare() async {
    final style = currencyStyles[_currency.trim().toUpperCase()];
    final v = await showAppSheet<double>(id: 'ride.freight-offer',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FreightOfferSheet(
        initial: _offer ?? _recommended?.roundToDouble(),
        recommended: _recommended,
        currencyLabel: (style?.symbol ?? _currency).trim(),
        money: _money,
      ),
    );
    if (v != null && mounted) setState(() => _offer = v);
  }

  Future<void> _declare() async {
    final style = currencyStyles[_currency.trim().toUpperCase()];
    final cap = _placeValues.declaredCap;
    final v = await showAppSheet<double>(id: 'ride.freight-declared',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FreightAmountSheet(
        title: 'Value of your items',
        initial: _declared,
        currencyLabel: (style?.symbol ?? _currency).trim(),
        hint: 'Up to ${_money(cap)}. Items worth more need another way to send.',
        problem: (v) => declaredValueProblem(v, cap, _money),
      ),
    );
    if (v != null && mounted) setState(() => _declared = v);
  }

  Future<void> _showProhibited() => showAppSheet<void>(id: 'ride.freight-prohibited',
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FreightProhibitedSheet(items: (ref.read(freightConfigProvider).value ?? const FreightConfig()).prohibitedItems),
  );

  Future<void> _chooseRecipient() async {
    final r = await showAppSheet<FreightRecipient>(id: 'ride.freight-recipient',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FreightRecipientSheet(initial: _recipient),
    );
    if (r != null && mounted) setState(() => _recipient = r.phone.trim().isEmpty ? null : r);
  }

  /// What the form has filled in, as the button and [_create] check it.
  FreightDraft get _draft => FreightDraft(
    pickup: _pickup != null,
    drop: _drop != null,
    description: _description,
    vehicle: _vehicle,
    offer: _offer,
    photoUploading: _uploading,
    declaredValue: _declared,
    declaredCap: _placeValues.declaredCap,
    prohibitedAck: _ack,
  );

  Future<void> _create() async {
    final a = _pickup, b = _drop, v = _vehicle;
    final problem = freightDraftProblem(_draft);
    if (problem != null) return showInfo(context, problem);
    setState(() => _booking = true);
    try {
      try {
        if (await ref.read(deviceBlockedProvider.future).timeout(const Duration(seconds: 5))) {
          if (mounted) showInfo(context, 'This device is not permitted to place a request.');
          return;
        }
      } catch (_) {}
      final scheduleAt = _time == FreightPickupTime.scheduled ? _scheduleAt : null;
      if (_time == FreightPickupTime.scheduled) {
        final c = await ref.read(scheduledRidesConfigProvider.future);
        final why = scheduleAt == null
            ? 'Choose the pickup time.'
            : (!c.enabled ? 'Scheduled rides are not available.' : pickupTimeProblem(scheduleAt, DateTime.now(), c));
        if (why != null) {
          if (mounted) showInfo(context, why);
          return;
        }
      }
      // The pickup's place and pricing, if they haven't come yet.
      final ctx = _context ?? await ref.read(freightPickupContextProvider)(a!.place.point);
      if (!mounted) return;
      if (_context == null) setState(() => _context = ctx);
      Profile? profile;
      try {
        profile = await ref.read(profileProvider.future);
      } catch (_) {}
      final picked = _picked;
      final charges = _charges;
      final names = _config.freightNamesFor(picked);
      final route = _route;
      final booked = await ref.read(rideRepositoryProvider).createRequest(
        scheduleAt: scheduleAt,
        service: v!.name,
        pickupName: freightAddressLabel(a!),
        pickupAddress: freightAddressFull(a),
        pickupLat: a.place.point.latitude,
        pickupLng: a.place.point.longitude,
        dropName: freightAddressLabel(b!),
        dropAddress: freightAddressFull(b),
        dropLat: b.place.point.latitude,
        dropLng: b.place.point.longitude,
        distanceKm: route?.km ?? const Distance().as(LengthUnit.Meter, a.place.point, b.place.point) / 1000,
        durationMin: (route?.min ?? 0).round(),
        fare: freightFare(_offer!, charges),
        paymentMode: resolvePayment(_payment, ref.read(paymentChoicesProvider).value ?? builtInPayments),
        note: freightNote(description: _description, options: [for (final k in picked) _config.labelOf(k)], time: _time),
        optionCharges: charges,
        optionNames: names,
        riderName: profile?.name,
        riderPhone: profile?.phone,
        deviceOs: kIsWeb ? 'web' : defaultTargetPlatform.name,
        // Freight is bid on: the rider offers, drivers counter.
        offerMe: true,
        metadata: rideRequestMetadata(area: ctx.area, gender: profile?.raw['gender'] as String?, riderPhoto: profile?.avatarUrl),
        currency: _currency,
        pricing: ctx.pricing,
        timezone: ctx.timezone,
        cargoDescription: _description,
        cargoPhotoPath: _photoPath,
        declaredValue: _declared,
        prohibitedAck: _ack,
        recipient: _recipient,
      );
      if (!mounted) return;
      setState(() {
        _description = '';
        _photo = null;
        _photoPath = null;
        _offer = null;
        _options = const {};
        _declared = null;
        _ack = false;
        _recipient = null;
      });
      // Sent: nothing left to offer again.
      _saver.forget(_saved());
      final later = booked.later;
      if (later != null) {
        ref.invalidate(myScheduledRidesProvider);
        setState(() {
          _scheduleAt = null;
          _time = FreightPickupTime.soon;
        });
        _saver.forget(_saved());
        await showNotice(
          context,
          title: 'Freight scheduled',
          message: 'Pickup ${pickupLabel(confirmedPickupAt(later, scheduleAt))}. '
              "We'll find your driver before then and let you know.",
        );
        if (mounted) GoRouter.maybeOf(context)?.push('/trips/scheduled');
        return;
      }
      _tabs.animateTo(1);
      showInfo(context, 'Request sent. Drivers will send you their offers.');
    } on DuplicateRideRequest catch (e) {
      if (mounted) showInfo(context, e.toString());
    } catch (e) {
      // Refused by the server's service check (0302): its own modal.
      if (mounted && !showServiceNotOffered(context, e)) showError(context, e);
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilt as the sizes, the options' charges and the tariffs arrive.
    ref.watch(freightVehiclesProvider);
    ref.watch(rideOptionsConfigProvider);
    ref.watch(rideOptionPlacesProvider);
    ref.watch(fareTariffsProvider);
    ref.watch(paymentChoicesProvider);
    ref.watch(freightConfigProvider);
    final mine = _tabs.index == 1;
    return Scaffold(
      appBar: AppBar(
        title: Text(mine ? 'My freight requests' : 'Freight'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(key: ValueKey('freight-tab-create'), text: 'Create request'),
            Tab(key: ValueKey('freight-tab-mine'), text: 'My requests'),
          ],
        ),
      ),
      body: TabBarView(controller: _tabs, children: [_form(context), const FreightRequestsList()]),
    );
  }

  Widget _form(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final problem = freightDraftProblem(_draft);
    final v = _vehicle;
    final offered = _offered;
    final picked = _picked;
    final charges = _charges;
    final payments = ref.read(paymentChoicesProvider).value ?? builtInPayments;
    final payment = resolvePayment(_payment, payments);
    final added = optionChargesTotal(charges);
    final look = DeliveryLook.of(context);
    Widget label(String text, {Widget? trailing}) => DeliverySectionLabel(text, trailing: trailing);
    return Column(children: [
      Expanded(
        child: DeliveryChoiceTheme(
          child: ListView(
            key: const ValueKey('freight-form'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              // The route sheet's From over To.
              FreightField(
                key: const ValueKey('freight-pickup'),
                label: 'Pickup location',
                value: _pickup == null ? null : freightAddressLabel(_pickup!),
                leading: const Icon(Icons.emoji_people, semanticLabel: 'Pickup'),
                onTap: () => _address(pickup: true),
              ),
              const SizedBox(height: 12),
              FreightField(
                key: const ValueKey('freight-drop'),
                label: 'Destination',
                value: _drop == null ? null : freightAddressLabel(_drop!),
                leading: const Icon(Icons.flag, semanticLabel: 'Destination'),
                onTap: () => _address(pickup: false),
              ),
              label('Pickup time'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final k in [FreightPickupTime.soon, FreightPickupTime.withinHour])
                  ChoiceChip(
                    key: ValueKey('freight-time-${k.name}'),
                    label: Text(k.label),
                    selected: _time == k,
                    onSelected: (_) => setState(() => _time = k),
                  ),
                ChoiceChip(
                  key: const ValueKey('freight-time-scheduled'),
                  label: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(_time == FreightPickupTime.scheduled && _scheduleAt != null
                        ? pickupLabel(_scheduleAt!)
                        : FreightPickupTime.scheduled.label),
                    const Icon(Icons.expand_more, size: 18),
                  ]),
                  selected: _time == FreightPickupTime.scheduled,
                  onSelected: (_) => _schedule(),
                ),
              ]),
              const SizedBox(height: 12),
              FreightField(
                key: const ValueKey('freight-description'),
                label: 'Description of the cargo',
                value: _description.isEmpty ? null : _description,
                onTap: _describe,
              ),
              const SizedBox(height: 8),
              FreightField(
                key: const ValueKey('freight-vehicle'),
                label: 'Vehicle size',
                value: v?.name,
                placeholder: 'No vehicle sizes yet',
                leading: v == null ? null : FreightVehicleImage(vehicle: v, size: 32),
                onTap: _vehicles.isEmpty ? null : _chooseVehicle,
              ),
              if (offered.isNotEmpty) ...[
                label(
                  'Options',
                  trailing: IconButton(
                    key: const ValueKey('freight-options-info'),
                    tooltip: 'What the options mean',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.info_outline, size: 20, color: t.colorScheme.primary),
                    onPressed: _explainOptions,
                  ),
                ),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final k in offered)
                    FilterChip(
                      key: ValueKey('freight-option-${k.id}'),
                      avatar: Icon(freightOptionIcon(k), size: 18),
                      label: Text(_config.labelOf(k)),
                      selected: picked.contains(k),
                      onSelected: (_) => _toggle(k),
                    ),
                ]),
              ],
              const SizedBox(height: 12),
              FreightField(
                key: const ValueKey('freight-declared'),
                label: 'Value of your items',
                value: _declared == null ? null : _money(_declared!),
                onTap: _declare,
              ),
              CheckboxListTile(
                key: const ValueKey('freight-prohibited-ack'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _ack,
                onChanged: (v) => setState(() => _ack = v ?? false),
                title: const Text('My cargo has none of the prohibited items'),
                subtitle: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('freight-prohibited-list'),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                    onPressed: _showProhibited,
                    child: const Text('See the prohibited items'),
                  ),
                ),
              ),
              FreightField(
                key: const ValueKey('freight-recipient'),
                label: 'Recipient (optional)',
                value: _recipient == null
                    ? null
                    : [if (_recipient!.name.trim().isNotEmpty) _recipient!.name.trim(), _recipient!.phone.trim()].join(' · '),
                onTap: _chooseRecipient,
              ),
              label('Payment'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final p in payments)
                  ChoiceChip(
                    key: ValueKey('freight-payment-${p.value}'),
                    avatar: MediaIcon(p.icon, fallback: paymentLook(p.kind).$1, size: 18),
                    label: Text(p.label),
                    selected: payment == p.value,
                    onSelected: (_) => setState(() => _payment = p.value),
                  ),
              ]),
              label('Picture of your cargo'),
              Row(children: [
                Material(
                  color: look.field,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(look.fieldRadius)),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: const ValueKey('freight-photo'),
                    onTap: _photoPick,
                    child: SizedBox.square(
                      dimension: 72,
                      child: _photo == null
                          ? Icon(Icons.add_a_photo_outlined, color: look.mutedOnField, size: 28)
                          : Stack(fit: StackFit.expand, children: [
                              Image.memory(_photo!, fit: BoxFit.cover),
                              if (_uploading) const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                            ]),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _photo == null ? 'Optional. Drivers see it once they accept.' : (_uploading ? 'Uploading...' : 'Added'),
                    style: t.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
                if (_photo != null && !_uploading)
                  IconButton(
                    key: const ValueKey('freight-photo-remove'),
                    tooltip: 'Remove the photo',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _photo = null;
                      _photoPath = null;
                    }),
                  ),
              ]),
              const SizedBox(height: 12),
              FreightField(
                key: const ValueKey('freight-offer'),
                label: 'Your offer',
                value: _offer == null ? null : _money(_offer!),
                placeholder: 'Offer your fare',
                emphasis: true,
                onTap: _offerFare,
              ),
              if (_offer != null && added > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Text(
                    '${[for (final c in charges) '${c.name} ${_money(c.amount)}'].join(' · ')}. '
                    'Total ${_money(freightFare(_offer!, charges))}',
                    key: const ValueKey('freight-total'),
                    style: t.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
            ],
          ),
        ),
      ),
      DeliveryFooter(
        buttonKey: const ValueKey('freight-create'),
        hintKey: const ValueKey('freight-create-hint'),
        label: 'Create request',
        busy: _booking,
        problem: problem,
        onPressed: _create,
      ),
    ]);
  }
}

/// One row of the form: its label over the value (or the label alone as a
/// placeholder), and a chevron.
class FreightField extends StatelessWidget {
  const FreightField({
    super.key,
    required this.label,
    this.value,
    this.placeholder,
    this.leading,
    this.onTap,
    this.emphasis = false,
  });
  final String label;
  final String? value;
  final String? placeholder;
  final Widget? leading;
  final VoidCallback? onTap;

  /// The value large and bold, as the offered fare reads.
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    // The route sheet's From / To row: its grey box, a dark icon, the label
    // small over the value, the label alone (in grey) while empty.
    final t = Theme.of(context);
    final look = DeliveryLook.of(context);
    final radius = BorderRadius.circular(look.fieldRadius);
    final big = t.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w400, color: look.onField);
    return Material(
      color: look.field,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: look.fieldHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: IconTheme.merge(
              data: IconThemeData(color: look.onField, size: 26),
              child: Row(children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                Expanded(
                  child: value == null
                      ? Text(placeholder ?? label, style: big?.copyWith(color: look.mutedOnField))
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(
                            label,
                            style: t.textTheme.bodySmall?.copyWith(fontSize: 13, height: 1.2, color: look.mutedOnField),
                          ),
                          Text(
                            value!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: emphasis ? big?.copyWith(fontSize: 22, fontWeight: FontWeight.w700) : big,
                          ),
                        ]),
                ),
                Icon(Icons.chevron_right, color: look.mutedOnField, size: 24),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A sheet's title row: the title and a close button.
class FreightSheetHead extends StatelessWidget {
  const FreightSheetHead(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Row(children: [
    const SizedBox(width: 48),
    Expanded(
      child: Text(
        title,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
  ]);
}

/// Cargo loading point / Cargo drop-off point: the address, searched or
/// pinned on the map, then the house number and street: filled in from the
/// search where it says, and the rider's to change.
class _AddressSheet extends ConsumerStatefulWidget {
  const _AddressSheet({required this.pickup, this.initial});
  final bool pickup;
  final FreightAddress? initial;

  @override
  ConsumerState<_AddressSheet> createState() => _AddressSheetState();
}

class _AddressSheetState extends ConsumerState<_AddressSheet> {
  late Place? _place = widget.initial?.place;
  late final _details = TextEditingController(text: widget.initial?.details ?? '');

  /// What the last search filled in: a new search replaces it, never words
  /// the rider typed.
  String _filled = '';

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _pick({bool onMap = false}) async {
    final p = await ref.read(freightPlaceSearchProvider)(
      context,
      title: widget.pickup ? 'Pickup address' : 'Drop-off address',
      near: _place?.point,
      onMap: onMap,
    );
    if (p == null || !mounted) return;
    setState(() {
      _place = p;
      final typed = _details.text.trim();
      if (typed.isEmpty || typed == _filled) {
        _filled = freightStreetOf(p);
        _details.text = _filled;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final place = _place;
    final t = Theme.of(context);
    final look = DeliveryLook.of(context);
    final radius = BorderRadius.circular(look.fieldRadius);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 8, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        key: const ValueKey('freight-address-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FreightSheetHead(widget.pickup ? 'Cargo loading point' : 'Cargo drop-off point'),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: FreightField(
                key: const ValueKey('freight-address-search'),
                label: 'Address',
                placeholder: 'Search the address',
                leading: const Icon(Icons.search),
                value: place?.name,
                onTap: _pick,
              ),
            ),
            IconButton(
              key: const ValueKey('freight-address-map'),
              tooltip: 'Pin on the map',
              icon: const Icon(Icons.map_outlined),
              onPressed: () => _pick(onMap: true),
            ),
          ]),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextField(
              key: const ValueKey('freight-address-details'),
              controller: _details,
              maxLength: freightAddressDetailsMax,
              textCapitalization: TextCapitalization.words,
              style: t.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w400, color: look.onField),
              decoration: InputDecoration(
                labelText: 'House number and street',
                hintText: 'No. 12, Jalan Ampang, Level 3',
                counterText: '',
                filled: true,
                fillColor: look.field,
                labelStyle: TextStyle(color: look.mutedOnField),
                hintStyle: TextStyle(color: look.mutedOnField),
                border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              key: const ValueKey('freight-address-next'),
              style: FilledButton.styleFrom(
                backgroundColor: look.button,
                foregroundColor: look.onButton,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: place == null
                  ? null
                  : () => Navigator.pop(context, (details: _details.text.trim(), place: place)),
              child: const Text('Next'),
            ),
          ),
        ],
      ),
    );
  }
}

class _DescriptionSheet extends StatefulWidget {
  const _DescriptionSheet({required this.initial});
  final String initial;

  @override
  State<_DescriptionSheet> createState() => _DescriptionSheetState();
}

class _DescriptionSheetState extends State<_DescriptionSheet> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(16, 8, 8, 16 + MediaQuery.viewInsetsOf(context).bottom),
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const FreightSheetHead('Description of the cargo'),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: TextField(
          key: const ValueKey('freight-description-field'),
          controller: _text,
          autofocus: true,
          minLines: 3,
          maxLines: 6,
          maxLength: cargoDescriptionMax,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Single-door fridge and 6 boxes, 2nd floor, no lift',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilledButton(
          key: const ValueKey('freight-description-done'),
          onPressed: () => Navigator.pop(context, _text.text),
          child: const Text('Done'),
        ),
      ),
    ]),
  );
}

/// Which vehicle suits your cargo? Each size with its picture, load and
/// load size; with [closedOnly] the open ones can't be chosen.
class _VehicleSheet extends StatelessWidget {
  const _VehicleSheet({required this.vehicles, this.selected, this.closedOnly = false});
  final List<FreightVehicle> vehicles;
  final String? selected;
  final bool closedOnly;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // The home vehicle bar's chosen card.
    final look = DeliveryLook.of(context);
    final radius = BorderRadius.circular(look.choiceRadius);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const FreightSheetHead('Which vehicle suits your cargo?'),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(right: 8),
            child: ListSearchFilter(
              count: vehicles.length,
              hint: 'Search vehicles',
              builder: (context, q) => Column(mainAxisSize: MainAxisSize.min, children: [
                for (final v in vehicles)
                  if (q.isEmpty || searchSelectMatches(v.name, q))
                    () {
                      final off = closedOnly && !v.closedBody;
                      final on = v.id == selected;
                      return Material(
                        color: look.cardFill(on),
                        borderRadius: radius,
                        child: InkWell(
                          key: ValueKey('freight-vehicle-${v.id}'),
                          borderRadius: radius,
                          onTap: off ? null : () => Navigator.pop(context, v.id),
                          child: Opacity(
                            opacity: off ? 0.5 : 1,
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Row(children: [
                                FreightVehicleImage(vehicle: v),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(
                                      v.name,
                                      style: t.textTheme.titleSmall
                                          ?.copyWith(fontWeight: FontWeight.w700, color: look.cardInk(t, on)),
                                    ),
                                    if (v.subtitle.isNotEmpty)
                                      Text(
                                        v.subtitle,
                                        style: t.textTheme.bodySmall?.copyWith(color: look.cardMuted(t, on)),
                                      ),
                                    Wrap(spacing: 6, runSpacing: 4, children: [
                                      if (v.sizeText case final size?) _Tag(size),
                                      if (v.closedBody) const _Tag('Closed body'),
                                      if (off) const _Tag('Not a closed body'),
                                    ]),
                                  ]),
                                ),
                              ]),
                            ),
                          ),
                        ),
                      );
                    }(),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: t.textTheme.labelSmall),
    );
  }
}

/// What the options mean: each one offered, what it is and its charge here.
class _OptionsInfoSheet extends StatelessWidget {
  const _OptionsInfoSheet({required this.options, required this.config, required this.charge});
  final List<RideOptionKind> options;
  final RideOptionsConfig config;
  final String Function(RideOptionKind) charge;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
      child: Column(
        key: const ValueKey('freight-options-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FreightSheetHead('What the options mean'),
          for (final k in options)
            ListTile(
              key: ValueKey('freight-option-info-${k.id}'),
              contentPadding: const EdgeInsets.only(right: 8),
              leading: Icon(freightOptionIcon(k)),
              title: Text(config.labelOf(k)),
              subtitle: Text(freightOptionExplanation(k)),
              trailing: Text(charge(k), style: t.textTheme.bodyMedium?.copyWith(color: muted)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 8, 12),
            child: Text(
              'Helpers and options are added to your offer.',
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ),
        ],
      ),
    );
  }
}

/// Offer your fare: the amount typed in, the suggested range for the trip
/// and size, and that the options come on top.
class FreightOfferSheet extends StatefulWidget {
  const FreightOfferSheet({
    super.key,
    this.initial,
    this.recommended,
    required this.currencyLabel,
    required this.money,
    this.title = 'Offer your fare',
    this.note = 'Helpers and options are added to your offer.',
  });
  final double? initial;

  /// The sheet's title, and the line under the suggestion (none: no line).
  final String title;
  final String? note;
  final double? recommended;
  final String currencyLabel;
  final String Function(double) money;

  @override
  State<FreightOfferSheet> createState() => _FreightOfferSheetState();
}

class _FreightOfferSheetState extends State<FreightOfferSheet> {
  late final _text = TextEditingController(
    text: widget.initial == null || widget.initial! <= 0 ? '' : trimNumber(widget.initial!),
  );
  String? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _done() {
    final v = double.tryParse(_text.text.trim());
    final problem = freightOfferProblem(v, widget.recommended, widget.money);
    if (problem != null) return setState(() => _problem = problem);
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final rec = widget.recommended;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 8, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FreightSheetHead(widget.title),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TextField(
            key: const ValueKey('freight-offer-field'),
            controller: _text,
            autofocus: true,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
            style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
            onChanged: (_) => setState(() => _problem = null),
            onSubmitted: (_) => _done(),
            decoration: InputDecoration(prefixText: '${widget.currencyLabel} ', errorText: _problem),
          ),
        ),
        const SizedBox(height: 8),
        if (rec != null && rec > 0)
          Text(
            freightSuggestionText(rec, widget.money),
            key: const ValueKey('freight-offer-hint'),
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall?.copyWith(color: muted),
          ),
        if (widget.note case final note?)
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 8),
            child: Text(
              note,
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton(key: const ValueKey('freight-offer-done'), onPressed: _done, child: const Text('Done')),
        ),
      ]),
    );
  }
}

/// An amount typed in, checked by [problem] (the declared value).
class FreightAmountSheet extends StatefulWidget {
  const FreightAmountSheet({
    super.key,
    required this.title,
    this.initial,
    required this.currencyLabel,
    required this.hint,
    required this.problem,
  });
  final String title;
  final double? initial;
  final String currencyLabel;
  final String hint;
  final String? Function(double?) problem;

  @override
  State<FreightAmountSheet> createState() => _FreightAmountSheetState();
}

class _FreightAmountSheetState extends State<FreightAmountSheet> {
  late final _text = TextEditingController(text: widget.initial == null ? '' : trimNumber(widget.initial!));
  String? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _done() {
    final v = double.tryParse(_text.text.trim());
    final problem = widget.problem(v);
    if (problem != null) return setState(() => _problem = problem);
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 8, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FreightSheetHead(widget.title),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TextField(
            key: const ValueKey('freight-amount-field'),
            controller: _text,
            autofocus: true,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
            style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            onChanged: (_) => setState(() => _problem = null),
            onSubmitted: (_) => _done(),
            decoration: InputDecoration(prefixText: '${widget.currencyLabel} ', errorText: _problem, errorMaxLines: 3),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 8, 12),
          child: Text(
            widget.hint,
            key: const ValueKey('freight-amount-hint'),
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton(key: const ValueKey('freight-amount-done'), onPressed: _done, child: const Text('Done')),
        ),
      ]),
    );
  }
}

/// What may not be sent (Admin > Freight settings), searchable when long.
class FreightProhibitedSheet extends StatelessWidget {
  const FreightProhibitedSheet({super.key, required this.items});
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
      child: Column(
        key: const ValueKey('freight-prohibited-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FreightSheetHead('Prohibited items'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(right: 8),
              child: ListSearchFilter(
                count: items.length,
                hint: 'Search items',
                builder: (context, q) => Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final i in items)
                    if (q.isEmpty || searchSelectMatches(i, q))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.block, color: t.colorScheme.error),
                        title: Text(i),
                      ),
                ]),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 8, 0),
            child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ),
        ],
      ),
    );
  }
}

/// Who receives the cargo: their name and phone, sent the tracking link
/// when the trip starts.
class FreightRecipientSheet extends StatefulWidget {
  const FreightRecipientSheet({
    super.key,
    this.initial,
    this.note = "We'll send them the tracking link when the trip starts.",
    this.phoneRequired = false,
  });
  final FreightRecipient? initial;

  /// What the recipient is sent, under the fields.
  final String note;

  /// A courier delivery needs the phone (the code and the link go there).
  final bool phoneRequired;

  @override
  State<FreightRecipientSheet> createState() => _FreightRecipientSheetState();
}

class _FreightRecipientSheetState extends State<FreightRecipientSheet> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _phone = TextEditingController(text: widget.initial?.phone ?? '');
  String? _problem;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _done() {
    final phone = _phone.text.trim();
    if (phone.isEmpty && widget.phoneRequired) {
      return setState(() => _problem = "Enter the recipient's phone number.");
    }
    if (phone.isNotEmpty && !recipientPhoneOk(phone)) {
      return setState(() => _problem = 'Enter a phone number, such as +60 12 345 6789.');
    }
    Navigator.pop(context, (name: _name.text.trim(), phone: phone));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 8, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const FreightSheetHead('Who receives it?'),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TextField(
            key: const ValueKey('freight-recipient-name'),
            controller: _name,
            maxLength: 80,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: "Recipient's name"),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TextField(
            key: const ValueKey('freight-recipient-phone'),
            controller: _phone,
            keyboardType: TextInputType.phone,
            onChanged: (_) => setState(() => _problem = null),
            decoration: InputDecoration(labelText: "Recipient's phone", hintText: '+60 12 345 6789', errorText: _problem),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 8, 12),
          child: Text(
            widget.note,
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton(key: const ValueKey('freight-recipient-done'), onPressed: _done, child: const Text('Done')),
        ),
      ]),
    );
  }
}

// ---- My freight requests ------------------------------------------------------------------------

/// The rider's freight requests: each with its status, the driver's offer
/// standing on it (accept or decline, as a ride's) and Cancel while it is
/// open; tapping one opens its trip screen.
class FreightRequestsList extends ConsumerWidget {
  const FreightRequestsList({super.key, this.kind = DeliveryKind.freight});

  /// Freight requests, or with [DeliveryKind.courier] My deliveries (0268).
  final DeliveryKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final courier = kind == DeliveryKind.courier;
    final provider = courier ? myCourierRequestsProvider : myFreightRequestsProvider;
    final list = ref.watch(provider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(courier ? "Couldn't load your deliveries." : "Couldn't load your freight requests."),
            TextButton(onPressed: () => ref.invalidate(provider), child: const Text('Try again')),
          ]),
        ),
      ),
      data: (rows) => rows.isEmpty
          ? Center(
              key: ValueKey('${kind.name}-requests-empty'),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  courier
                      ? 'No deliveries yet. Send a parcel and couriers will send you their offers.'
                      : 'No freight requests yet. Create one and drivers will send you their offers.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            )
          : ListView.separated(
              key: ValueKey('${kind.name}-requests'),
              padding: const EdgeInsets.all(16),
              itemCount: rows.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => FreightRequestCard(request: rows[i], kind: kind),
            ),
    );
  }
}

class FreightRequestCard extends ConsumerStatefulWidget {
  const FreightRequestCard({super.key, required this.request, this.kind = DeliveryKind.freight});
  final RideRequest request;
  final DeliveryKind kind;

  @override
  ConsumerState<FreightRequestCard> createState() => _FreightRequestCardState();
}

class _FreightRequestCardState extends ConsumerState<FreightRequestCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
      ref.invalidate(widget.kind == DeliveryKind.courier ? myCourierRequestsProvider : myFreightRequestsProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open() => GoRouter.maybeOf(context)?.push('/ride/${widget.request.id}');

  Future<void> _cancel() async {
    final ok = await showAppDialog<bool>(id: 'ride.freight-cancel',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cancel this request?'),
        content: Text('${widget.kind == DeliveryKind.courier ? 'Couriers' : 'Drivers'} will no longer see it or send offers.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
          FilledButton(
            key: const ValueKey('freight-cancel-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Cancel request'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(() => ref.read(rideRepositoryProvider).cancel(widget.request, reason: 'Cancelled by rider', by: 'rider'));
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final status = '${r.raw['status'] ?? 'open'}';
    final open = r.status == RideStatus.open;
    final offer = standingOffer(r);
    final charges = r.optionCharges;
    final fare = r.effectiveFare ?? 0;
    final kind = widget.kind;
    final courier = kind == DeliveryKind.courier;
    final p = kind.name;
    final vehicle = freightVehicleNamed(ref.watch(deliveryVehiclesProvider(kind)).value ?? const [], r.service);
    final vehicleName = vehicle?.shortName ?? r.service ?? kind.serviceType;
    return Card(
      key: ValueKey('$p-request-${r.id}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _open,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: t.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(6)),
                child: Text(
                  deliveryStatusLabel(kind, status),
                  key: ValueKey('$p-request-status-${r.id}'),
                  style: t.textTheme.labelSmall?.copyWith(
                    color: t.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  r.createdAt == null ? '' : formatDateTime(r.createdAt),
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.labelSmall?.copyWith(color: muted),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              FreightVehicleImage(vehicle: vehicle, size: 28),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  open
                      ? '$vehicleName · your offer ${r.fareText(freightOfferOf(fare, charges))}'
                      : '$vehicleName · ${r.fareText(fare)}',
                  style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ]),
            if (charges.isNotEmpty)
              Text(
                '+ ${[for (final c in charges) '${c.name} ${r.fareText(c.amount)}'].join(' · ')}',
                style: t.textTheme.bodySmall?.copyWith(color: muted),
              ),
            const SizedBox(height: 4),
            Text(r.pickupLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall),
            Text(r.dropLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall),
            if (r.cargoDescription case final d?)
              Text(d, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: muted)),
            // Courier (0268): the size, who pays and the code to pass on.
            if (courier) ...[
              if (r.recipientPays)
                Text(
                  recipientPaysText(r.fareText(fare)),
                  key: ValueKey('courier-request-payer-${r.id}'),
                  style: t.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              if (r.status != RideStatus.cancelled && r.status != RideStatus.completed && r.raw['status'] != 'expired') ...[
                const SizedBox(height: 8),
                CourierCodeCard(request: r),
              ],
            ],
            if (open) ...[
              const Divider(height: 16),
              if (offer == null)
                Text(
                  courier ? 'Waiting for courier offers' : 'Waiting for driver offers',
                  key: ValueKey('$p-request-waiting-${r.id}'),
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
              // The ride offer cards, as the trip screen deals them (in from
              // the right, out to the left): one bid stands on a request.
              OfferStack(
                key: ValueKey('$p-request-offers-${r.id}'),
                offers: [
                  if (offer != null)
                    SearchOfferView(
                      key: offer.key,
                      cardKey: ValueKey('$p-request-offer-${r.id}'),
                      acceptKey: ValueKey('$p-request-accept-${r.id}'),
                      declineKey: ValueKey('$p-request-decline-${r.id}'),
                      amount: offer.amount,
                      price: r.fareText(offer.amount),
                      yourFare: (offer.amount - fare).abs() < 0.005,
                      progress: 1,
                      name: offer.name,
                      rating: offer.rating,
                      trips: offer.trips,
                      vehicle: offer.vehicle,
                      plate: offer.plate,
                      plateColours: offer.plateColours,
                      photo: offer.photo,
                      onDecline: _busy
                          ? null
                          : () => _run(() => ref.read(rideRepositoryProvider).declineOffer(r.id, partnerId: offer.partnerId)),
                      onAccept: _busy
                          ? null
                          : () => _run(() async {
                              final taken = await ref
                                  .read(rideRepositoryProvider)
                                  .acceptOffer(r.id, partnerId: offer.partnerId, amount: offer.amount);
                              if (taken == null) throw StateError('That offer is no longer there.');
                              if (mounted) _open();
                            }),
                    ),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: ValueKey('$p-request-cancel-${r.id}'),
                  onPressed: _busy ? null : _cancel,
                  child: const Text('Cancel request'),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
