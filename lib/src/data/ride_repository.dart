import 'dart:async';
import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';

import 'package:latlong2/latlong.dart';

import '../core/book_for.dart';
import '../core/commission.dart';
import '../core/driver_eta.dart';
import '../core/request_viewers.dart';
import '../core/ride_request_metadata.dart';
import '../core/ride_share.dart';
import '../core/session_telemetry.dart';
import '../core/fare_coins.dart';
import '../core/region_pricing.dart';
import '../core/format.dart' show setRegionCurrencySymbols;
import '../core/ride_bidding.dart';
import '../core/ride_stops.dart';
import '../core/trip_charges.dart';
import '../core/trip_checkpoint.dart';
import 'geo_service.dart';
import 'models.dart';

/// Ride booking + dispatch over `public.ride_requests`, mirroring the Expo
/// app's `utils/rideRequestsStore.ts`. Partners are identified by their auth
/// uid in `partner_id`, exactly as the Expo e-hailing screen does.
class RideRepository {
  RideRepository(this._db);
  final SupabaseClient _db;
  static const _table = 'ride_requests';

  String? get _uid => _db.auth.currentUser?.id;

  Future<RideRequest> createRequest({
    required String service,
    required String pickupName,
    required String pickupAddress,
    required double pickupLat,
    required double pickupLng,
    required String dropName,
    required String dropAddress,
    required double dropLat,
    required double dropLng,
    required double distanceKm,
    required int durationMin,
    required double fare,
    String paymentMode = 'Cash',
    int passengers = 1,
    String? note,
    String? riderName,
    String? riderPhone,
    String? deviceOs,
    bool offerMe = false,
    List<Place> stops = const [],
    Map<String, Object> metadata = const {},
    BookedFor? bookedFor,
    String currency = AppConfig.currency,
    RegionPricing pricing = RegionPricing.none,
    String? timezone,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Sign in to book a ride.');
    final otp = (1000 + math.Random.secure().nextInt(9000)).toString();
    final row = {
      'id': const Uuid().v4(),
      'rider_id': uid,
      'rider_name': riderName,
      'rider_phone': riderPhone,
      'rider_rating': 5,
      'service': service,
      'payment_mode': paymentMode,
      'pickup_name': pickupName,
      'pickup_address': pickupAddress,
      'pickup_lat': pickupLat,
      'pickup_lng': pickupLng,
      'drop_name': dropName,
      'drop_address': dropAddress,
      'drop_lat': dropLat,
      'drop_lng': dropLng,
      'distance_km': double.parse(distanceKm.toStringAsFixed(2)),
      'duration_min': durationMin,
      'fare': fare,
      'ride_fare': fare,
      'currency': currency,
      'passengers': passengers,
      'luggage': 0,
      'note': note,
      'offer_me': offerMe,
      'otp': otp,
      'device_os': deviceOs,
      'user_accept_lat': pickupLat,
      'user_accept_lng': pickupLng,
      'status': 'open',
      if (stops.isNotEmpty) 'stops': [for (final p in stops.take(maxRideStops)) stopToJson(p)],
      if (bookedFor != null) 'booked_for_name': bookedFor.name,
      if (bookedFor != null) 'booked_for_phone': bookedFor.phone,
      ...metadata,
      if (pricing != RegionPricing.none) ...pricing.toRideColumns(),
      'timezone': ?timezone,
    };
    // Stops, the metadata, the region's pricing and its time zone are
    // extras: a database without one of their columns (stops needs 0098,
    // pricing 0119, the zone 0124) books the ride without it rather than
    // failing.
    final optional = {'stops', ...metadata.keys, ...RegionPricing.none.toRideColumns().keys, 'timezone'};
    Map<String, dynamic> data;
    for (var attempt = 0;; attempt++) {
      try {
        data = await _db.from(_table).insert(row).select().single();
        break;
      } on PostgrestException catch (e) {
        // A second request while one is on the go: refused before it was
        // written, so nothing reached the drivers (migration 0107).
        if (isDuplicateRideError(e.message)) throw DuplicateRideRequest(forOthers: bookedFor != null);
        // A place GET.ride doesn't serve: the database's own check (0125).
        final unserved = ServiceUnavailableError.parse(e.message);
        if (unserved != null) throw unserved;
        // Never quietly book someone else's ride as the rider's own.
        if (bookedFor != null && e.message.contains('booked_for')) {
          throw StateError("Booking for someone else isn't available yet. Please try again later.");
        }
        final col = droppableRideColumn('${e.message} ${e.details}', optional, row.keys);
        if (attempt >= optional.length || col == null) rethrow;
        row.remove(col);
      }
    }
    final req = RideRequest(data);
    unawaited(_notifyPartners(req));
    return req;
  }

  /// The caller's public IP as the `ip-lookup` edge function sees it, or null.
  Future<String?> publicIp() async {
    try {
      final res = await _db.functions.invoke('ip-lookup', body: {}).timeout(const Duration(seconds: 4));
      return IpInfo.fromResponse(res.data)?.publicIp;
    } catch (_) {
      return null;
    }
  }

  /// Best-effort push to online partners through the shared `send-push` edge
  /// function (same payload as the Expo app).
  Future<void> _notifyPartners(RideRequest r) async {
    try {
      await _db.functions.invoke(
        'send-push',
        body: {
          'title': 'New Request',
          'body': '${r.currency} ${r.fare?.round() ?? ''} , ${r.pickupLabel} -> ${r.dropLabel}',
          'audience': 'partners',
          'data': {'type': 'new_ride_request', 'requestId': r.id},
        },
      );
    } catch (_) {}
  }

  Future<void> expireStaleOpen() async {
    final uid = _uid;
    if (uid == null) return;
    final cutoff = DateTime.now().toUtc().subtract(AppConfig.requestExpiry).toIso8601String();
    try {
      await _db
          .from(_table)
          .update({'status': 'expired'})
          .eq('status', 'open')
          .eq('rider_id', uid)
          .lt('created_at', cutoff);
    } catch (_) {}
  }

  /// The rider's own ride on the go. Rides they booked for other people
  /// are [ridesOnTheGo]; they never stand in the way of the rider's own.
  Future<RideRequest?> ongoingForRider() async => ownRide(await ridesOnTheGo());

  /// Every ride this rider has on the go, their own and those booked for
  /// others, newest first.
  Future<List<RideRequest>> ridesOnTheGo() async {
    final uid = _uid;
    if (uid == null) return const [];
    await expireStaleOpen();
    final rows = await _db
        .from(_table)
        .select()
        .eq('rider_id', uid)
        .inFilter('status', riderOngoingStatuses)
        .order('created_at', ascending: false)
        .limit(20);
    return rows.map(RideRequest.new).toList();
  }

  Future<RideRequest?> ongoingForPartner() async {
    final uid = _uid;
    if (uid == null) return null;
    final rows = await _db
        .from(_table)
        .select()
        .eq('partner_id', uid)
        .inFilter('status', partnerOngoingStatuses)
        .order('created_at', ascending: false)
        .limit(1);
    return rows.isEmpty ? null : RideRequest(rows.first);
  }

  Future<List<RideRequest>> history({int limit = 50}) async {
    final uid = _uid;
    if (uid == null) return [];
    final rows = await _db
        .from(_table)
        .select()
        .or('rider_id.eq.$uid,partner_id.eq.$uid')
        .order('created_at', ascending: false)
        .limit(limit);
    return rows.map(RideRequest.new).toList();
  }

  Future<RideRequest?> fetch(String id) async {
    final row = await _db.from(_table).select().eq('id', id).maybeSingle();
    return row == null ? null : RideRequest(row);
  }

  Future<List<RideRequest>> openRequests({int limit = 30}) async {
    final cutoff = DateTime.now().toUtc().subtract(AppConfig.requestExpiry).toIso8601String();
    final rows = await _db
        .from(_table)
        .select()
        .eq('status', 'open')
        .gte('created_at', cutoff)
        .order('created_at', ascending: false)
        .limit(limit);
    return rows.map(RideRequest.new).where((r) => r.riderId != _uid).toList();
  }

  /// Atomically claims an open request. Returns null when another partner won
  /// the race (the `status = open` guard no longer matches).
  Future<RideRequest?> accept(
    String id,
    Partner? partner, {
    double? lat,
    double? lng,
    String? fallbackName,
    String? fallbackPhone,
  }) async {
    final row = await _db
        .from(_table)
        .update({
          'status': 'accepted',
          'accepted_at': DateTime.now().toUtc().toIso8601String(),
          'partner_id': _uid,
          'partner_name': partner?.name ?? fallbackName,
          'partner_phone': partner?.phone ?? fallbackPhone,
          'partner_photo': partner?.avatarUrl,
          'partner_vehicle': partner?.vehicle,
          'partner_plate': partner?.plate,
          'partner_rating': partner?.rating,
          'partner_accept_lat': lat,
          'partner_accept_lng': lng,
          // Taking the rider's own fare supersedes any bid still on the row.
          'offered_fare': null,
        })
        .eq('id', id)
        .eq('status', 'open')
        .select()
        .maybeSingle();
    return row == null ? null : RideRequest(row);
  }

  // ---- Fare bidding (see core/ride_bidding.dart for the shared contract) ----

  /// The admin's regions (Admin → Country / States / Cities, saved to the
  /// `countries` / `states` / `cities` / `suburbs` tables) with each one's
  /// bidding switch, pricing and services. Old `country-states-cities`
  /// settings entries are read too. A table that cannot be read is skipped;
  /// empty when none can, and bidding then stays on. Kept for
  /// [regionsCacheFor] so one pickup's checks share a read, while an admin's
  /// change is picked up on the next check after that.
  Future<List<BiddingRegion>> biddingRegions() {
    final cached = _regions;
    if (cached != null && DateTime.now().difference(cached.at) < regionsCacheFor) return cached.list;
    final list = _readRegions();
    _regions = (at: DateTime.now(), list: list);
    return list;
  }

  static const regionsCacheFor = Duration(seconds: 20);
  ({DateTime at, Future<List<BiddingRegion>> list})? _regions;

  Future<List<BiddingRegion>> _readRegions() async {
    Future<List<BiddingRegion>> table(String t, String select) async {
      try {
        final rows = await _db.from(t).select(select);
        return [for (final r in rows) ?BiddingRegion.fromRegionRow(t, Map<String, dynamic>.from(r))];
      } catch (_) {
        return const [];
      }
    }

    Future<List<BiddingRegion>> legacy() async {
      try {
        final rows = await _db.from('settings_entries').select('values').eq('category', 'country-states-cities');
        return [
          for (final r in rows)
            if (r['values'] is Map) ?BiddingRegion.fromValues(Map<String, dynamic>.from(r['values'] as Map)),
        ];
      } catch (_) {
        return const [];
      }
    }

    final parts = await Future.wait([
      for (final e in regionTableSelects.entries) table(e.key, e.value),
      legacy(),
    ]);
    final regions = [for (final p in parts) ...p];
    // Amounts in a region's currency print with the symbol it gives it.
    setRegionCurrencySymbols(regionCurrencySymbols(regions));
    return regions;
  }

  /// The `service-settings` ids switched on for [pickup]'s region; null when
  /// no region restricts them.
  Future<Set<String>?> servicesFor(LatLng pickup, Future<AreaInfo?> Function() area) async {
    final regions = await biddingRegions();
    if (!regions.any((r) => r.services != null)) return null;
    AreaInfo? names;
    try {
      names = await area().timeout(const Duration(seconds: 5));
    } catch (_) {}
    return servicesAt(regions, pickup, area: names);
  }

  /// The regions around [pickup] and their scheduled rules (service hours,
  /// bidding, taxes, surcharges), for pricing each service at booking time.
  /// Whether GET.ride serves [point] (see [coverageGap]): null when it
  /// does, or when the regions can't be read.
  Future<({CoverageGap gap, BiddingRegion? region})?> coverageAt(LatLng point, Future<AreaInfo?> Function() area) async {
    final regions = await biddingRegions();
    if (regions.isEmpty) return null;
    AreaInfo? names;
    try {
      names = await area().timeout(const Duration(seconds: 5));
    } catch (_) {}
    return coverageGap(regions, point, area: names);
  }

  Future<RegionRuleContext> ruleContextFor(LatLng pickup, Future<AreaInfo?> Function() area) async {
    final regions = await biddingRegions();
    if (regions.isEmpty) return RegionRuleContext.empty;
    AreaInfo? names;
    try {
      names = await area().timeout(const Duration(seconds: 5));
    } catch (_) {}
    return RegionRuleContext(regionsAround(regions, pickup, area: names));
  }

  /// How fares are priced at [pickup] (whole amounts, tax): the region's
  /// own setting, found as the bidding switch is. None when unreadable.
  Future<RegionPricing> pricingFor(LatLng pickup, Future<AreaInfo?> Function() area) async {
    final regions = await biddingRegions();
    if (!regions.any((r) => r.pricing != null)) return RegionPricing.none;
    AreaInfo? names;
    try {
      names = await area().timeout(const Duration(seconds: 5));
    } catch (_) {}
    return pricingAt(regions, pickup, area: names);
  }

  /// Whether the rider may be bid on at [pickup] (Expo `useRegionBidding`).
  /// Names are only looked up when no mapped boundary decides.
  Future<bool> biddingEnabledFor(LatLng pickup, Future<AreaInfo?> Function() area) async {
    final regions = await biddingRegions();
    if (regions.isEmpty) return true;
    final byBoundary = biddingByBoundary(regions, pickup);
    if (byBoundary != null) return byBoundary;
    AreaInfo? names;
    try {
      names = await area().timeout(const Duration(seconds: 5));
    } catch (_) {}
    return biddingEnabledAt(regions, pickup, area: names);
  }

  static const _bidFields = [
    'offered_fare',
    'partner_id',
    'partner_name',
    'partner_phone',
    'partner_photo',
    'partner_vehicle',
    'partner_plate',
    'partner_rating',
    'vehicle_id',
    'partner_accept_lat',
    'partner_accept_lng',
  ];

  static Map<String, dynamic> get _noBid => {for (final f in _bidFields) f: null};

  /// A partner's counter-offer on an open request. Null when the request is
  /// no longer open (taken, cancelled, expired).
  Future<RideRequest?> submitOffer(
    String id,
    double amount,
    Partner? partner, {
    double? lat,
    double? lng,
    String? fallbackName,
    String? fallbackPhone,
  }) async {
    final row = await _db
        .from(_table)
        .update({
          'offered_fare': amount,
          'partner_id': _uid,
          'partner_name': partner?.name ?? fallbackName,
          'partner_phone': partner?.phone ?? fallbackPhone,
          'partner_photo': partner?.avatarUrl,
          'partner_vehicle': partner?.vehicle,
          'partner_plate': partner?.plate,
          'partner_rating': partner?.rating,
          'partner_accept_lat': lat,
          'partner_accept_lng': lng,
        })
        .eq('id', id)
        .eq('status', 'open')
        .select()
        .maybeSingle();
    return row == null ? null : RideRequest(row);
  }

  /// Takes this partner's own standing offer back off the row.
  Future<void> withdrawOffer(String id) async {
    final uid = _uid;
    if (uid == null) return;
    await _db.from(_table).update(_noBid).eq('id', id).eq('status', 'open').eq('partner_id', uid);
  }

  /// The rider raises the fare on their open request. Every standing bid is
  /// cleared, and partners are told the fare went up. Null when the request
  /// is no longer open.
  Future<RideRequest?> raiseFare(String id, double fare) async {
    final row = await _db
        .from(_table)
        .update({'fare': fare, 'ride_fare': fare, ..._noBid})
        .eq('id', id)
        .eq('status', 'open')
        .select()
        .maybeSingle();
    if (row == null) return null;
    final r = RideRequest(row);
    unawaited(_notifyFareRaised(r));
    return r;
  }

  Future<void> _notifyFareRaised(RideRequest r) async {
    try {
      await _db.functions.invoke(
        'send-push',
        body: {
          'title': 'Fare increased',
          'body': '${r.currency} ${r.fare?.round() ?? ''} , ${r.pickupLabel} -> ${r.dropLabel}',
          'audience': 'partners',
          'data': {'type': 'ride_request_fare_raised', 'requestId': r.id},
        },
      );
    } catch (_) {}
  }

  /// The rider takes [partnerId]'s offer of [amount]: their own row moves
  /// to `accepted` with that partner, billed at the offer. Matched on the
  /// exact partner and amount, so a bid that changed since it was shown is
  /// never accepted; null in that case.
  Future<RideRequest?> acceptOffer(String id, {required String partnerId, required double amount}) async {
    final row = await _db
        .from(_table)
        .update({
          'status': 'accepted',
          'accepted_at': DateTime.now().toUtc().toIso8601String(),
          'fare': amount,
          'ride_fare': amount,
        })
        .eq('id', id)
        .eq('status', 'open')
        .eq('partner_id', partnerId)
        .eq('offered_fare', amount.toStringAsFixed(2))
        .select()
        .maybeSingle();
    return row == null ? null : RideRequest(row);
  }

  /// The rider turns [partnerId]'s offer down, leaving the request open for
  /// other partners.
  Future<void> declineOffer(String id, {required String partnerId}) async {
    await _db.from(_table).update(_noBid).eq('id', id).eq('status', 'open').eq('partner_id', partnerId);
  }

  /// Claims the GET.coin ride reward for the rider of a completed ride
  /// (`wallet_award_ride_coins`). The server prices it on the ride's stored
  /// fare (migration 0093), checks the caller is the rider and pays
  /// once per ride, so calling again is harmless and answers 0. Answers 0
  /// when there is nothing to claim or the call fails.
  Future<double> claimRideReward(RideRequest r) async {
    final uid = _uid;
    final fare = r.effectiveFare ?? 0;
    if (uid == null || r.status != RideStatus.completed || r.riderId != uid || fare <= 0) return 0;
    try {
      final v = await _db.rpc('wallet_award_ride_coins', params: {'p_ride': r.id, 'p_user': uid, 'p_fare': fare});
      return v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Pays part of a completed ride's fare with the rider's GET.coin
  /// (`wallet_redeem_fare_coins`). The server takes as much as the balance
  /// covers at the admin rate, checks the caller is the rider and redeems
  /// once per ride (`fare_coins_redeemed_at`), so asking again answers zero.
  /// Null when the call fails, so the caller can try again later.
  Future<FareCoinRedemption?> redeemFareCoins(RideRequest r) async {
    final uid = _uid;
    // What the rider owes on the ride, tolls and charges included; the server
    // caps it the same way and credits the coin value to the driver (0101).
    final fare = r.totalDue ?? 0;
    if (uid == null || r.status != RideStatus.completed || r.riderId != uid || fare <= 0) {
      return (coinsUsed: 0.0, coinValue: 0.0);
    }
    try {
      final data = await _db.rpc('wallet_redeem_fare_coins', params: {'p_user': uid, 'p_fare': fare, 'p_ride': r.id});
      return fareCoinRedemptionFrom(data);
    } catch (_) {
      return null;
    }
  }

  Future<void> updateStatus(String id, RideStatus status) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final patch = <String, dynamic>{'status': status.db};
    switch (status) {
      case RideStatus.arrived:
        patch['arrived_at'] = now;
      case RideStatus.onTrip:
        patch['started_at'] = now;
      case RideStatus.completed:
        patch['completed_at'] = now;
      case RideStatus.cancelled:
        patch['cancelled_at'] = now;
      default:
        break;
    }
    await _db.from(_table).update(patch).eq('id', id);
  }

  /// Rider cancel. An open request is cancelled outright; once a partner has
  /// accepted, a cancellation *request* is raised for the other side to
  /// approve (Expo `requestRideCancellation`).
  Future<void> cancel(RideRequest r, {String? reason, required String by}) async {
    if (r.status == RideStatus.open) {
      await _db
          .from(_table)
          .update({
            'status': 'cancelled',
            'cancelled_at': DateTime.now().toUtc().toIso8601String(),
            'cancel_reason': reason,
          })
          .eq('id', r.id);
      return;
    }
    await _db
        .from(_table)
        .update({
          'cancel_requested_at': DateTime.now().toUtc().toIso8601String(),
          'cancel_requested_by': by,
          'cancel_reason': reason,
        })
        .eq('id', r.id)
        .inFilter('status', partnerOngoingStatuses);
  }

  /// The ride's share link token, made on first share (migration 0108).
  /// Only the ride's rider can make one.
  Future<String> shareToken(String rideId) async {
    final v = await _db.rpc('ride_share_link', params: {'p_ride': rideId});
    if (v is! String || v.isEmpty) throw StateError("This ride can't be shared.");
    return v;
  }

  /// The ride a share link shows, read without an account. Null when the
  /// link is unknown or has expired.
  Future<SharedRide?> sharedRide(String token) async {
    if (!isShareToken(token)) return null;
    final v = await _db.rpc('ride_share_view', params: {'p_token': token});
    return v is Map ? SharedRide(Map<String, dynamic>.from(v)) : null;
  }

  /// How far the nearest online driver is, per vehicle type, from [lat],
  /// [lng] (0111). Empty when none is near, or the database predates it.
  /// The driver's app has this request on screen (migration 0112). Quiet
  /// on failure: an older database simply shows the rider no bar.
  Future<void> markViewed(String requestId) async {
    try {
      await _db.rpc('ride_request_viewed', params: {'p_request': requestId});
    } catch (_) {}
  }

  /// Who has looked at the rider's request, for the bar over the sheet.
  Future<RequestViewers> viewers(String requestId) async {
    try {
      return RequestViewers.parse(await _db.rpc('ride_request_viewers', params: {'p_request': requestId}));
    } catch (_) {
      return RequestViewers.none;
    }
  }

  Future<Map<String, double>> nearbyDrivers(double lat, double lng) async {
    try {
      final rows = await _db.rpc('nearby_driver_etas', params: {'p_lat': lat, 'p_lng': lng});
      return parseNearbyDrivers(rows);
    } catch (_) {
      return const {};
    }
  }

  /// The driver cancels outright, with a reason. Only before the passenger
  /// is on board ([driverMayCancel]; migration 0106 refuses it after
  /// pickup). Null when the ride had already moved on (picked up, or ended).
  Future<RideRequest?> cancelAsDriver(String id, String reason) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final row = await _db
        .from(_table)
        .update({
          'status': 'cancelled',
          'cancelled_at': now,
          'cancel_reason': reason,
          'cancel_requested_by': 'partner',
          'cancel_requested_at': now,
        })
        .eq('id', id)
        .inFilter('status', const ['accepted', 'arrived'])
        .select()
        .maybeSingle();
    return row == null ? null : RideRequest(row);
  }

  Future<void> approveCancellation(String id) => updateStatus(id, RideStatus.cancelled);

  Future<void> declineCancellation(String id) =>
      _db.from(_table).update({'cancel_requested_at': null, 'cancel_requested_by': null}).eq('id', id);

  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) => _db
      .from(_table)
      .update({
        'partner_live_lat': lat,
        'partner_live_lng': lng,
        'partner_live_heading': heading,
        'partner_live_at': DateTime.now().toUtc().toIso8601String(),
      })
      .eq('id', id);

