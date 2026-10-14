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
import '../core/my_qr.dart' show QrBookingError, QrBookingFailure;
import '../core/my_ride.dart' show myRideMaxTargets;
import '../core/region_pricing.dart';
import '../core/format.dart' show setRegionCurrencySymbols;
import '../core/ride_bidding.dart';
import '../core/ride_payment.dart';
import '../core/ride_stops.dart';
import '../core/trip_charges.dart';
import '../core/trip_checkpoint.dart';
import '../core/ble_handshake.dart';
import '../core/trip_start.dart';
import 'geo_service.dart';
import 'models.dart';
import 'realtime_backup.dart';
import 'ride_cache.dart';
import 'scheduled_ride_repository.dart';
import '../core/ride_cache.dart';
import '../core/scheduled_rides.dart' show ScheduledRide;

/// What "Find a driver" made: a ride now, or a booking for later.
typedef Booked = ({RideRequest? now, ScheduledRide? later});

/// Ride booking + dispatch over `public.ride_requests`, mirroring the Expo
/// app's `utils/rideRequestsStore.ts`. Partners are identified by their auth
/// uid in `partner_id`, exactly as the Expo e-hailing screen does.
class RideRepository {
  RideRepository(this._db, {RideCacheStore? cache}) : _cache = cache ?? RideCacheStore();
  final SupabaseClient _db;

  /// The rides kept on the phone for when the server can't be reached.
  final RideCacheStore _cache;

  /// Admin → Reliability: whether the copy kept on the phone is shown when
  /// the server can't be reached.
  bool useOfflineCopy = true;
  static const _table = 'ride_requests';

  String? get _uid => _db.auth.currentUser?.id;

