import 'dart:async';
import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../core/commission.dart';
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
      'offer_me': false,
      'otp': otp,
      'device_os': deviceOs,
      'user_accept_lat': pickupLat,
      'user_accept_lng': pickupLng,
      'status': 'open',
    };
    final data = await _db.from(_table).insert(row).select().single();
    final req = RideRequest(data);
    unawaited(_notifyPartners(req));
    return req;
  }

  /// Best-effort push to online partners through the shared `send-push` edge
  /// function (same payload as the Expo app).
  Future<void> _notifyPartners(RideRequest r) async {
    try {
      await _db.functions.invoke('send-push', body: {
        'title': 'New Request',
        'body': '${r.currency} ${r.fare?.round() ?? ''} , ${r.pickupLabel} -> ${r.dropLabel}',
        'audience': 'partners',
        'data': {'type': 'new_ride_request', 'requestId': r.id},
      });
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
        })
        .eq('id', id)
        .eq('status', 'open')
        .select()
        .maybeSingle();
    return row == null ? null : RideRequest(row);
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
      await _db.from(_table).update({
        'status': 'cancelled',
        'cancelled_at': DateTime.now().toUtc().toIso8601String(),
        'cancel_reason': reason,
      }).eq('id', r.id);
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

  Future<void> declineCancellation(String id) => _db
      .from(_table)
      .update({'cancel_requested_at': null, 'cancel_requested_by': null}).eq('id', id);

  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) =>
      _db.from(_table).update({
        'partner_live_lat': lat,
        'partner_live_lng': lng,
        'partner_live_heading': heading,
        'partner_live_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', id);

  Future<void> publishRiderLocation(String id, double lat, double lng) =>
      _db.from(_table).update({
        'user_live_lat': lat,
        'user_live_lng': lng,
        'user_live_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', id);

  /// Completes the trip and charges the partner's commission through the
  /// shared `wallet_charge_ride_commission` RPC (idempotent per ride).
  Future<void> complete(RideRequest r) async {
    await updateStatus(r.id, RideStatus.completed);
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
      await _db.rpc('wallet_charge_ride_commission', params: {
        'p_ride': r.id,
        'p_partner': uid,
        'p_fare': fare,
        'p_rate': rate,
      });
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
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'id',
              value: id,
            ),
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
