import 'dart:async';
import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';

import 'package:latlong2/latlong.dart';

import '../core/commission.dart';
import '../core/ride_request_metadata.dart';
import '../core/session_telemetry.dart';
import '../core/fare_coins.dart';
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
      'currency': AppConfig.currency,
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
      ...metadata,
    };
    // Stops and the metadata are extras: a database without one of their
    // columns (stops needs 0098) books the ride without it rather than failing.
    final optional = {'stops', ...metadata.keys};
    Map<String, dynamic> data;
    for (var attempt = 0;; attempt++) {
      try {
        data = await _db.from(_table).insert(row).select().single();
        break;
      } on PostgrestException catch (e) {
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

  Future<RideRequest?> ongoingForRider() async {
    final uid = _uid;
    if (uid == null) return null;
    await expireStaleOpen();
    final rows = await _db
        .from(_table)
        .select()
        .eq('rider_id', uid)
        .inFilter('status', riderOngoingStatuses)
        .order('created_at', ascending: false)
        .limit(1);
    return rows.isEmpty ? null : RideRequest(rows.first);
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

  /// The admin's region list (`country-states-cities`) with each region's
  /// bidding switch. Empty when it cannot be read: bidding then stays on.
  Future<List<BiddingRegion>> biddingRegions() async {
    try {
      final rows = await _db.from('settings_entries').select('values').eq('category', 'country-states-cities');
      return [
        for (final r in rows)
          if (r['values'] is Map) BiddingRegion.fromValues(Map<String, dynamic>.from(r['values'] as Map)),
      ].whereType<BiddingRegion>().toList();
    } catch (_) {
      return const [];
    }
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
  Future<void> complete(RideRequest r, {TripCharges charges = TripCharges.none}) async {
    final patch = <String, dynamic>{
      'status': RideStatus.completed.db,
      'completed_at': DateTime.now().toUtc().toIso8601String(),
      ...charges.toPatch(),
    };
    try {
      await _db.from(_table).update(patch).eq('id', r.id);
    } on PostgrestException catch (e) {
      // Without migration 0100 there is no note column; the amounts (0047)
      // still go on the ride.
      if (!'${e.message} ${e.details}'.contains('other_charges_note')) rethrow;
      patch.remove('other_charges_note');
      await _db.from(_table).update(patch).eq('id', r.id);
    }
    final fare = r.effectiveFare ?? 0;
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