  /// Books a ride now, or with [scheduleAt] for later (migration 0189): the
  /// same row goes to `schedule_ride`, which keeps it until its release.
  Future<Booked> createRequest({
    DateTime? scheduleAt,
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
    double? autoAcceptFare,
    List<Place> stops = const [],
    Map<String, Object> metadata = const {},
    BookedFor? bookedFor,
    String currency = AppConfig.currency,
    RegionPricing pricing = RegionPricing.none,
    String? timezone,
    List<String> targetDriverIds = const [],
    double? myRideMaxKm,
    String? directQrToken,
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
      'auto_accept_fare': ?autoAcceptFare,
      // My Ride: the favourites to offer it to first. The server keeps only
      // the rider's own, not hidden ones and sets the window itself.
      if (targetDriverIds.isNotEmpty) 'target_driver_ids': targetDriverIds.take(myRideMaxTargets).toList(),
      if (targetDriverIds.isNotEmpty && myRideMaxKm != null && myRideMaxKm > 0) 'my_ride_max_km': myRideMaxKm,
      // GET.now (0161): the scanned code books that driver alone. The server
      // checks it and refuses the request (QR_EXPIRED &co.) rather than
      // sending it to anybody else; favourites sent with it are dropped.
      if (directQrToken != null && directQrToken.trim().isNotEmpty) 'direct_qr_token': directQrToken.trim(),
    };
    // Stops, the metadata, the region's pricing and its time zone are
    // extras: a database without one of their columns (stops needs 0098,
    // pricing 0119, the zone 0124) books the ride without it rather than
    // failing.
    // auto_accept_fare needs 0141; without it the rider's phone still takes
    // a matching offer while the searching screen is open. My Ride's
    // columns need 0160; without them the ride goes to everybody nearby.
    final optional = {
      'stops',
      ...metadata.keys,
      ...RegionPricing.none.toRideColumns().keys,
      'timezone',
      'auto_accept_fare',
      'target_driver_ids',
      'my_ride_max_km',
    };
    if (scheduleAt != null) {
      // Favourites and a scanned driver are for a ride now; the server
      // drops them from a booking anyway.
      for (final k in ['target_driver_ids', 'my_ride_max_km', 'direct_qr_token', 'auto_accept_fare']) {
        row.remove(k);
      }
      return (now: null, later: await ScheduledRideRepository(_db).schedule(row, scheduleAt));
    }
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
        // A GET.now code that has expired, is the rider's own, or whose
        // driver can't take rides: nothing was stored.
        final qr = QrBookingError.parse(e.message);
        if (qr != null) throw qr;
        // Never quietly book someone else's ride as the rider's own.
        if (bookedFor != null && e.message.contains('booked_for')) {
          throw StateError("Booking for someone else isn't available yet. Please try again later.");
        }
        // Never quietly turn a direct booking into one for everybody: a
        // database without 0161 can't book by code.
        if (row.containsKey('direct_qr_token') &&
            missingColumn('${e.message} ${e.details}') == 'direct_qr_token') {
          throw const QrBookingError(QrBookingFailure.notAvailable);
        }
        final col = droppableRideColumn('${e.message} ${e.details}', optional, row.keys);
        if (attempt >= optional.length || col == null) rethrow;
        row.remove(col);
      }
    }
    // Online partners are pushed by the database (the ride_requests insert
    // trigger); send-push no longer takes a rider's call.
    return (now: RideRequest(await _readAside(data)), later: null);
  }

  /// The rider's own open requests: while one is open the passenger's
  /// details wait in `ride_request_private`, which only the rider reads
  /// (migration 0195). Kept per request for this session.
  final Map<String, Map<String, dynamic>> _aside = {};

  Map<String, dynamic> _withAside(Map<String, dynamic> row) {
    final aside = _aside['${row['id']}'];
    if (aside == null || aside.isEmpty || row['status'] != 'open') return row;
    return {
      ...row,
      for (final e in aside.entries)
        if (e.value != null && e.key != 'request_id' && e.key != 'updated_at') e.key: e.value,
    };
  }

  Future<Map<String, dynamic>> _readAside(Map<String, dynamic> row) async {
    final uid = _uid;
    if (uid == null || row['status'] != 'open' || row['rider_id'] != uid) return row;
    final id = '${row['id']}';
    if (!_aside.containsKey(id)) {
      try {
        _aside[id] = await _db.from('ride_request_private').select().eq('request_id', id).maybeSingle() ?? const {};
      } catch (_) {
        // A database before 0195 keeps everything on the row.
        _aside[id] = const {};
      }
    }
    return _withAside(row);
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
    try {
      await expireStaleOpen();
      final rows = await _db
          .from(_table)
          .select()
          .eq('rider_id', uid)
          .inFilter('status', riderOngoingStatuses)
          .order('created_at', ascending: false)
          .limit(20);
      final merged = await Future.wait(rows.map(_readAside));
      for (final row in merged) {
        unawaited(_cache.save(row));
      }
      return merged.map(RideRequest.new).toList();
    } on PostgrestException {
      rethrow;
    } catch (_) {
      // No connection: the rides on the go as this phone last saw them.
      final kept = await _keptInProgress(uid, 'rider_id', riderOngoingStatuses);
      if (kept == null) rethrow;
      return kept;
    }
  }

  /// The rides in progress kept on the phone, or null when there are none.
  Future<List<RideRequest>?> _keptInProgress(String uid, String column, List<String> statuses) async {
    if (!useOfflineCopy) return null;
    final kept = cachedRidesInProgress(await _cache.read(), uid: uid, column: column, statuses: statuses);
    if (kept.isEmpty) return null;
    return [for (final c in kept) RideRequest(c.row, cachedAt: c.savedAt)];
  }

  Future<RideRequest?> ongoingForPartner() async {
    final uid = _uid;
    if (uid == null) return null;
    try {
      final rows = await _db
          .from(_table)
          .select()
          .eq('partner_id', uid)
          .inFilter('status', partnerOngoingStatuses)
          .order('created_at', ascending: false)
          .limit(1);
      if (rows.isEmpty) return null;
      unawaited(_cache.save(rows.first));
      return RideRequest(rows.first);
    } on PostgrestException {
      rethrow;
    } catch (_) {
      // No connection: the trip as this phone last saw it.
      final kept = await _keptInProgress(uid, 'partner_id', partnerOngoingStatuses);
      if (kept == null) rethrow;
      return kept.first;
    }
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

  /// The trips this driver completed since [since], newest first, for the
  /// Earnings page (core/driver_earnings.dart). Read a page at a time: the
  /// API answers at most 1,000 rows a request, and a busy driver's eight
  /// weeks can be more. [maxRows] stops a runaway read.
  Future<List<RideRequest>> completedAsDriver(DateTime since, {int pageSize = 1000, int maxRows = 5000}) async {
    final uid = _uid;
    if (uid == null) return [];
    final out = <RideRequest>[];
    while (out.length < maxRows) {
      final rows = await _db
          .from(_table)
          .select()
          .eq('partner_id', uid)
          .eq('status', 'completed')
          .gte('completed_at', since.toUtc().toIso8601String())
          .order('completed_at', ascending: false)
          .order('id')
          .range(out.length, out.length + pageSize - 1);
      out.addAll(rows.map(RideRequest.new));
      if (rows.length < pageSize) break;
    }
    return out;
  }

  Future<RideRequest?> fetch(String id) async {
    final row = await _db.from(_table).select().eq('id', id).maybeSingle();
    return row == null ? null : RideRequest(await _readAside(row));
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
  /// bidding switch, pricing and services, as seen from [at]. Old
  /// `country-states-cities` settings entries are read too.
  ///
  /// The server tests the mapped boundaries against [at] (`regions_at`,
  /// migration 0169), so only the answer comes down -- the boundaries are
  /// megabytes, and reading them on every check timed out, which silently
  /// lost the region's pricing (whole fares, tax) and bidding switch. A list
  /// read for one point is only asked about that point; without [at] the
  /// boundaries are left out (names only). Against a database without 0169
  /// the tables are read whole, as before.
  ///
  /// Kept for [regionsCacheFor] per point; an admin's change drops them at
  /// once ([forgetRegions], wired to the live region tables in
  /// `providers.dart`). A read that failed is kept for [regionsRetryAfter]
  /// rather than retried on the next check, so a struggling database is not
  /// asked again every few seconds.
  Future<List<BiddingRegion>> biddingRegions({LatLng? at}) {
    final key = at == null ? 'names' : regionLookupKey(at);
    final cached = _regions[key];
    final now = DateTime.now();
    if (cached != null && now.isBefore(cached.until)) return cached.list;
    var failed = false;
    final list = _lookupRegions(at, () => failed = true);
    final kept = (until: now.add(regionsCacheFor), list: list);
    if (_regions.length >= 16) _regions.remove(_regions.keys.first);
    _regions[key] = kept;
    unawaited(list.then((_) {
      if (failed && identical(_regions[key], kept)) {
        _regions[key] = (until: DateTime.now().add(regionsRetryAfter), list: list);
      }
    }));
    return list;
  }

  /// Drops the kept regions, so the next check reads the admin's change.
  void forgetRegions() {
    _regions.clear();
    _wholeRegions = null;
  }

  static const regionsCacheFor = Duration(minutes: 10);
  static const regionsRetryAfter = Duration(seconds: 45);
  final Map<String, ({DateTime until, Future<List<BiddingRegion>> list})> _regions = {};

  /// Whether `regions_at` exists; false after the database said it does
  /// not (before migration 0169), so the whole tables are read instead.
  bool _lookupAvailable = true;

  /// The whole-table read (no 0169), shared by every point: its rings test
  /// any point.
  Future<List<BiddingRegion>>? _wholeRegions;

  Future<List<BiddingRegion>> _lookupRegions(LatLng? at, void Function() onFailed) async {
    if (_lookupAvailable) {
      try {
        final rows = await _db.rpc(
          'regions_at',
          params: {'p_lat': at?.latitude, 'p_lng': at?.longitude},
        );
        final regions = [
          if (rows is List)
            for (final r in rows)
              if (r is Map) ?regionFromLookupRow(Map<String, dynamic>.from(r)),
          ...await _legacyRegions(onFailed),
        ];
        setRegionCurrencySymbols(regionCurrencySymbols(regions));
        return regions;
      } on PostgrestException catch (e) {
        if (e.code != 'PGRST202' && e.code != '42883') {
          onFailed();
          return const [];
        }
        _lookupAvailable = false;
      } catch (_) {
        onFailed();
        return const [];
      }
    }
    var whole = _wholeRegions;
    if (whole == null) {
      var failed = false;
      final read = whole = _readRegions(() => failed = true);
      _wholeRegions = read;
      final regions = await read;
      if (failed) {
        if (identical(_wholeRegions, read)) _wholeRegions = null;
        onFailed();
      }
      return regions;
    }
    return whole;
  }

  Future<List<BiddingRegion>> _legacyRegions(void Function() onFailed) async {
    try {
      final rows = await _db.from('settings_entries').select('values').eq('category', 'country-states-cities');
      return [
        for (final r in rows)
          if (r['values'] is Map) ?BiddingRegion.fromValues(Map<String, dynamic>.from(r['values'] as Map)),
      ];
    } catch (_) {
      onFailed();
      return const [];
    }
  }

  Future<List<BiddingRegion>> _readRegions(void Function() onFailed) async {
    Future<List<BiddingRegion>> table(String t, String select) async {
      try {
        final rows = await _db.from(t).select(select);
        return [for (final r in rows) ?BiddingRegion.fromRegionRow(t, Map<String, dynamic>.from(r))];
      } catch (_) {
        onFailed();
        return const [];
      }
    }

    final parts = await Future.wait([
      for (final e in regionTableSelects.entries) table(e.key, e.value),
      _legacyRegions(onFailed),
    ]);
    final regions = [for (final p in parts) ...p];
    // Amounts in a region's currency print with the symbol it gives it.
    setRegionCurrencySymbols(regionCurrencySymbols(regions));
    return regions;
  }

  /// The `service-settings` ids switched on for [pickup]'s region; null when
  /// no region restricts them.
  Future<Set<String>?> servicesFor(LatLng pickup, Future<AreaInfo?> Function() area) async {
    final regions = await biddingRegions(at: pickup);
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
    final regions = await biddingRegions(at: point);
    if (regions.isEmpty) return null;
    AreaInfo? names;
    try {
      names = await area().timeout(const Duration(seconds: 5));
    } catch (_) {}
    return coverageGap(regions, point, area: names);
  }

  Future<RegionRuleContext> ruleContextFor(LatLng pickup, Future<AreaInfo?> Function() area) async {
    final regions = await biddingRegions(at: pickup);
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
    final regions = await biddingRegions(at: pickup);
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
    final regions = await biddingRegions(at: pickup);
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

  /// The rider's "Auto-accept offer of RM x" on their open request: an
  /// offer at or under [limit] is taken by the database the moment it
  /// lands (migration 0141); null switches it off.
  Future<void> setAutoAccept(String id, double? limit) async {
    final uid = _uid;
    if (uid == null) return;
    await _db.from(_table).update({'auto_accept_fare': limit}).eq('id', id).eq('rider_id', uid).eq('status', 'open');
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
    // The database's trigger tells partners the fare went up.
    return RideRequest(row);
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

  /// "Pay now" for a completed ride (`ride_pay`, migration 0142): the
  /// server works out what is left to pay, takes it from the rider's
  /// GET.wallet or GET.coin and credits the driver, once. Throws when it is
  /// refused (`insufficient_balance` and the like; see ridePaymentFailure).
  ///
  /// [expected] is the amount the passenger was shown: the server takes the
  /// money only if that is still what is left to pay (`amount_changed`
  /// otherwise, migration 0174). A database without 0174 is paid as before.
  Future<void> payRide(String id, RidePayMethod method, {double? expected}) async {
    if (method == RidePayMethod.cash) return payRideCash(id);
    final params = {'p_ride': id, 'p_method': method.db};
    if (expected == null) {
      await _db.rpc('ride_pay', params: params);
      return;
    }
    try {
      await _db.rpc('ride_pay', params: {...params, 'p_expected': double.parse(expected.toStringAsFixed(2))});
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202') rethrow;
      await _db.rpc('ride_pay', params: params);
    }
  }

  /// "Paid in cash": the ride waits for the driver to confirm it.
  Future<void> payRideCash(String id) async {
    await _db.rpc('ride_pay_cash', params: {'p_ride': id});
  }

  /// The driver confirms the passenger's cash was received.
  Future<void> confirmRideCash(String id) async {
    await _db.rpc('ride_confirm_cash', params: {'p_ride': id});
  }

  /// The driver starts the trip with the passenger's code; the server checks
  /// it (`start_trip`, migration 0152). On a database without it, the trip
  /// starts as it used to.
  Future<TripStartOutcome> startTrip(String id, String code) async {
    try {
      return tripStartOutcome(await _db.rpc('start_trip', params: {'p_request': id, 'p_code': code}));
    } on PostgrestException catch (e) {
      // Only "no such function" falls back; a refusal stays a refusal.
      if (e.code != 'PGRST202' && e.code != '42883') rethrow;
      await updateStatus(id, RideStatus.onTrip);
      return const TripStarted();
    }
  }

  /// This side's Bluetooth token and the other side's (get_trip_ble_token,
  /// 0153); switched off on a database without it.
  Future<BleTicket> bleTicket(String id) async {
    try {
      return BleTicket.fromJson(await _db.rpc('get_trip_ble_token', params: {'p_request': id}));
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202' && e.code != '42883') rethrow;
      return const BleTicket(enabled: false);
    }
  }

  /// Reports the other side's token this phone saw (ble_handshake_proof).
  Future<BleProofResult> bleProof(
    String id, {
    required String seenToken,
    required int rssi,
    required Duration seenFor,
    double? lat,
    double? lng,
  }) async {
    try {
      return bleProofResult(
        await _db.rpc(
          'ble_handshake_proof',
          params: {
            'p_request': id,
            'p_seen_token': seenToken,
            'p_rssi': rssi,
            'p_seen_ms': seenFor.inMilliseconds,
            'p_lat': lat,
            'p_lng': lng,
          },
        ),
      );
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202' && e.code != '42883') rethrow;
      return BleProofResult.off;
    }
  }

  /// The ride's trip code, for its rider (`ride_trip_codes`, 0152); null for
  /// anyone else, or on a database without the table.
  Future<String?> tripCode(String id) async {
    try {
      final row = await _db.from('ride_trip_codes').select('code').eq('request_id', id).maybeSingle();
      return row?['code'] as String?;
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
    RealtimeBackup? backup;
    RideStatus? shown;
    // The trip is on screen in the state it is in: the pushes about it
    // (migration 0144) needn't be sent again.
    void emit(RideRequest r) {
      if (controller.isClosed) return;
      controller.add(r);
      if (r.fromCache) return;
      unawaited(_cache.save(r.raw));
      if (r.status != shown) {
        shown = r.status;
        unawaited(ackRideNotifications(id));
      }
    }

    // Realtime does not replay what changed while the phone held the app
    // suspended, and can drop an update: the backup reads the row again.
    Future<void> reread() async {
      try {
        final r = await fetch(id);
        if (r != null) emit(r);
      } catch (_) {}
    }

    controller.onListen = () async {
      backup = RealtimeBackup(reread);
      try {
        final first = await fetch(id);
        if (first != null) emit(first);
      } catch (e) {
        // No connection: the ride as this phone last saw it, until the
        // backup reads it again. Without one, the screen offers a retry.
        final kept = e is PostgrestException || !useOfflineCopy ? null : await _cache.ride(id);
        if (kept != null) {
          emit(RideRequest(kept.row, cachedAt: kept.savedAt));
        } else if (!controller.isClosed) {
          controller.addError(e);
        }
      }
      if (controller.isClosed) return;
      channel = _db
          .channel('ride_request_${id}_${DateTime.now().microsecondsSinceEpoch}')
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: _table,
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: id),
            callback: (p) {
              if (p.newRecord.isNotEmpty) emit(RideRequest(_withAside(p.newRecord)));
            },
          )
          .subscribe(backup!.onStatus);
    };
    controller.onCancel = () async {
      backup?.dispose();
      if (channel != null) await _db.removeChannel(channel!);
      await controller.close();
    };
    return controller.stream;
  }

  /// The caller has [requestId] on screen: its queued pushes are delivered
  /// (`ack_ride_notifications`, 0144). Quiet when the database predates it.
  Future<void> ackRideNotifications(String requestId) async {
    if (_uid == null) return;
    try {
      await _db.rpc('ack_ride_notifications', params: {'p_request': requestId});
    } catch (_) {}
  }

  /// Live partner queue: emits the full open list whenever anything changes.
  Stream<List<RideRequest>> watchOpen() {
    final controller = StreamController<List<RideRequest>>();
    RealtimeChannel? channel;
    Future<void> refresh() async {
      try {
        final list = await openRequests();
        if (!controller.isClosed) controller.add(list);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      }
    }

    RealtimeBackup? backup;
    controller.onListen = () {
      refresh();
      // Back from the background, or an update dropped: the queue as it is
      // now, not as it was (and requests drop off as they age past expiry).
      backup = RealtimeBackup(refresh, every: const Duration(seconds: 10));
      channel = _db
          .channel('ride_requests_open_${DateTime.now().microsecondsSinceEpoch}')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: _table,
            callback: (_) => refresh(),
          )
          .subscribe(backup!.onStatus);
    };
    controller.onCancel = () async {
      backup?.dispose();
      if (channel != null) await _db.removeChannel(channel!);
      await controller.close();
    };
    return controller.stream;
  }
}