  /// Stamps where the driver was at a trip milestone (see
  /// core/trip_checkpoint.dart). Best-effort: a failed write never holds up
  /// the trip, so this answers false instead of throwing.
  Future<bool> recordCheckpoint(String id, TripCheckpoint checkpoint, double? lat, double? lng) async {
    final patch = checkpointPatch(checkpoint, lat, lng);
    if (patch == null) return false;
    try {
      await _db.from(_table).update(patch).eq('id', id);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> publishRiderLocation(String id, double lat, double lng) => _db
      .from(_table)
      .update({'user_live_lat': lat, 'user_live_lng': lng, 'user_live_at': DateTime.now().toUtc().toIso8601String()})
      .eq('id', id);

  /// Completes the trip and charges the partner's commission through the
  /// shared `wallet_charge_ride_commission` RPC (idempotent per ride).
  ///
  /// [charges] are the tolls and other charges the driver declared; they are
  /// stored with the completion and are not part of the commissionable fare.
  ///
  /// [earlyFare] ends the trip before the drop-off: the ride is stored at
  /// that fare (`ride_fare`) and stamped `ended_early_at`, and commission is
  /// charged on it rather than on the booked fare.
  Future<void> complete(RideRequest r, {TripCharges charges = TripCharges.none, double? earlyFare}) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final patch = <String, dynamic>{
      'status': RideStatus.completed.db,
      'completed_at': now,
      ...charges.toPatch(),
      if (earlyFare != null) ...{'ride_fare': earlyFare, 'ended_early_at': now},
    };
    // Columns a database without the newer migrations lacks: dropped one at
    // a time, so the fare and the amounts still land.
    const optional = ['other_charges_note', 'ended_early_at']; // 0100, 0104
    while (true) {
      try {
        await _db.from(_table).update(patch).eq('id', r.id);
        break;
      } on PostgrestException catch (e) {
        final text = '${e.message} ${e.details}';
        final missing = optional.where((c) => patch.containsKey(c) && text.contains(c)).firstOrNull;
        if (missing == null) rethrow;
        patch.remove(missing);
      }
    }
    final fare = earlyFare ?? r.effectiveFare ?? 0;
    final uid = _uid;
    if (fare <= 0 || uid == null) return;
    try {
      final rows = await _db
          .from('commission_rates')
          .select('level, country, state, city, suburb, user_id, rate, active')
          .order('updated_at', ascending: false);
      final rate = resolveCommissionRate(
        rows.map(CommissionRule.fromRow).toList(),
        userId: uid,
        geo: Geo(
          country: r.raw['country'] as String?,
          state: r.raw['state'] as String?,
          city: r.raw['city'] as String?,
          suburb: r.raw['suburb'] as String?,
        ),
      );
      if (rate <= 0 || rate >= 1) return;
      await _db.rpc(
        'wallet_charge_ride_commission',
        params: {'p_ride': r.id, 'p_partner': uid, 'p_fare': fare, 'p_rate': rate},
      );
    } catch (_) {
      // Commission is reconciled by the back office if this best-effort call fails.
    }
  }

  /// Live updates for a single request.
  Stream<RideRequest> watch(String id) {
    final controller = StreamController<RideRequest>();
    RealtimeChannel? channel;
    controller.onListen = () async {
      final first = await fetch(id);
      if (first != null && !controller.isClosed) controller.add(first);
      channel = _db
          .channel('ride_request_${id}_${DateTime.now().microsecondsSinceEpoch}')
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: _table,
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: id),
            callback: (p) {
              if (!controller.isClosed && p.newRecord.isNotEmpty) {
                controller.add(RideRequest(p.newRecord));
              }
            },
          )
          .subscribe();
    };
    controller.onCancel = () async {
      if (channel != null) await _db.removeChannel(channel!);
      await controller.close();
    };
    return controller.stream;
  }

  /// Live partner queue: emits the full open list whenever anything changes.
  Stream<List<RideRequest>> watchOpen() {
    final controller = StreamController<List<RideRequest>>();
    RealtimeChannel? channel;
    Timer? ticker;
    Future<void> refresh() async {
      try {
        final list = await openRequests();
        if (!controller.isClosed) controller.add(list);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      }
    }

    controller.onListen = () {
      refresh();
      channel = _db
          .channel('ride_requests_open_${DateTime.now().microsecondsSinceEpoch}')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: _table,
            callback: (_) => refresh(),
          )
          .subscribe();
      // Drops requests as they age past the expiry window.
      ticker = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
    };
    controller.onCancel = () async {
      ticker?.cancel();
      if (channel != null) await _db.removeChannel(channel!);
      await controller.close();
    };
    return controller.stream;
  }
}
