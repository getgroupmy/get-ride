// City to City (migration 0306): the settings, permits by country and route
// rules the admin keeps, and commission per service. The apps read the
// same rows (everyone signed in reads them); admins with EDIT write.
// Bookings (0307): the rider's quote, request, offers and booking.
// Money and reminders (0309): the give-up and in-app payment rules by
// region, paying in the app, fees owed.
// Per-seat trips (0310): the seat rules, posting a trip, searching and
// booking seats, the driver's requests, passengers, start and finish.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/booking_modules.dart' show familyModuleSeatTrip;
import '../core/city_to_city.dart';
import '../core/city_to_city_seats.dart';
import '../core/commission.dart' show Geo;
import '../core/family.dart' show FamilyPassenger, FamilyPick, familyBookingColumns;
import '../core/fare.dart' show ServiceRates;
import '../core/fare_tariff.dart';
import '../providers.dart';
import 'family_repository.dart' show familyPassengersProvider;
import 'live_tables.dart';

/// A permit type an admin can ask for (permit_types, 0254).
typedef C2cPermitType = ({String id, String name, String country, String appliesTo});

/// The City to City Vehicle Service: its entry id, its master services
/// (ids) and its own rates, for the fare card.
typedef C2cService = ({String? id, Set<String> types, ServiceRates? rates, bool active});

class CityToCityRepository {
  CityToCityRepository(this._db);
  final SupabaseClient _db;

  Future<C2cSettings> settings() async =>
      C2cSettings.fromRow(await _db.from('city_to_city_settings').select().eq('id', 1).maybeSingle());

  Future<void> saveSettings(C2cSettings s) => _db.from('city_to_city_settings').update(s.toRow()).eq('id', 1);

  Future<List<C2cRule>> rules() async {
    final rows = await _db
        .from('c2c_route_rules')
        .select()
        .order('position', ascending: true)
        .order('created_at', ascending: true);
    return [for (final r in rows) C2cRule.fromRow(r)];
  }

  /// Adds [r] (no id) at the end of the list, or changes it.
  Future<void> saveRule(C2cRule r) async {
    final row = r.toRow();
    if (r.id == null) {
      await _db.from('c2c_route_rules').insert(row);
    } else {
      await _db.from('c2c_route_rules').update(row).eq('id', r.id!);
    }
  }

  Future<void> setRuleActive(String id, bool on) => _db.from('c2c_route_rules').update({'active': on}).eq('id', id);

  Future<void> deleteRule(String id) => _db.from('c2c_route_rules').delete().eq('id', id);

  Future<List<C2cCountryPermit>> countryPermits() async {
    final rows = await _db
        .from('c2c_country_permits')
        .select('id, country, permit_type_id, applies_to, position, permit_types(name)')
        .order('country', ascending: true)
        .order('position', ascending: true);
    return [for (final r in rows) C2cCountryPermit.fromRow(r)];
  }

  Future<void> addCountryPermit(String country, String permitTypeId, {int position = 0}) => _db
      .from('c2c_country_permits')
      .insert({'country': country.trim(), 'permit_type_id': permitTypeId, 'position': position});

  Future<void> removeCountryPermit(String id) => _db.from('c2c_country_permits').delete().eq('id', id);

  Future<List<C2cPermitType>> permitTypes() async {
    final rows = await _db
        .from('permit_types')
        .select('id, name, country, applies_to')
        .eq('active', true)
        .order('country', ascending: true)
        .order('position', ascending: true);
    return [
      for (final r in rows)
        (
          id: '${r['id']}',
          name: '${r['name'] ?? ''}',
          country: '${r['country'] ?? ''}',
          appliesTo: r['applies_to'] == 'driver' ? 'driver' : 'vehicle',
        ),
    ];
  }

  /// The service's own rate per Vehicle Service id.
  Future<Map<String, double>> serviceRates() async {
    final rows = await _db.from('commission_service_rates').select('service_id, rate, active');
    return {
      for (final r in rows)
        if (r['active'] != false && r['rate'] is num) '${r['service_id']}': (r['rate'] as num).toDouble(),
    };
  }

  /// Sets service [id]'s own rate (a fraction), or back to the place rate (null).
  Future<void> setServiceRate(String id, String name, double? rate) async {
    if (rate == null) {
      await _db.from('commission_service_rates').delete().eq('service_id', id);
    } else {
      await _db
          .from('commission_service_rates')
          .upsert({'service_id': id, 'service_name': name, 'rate': rate, 'active': true}, onConflict: 'service_id');
    }
  }

  Future<List<FareTariff>> fareCards() async {
    final rows = await _db.from('fare_tariffs').select().eq('active', true).order('level', ascending: true);
    return [for (final r in rows) FareTariff.fromRow(r)];
  }

  Future<C2cService> service() async {
    final rows = await _db
        .from('settings_entries')
        .select('id, category, values')
        .inFilter('category', ['vehicle-services', 'service-settings'])
        .order('position', ascending: true);
    Map<String, dynamic> values(Map r) => Map<String, dynamic>.from((r['values'] as Map?) ?? const {});
    final mine = rows
        .where((r) => r['category'] == 'vehicle-services' && '${values(r)['name'] ?? ''}'.trim() == c2cServiceName)
        .firstOrNull;
    if (mine == null) return (id: null, types: const <String>{}, rates: null, active: false);
    final v = values(mine);
    final typeNames = {
      for (final t in v['serviceTypes'] is List ? v['serviceTypes'] as List : const []) '$t'.trim().toLowerCase(),
    };
    final status = '${v['status'] ?? true}'.toLowerCase();
    return (
      id: '${mine['id']}',
      types: {
        for (final r in rows)
          if (r['category'] == 'service-settings' && typeNames.contains('${values(r)['name'] ?? ''}'.trim().toLowerCase()))
            '${r['id']}',
      },
      rates: ServiceRates.fromValues(v),
      active: !const {'false', '0', 'off', 'inactive'}.contains(status),
    );
  }

  // ---- Bookings (0307) ----------------------------------------------------------------------------

  Map<String, dynamic> _geo(Geo g) => {'country': ?g.country, 'state': ?g.state, 'city': ?g.city, 'suburb': ?g.suburb};

  /// Whether City to City is on at [place] (0306's c2c_available_at).
  Future<bool> availableAt(Geo place) async =>
      await _db.rpc('c2c_available_at', params: {'p_place': _geo(place)}) == true;

  /// The quote for a whole-car trip from [pickup] (at [lat], [lng]) to
  /// [drop], [km] km and [min] minutes (0306's c2c_quote).
  Future<C2cQuote> quote({
    required double lat,
    required double lng,
    required Geo pickup,
    required Geo drop,
    required double km,
    required double min,
  }) async {
    final r = await _db.rpc('c2c_quote', params: {
      'p_lat': lat,
      'p_lng': lng,
      'p_pickup': _geo(pickup),
      'p_drop': _geo(drop),
      'p_km': km,
      'p_min': min,
    });
    return c2cQuoteFromJson(Map<String, dynamic>.from(r as Map));
  }

  /// Sends the request ([c2cBookingRow]); the server checks it (0307).
  Future<C2cBooking> book(Map<String, dynamic> row) async =>
      C2cBooking.fromRow(await _db.from('c2c_bookings').insert(row).select().single());

  /// The signed-in rider's trips, newest first.
  Future<List<C2cBooking>> myTrips() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return const [];
    final rows = await _db
        .from('c2c_bookings')
        .select()
        .eq('rider_id', uid)
        .order('created_at', ascending: false)
        .limit(50);
    return [for (final r in rows) C2cBooking.fromRow(r)];
  }

  Future<C2cBooking?> booking(String id) async {
    final r = await _db.from('c2c_bookings').select().eq('id', id).maybeSingle();
    return r == null ? null : C2cBooking.fromRow(r);
  }

  /// The offers on request [bookingId], oldest first.
  Future<List<C2cOffer>> offers(String bookingId) async {
    final rows = await _db
        .from('c2c_offers')
        .select()
        .eq('booking_id', bookingId)
        .order('created_at', ascending: true);
    return [for (final r in rows) C2cOffer.fromRow(r)];
  }

  Future<void> acceptOffer(String offerId) => _db.rpc('c2c_accept_offer', params: {'p_offer': offerId});

  Future<void> declineOffer(String offerId) => _db.rpc('c2c_decline_offer', params: {'p_offer': offerId});

  /// A new fare for a request with no driver yet, within its range.
  Future<void> setFare(String bookingId, double fare) =>
      _db.rpc('c2c_set_fare', params: {'p_booking': bookingId, 'p_fare': fare});

  /// Cancels [bookingId]; the fee taken (0 for none) and whether it was
  /// charged or is due.
  Future<({double fee, String feeStatus})> cancel(String bookingId, {String? reason}) async {
    final r = await _db.rpc('c2c_cancel', params: {'p_booking': bookingId, 'p_reason': reason});
    final m = r is Map ? r : const {};
    final fee = m['fee'];
    return (fee: fee is num ? fee.toDouble() : 0.0, feeStatus: '${m['feeStatus'] ?? 'none'}');
  }

  /// The driver's name and phone once booked; null before or after.
  Future<({String name, String? phone})?> contact(String bookingId) async {
    final r = await _db.rpc('c2c_contact', params: {'p_booking': bookingId});
    if (r is! Map) return null;
    final phone = '${r['phone'] ?? ''}'.trim();
    return (name: '${r['name'] ?? 'Your driver'}', phone: phone.isEmpty ? null : phone);
  }

  Future<void> rateDriver(String bookingId, int stars, {String? comment}) => _db.rpc(
    'c2c_rate_driver',
    params: {'p_booking': bookingId, 'p_stars': stars, 'p_comment': comment},
  );

  // ---- The driver (0308) --------------------------------------------------------------------------

  /// The open requests in reach, with what the page's header needs.
  Future<C2cDriverFeed> driverFeed() async => C2cDriverFeed.fromJson(await _db.rpc('c2c_driver_requests'));

  /// The trips the signed-in driver is booked on, latest leave first.
  Future<List<C2cBooking>> driverTrips() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return const [];
    final rows = await _db
        .from('c2c_bookings')
        .select()
        .eq('driver_id', uid)
        .order('leave_at', ascending: false)
        .limit(60);
    return [for (final r in rows) C2cBooking.fromRow(r)];
  }

  /// Offers [price] on request [bookingId], leaving at [leaveAt] (the
  /// rider's time when null); offering again changes the open offer.
  Future<void> makeOffer(String bookingId, double price, {DateTime? leaveAt}) => _db.rpc('c2c_make_offer', params: {
    'p_booking': bookingId,
    'p_price': c2cRound2(price),
    'p_leave_at': leaveAt?.toUtc().toIso8601String(),
  });

  Future<void> withdrawOffer(String offerId) => _db.rpc('c2c_withdraw_offer', params: {'p_offer': offerId});

  /// Moves the booked trip on: driver_arriving, on_trip, completed.
  Future<void> driverProgress(String bookingId, C2cStatus to) =>
      _db.rpc('c2c_driver_progress', params: {'p_booking': bookingId, 'p_status': to.key});

  /// Gives a booked trip up; it goes back to open for other drivers.
  Future<void> driverCancel(String bookingId, {String? reason}) =>
      _db.rpc('c2c_driver_cancel', params: {'p_booking': bookingId, 'p_reason': reason});

  // ---- Money (0309) ---------------------------------------------------------------------------------

  Future<List<C2cGiveUpRule>> giveUpRules() async {
    final rows = await _db.from('c2c_giveup_rules').select().order('created_at', ascending: true);
    return [for (final r in rows) C2cGiveUpRule.fromRow(r)];
  }

  /// Adds [r] (no id) or changes it.
  Future<void> saveGiveUpRule(C2cGiveUpRule r) async {
    if (r.id == null) {
      await _db.from('c2c_giveup_rules').insert(r.toRow());
    } else {
      await _db.from('c2c_giveup_rules').update(r.toRow()).eq('id', r.id!);
    }
  }

  Future<void> deleteGiveUpRule(String id) => _db.from('c2c_giveup_rules').delete().eq('id', id);

  Future<List<C2cPayRule>> payRules() async {
    final rows = await _db.from('c2c_pay_rules').select().order('created_at', ascending: true);
    return [for (final r in rows) C2cPayRule.fromRow(r)];
  }

  Future<void> savePayRule(C2cPayRule r) async {
    if (r.id == null) {
      await _db.from('c2c_pay_rules').insert(r.toRow());
    } else {
      await _db.from('c2c_pay_rules').update(r.toRow()).eq('id', r.id!);
    }
  }

  Future<void> deletePayRule(String id) => _db.from('c2c_pay_rules').delete().eq('id', id);

  /// What the pay sheet for [bookingId] needs.
  Future<C2cPayInfo> payInfo(String bookingId) async =>
      C2cPayInfo.fromJson(await _db.rpc('c2c_pay_info', params: {'p_booking': bookingId}));

  /// Accepts [offerId], paying the way [way] (In app, held) the [expected]
  /// total the rider saw.
  Future<void> acceptOfferPay(String offerId, {C2cPayWay? way, double? expected}) => _db.rpc(
    'c2c_accept_offer_pay',
    params: {'p_offer': offerId, 'p_method': way?.key, 'p_expected': expected == null ? null : c2cRound2(expected)},
  );

  /// Pays completed trip [bookingId] (In app, after the trip).
  Future<void> pay(String bookingId, C2cPayWay way, double expected) => _db.rpc(
    'c2c_pay',
    params: {'p_booking': bookingId, 'p_method': way.key, 'p_expected': c2cRound2(expected)},
  );

  /// The rider pays [bookingId] in cash instead.
  Future<void> switchToCash(String bookingId) => _db.rpc('c2c_switch_to_cash', params: {'p_booking': bookingId});

  /// What the signed-in account owes City to City.
  Future<C2cOwed> myOwed() async => C2cOwed.fromJson(await _db.rpc('c2c_my_owed'));

  /// Pay now: from the GET wallet as far as it goes; how much was paid.
  Future<double> payOwed() async {
    final r = await _db.rpc('c2c_pay_owed');
    final paid = r is Map ? r['paid'] : null;
    return paid is num ? paid.toDouble() : 0;
  }

  /// The cash trip's driver collected the fees the rider owed; how much.
  Future<double> markCollected(String bookingId) async {
    final r = await _db.rpc('c2c_mark_collected', params: {'p_booking': bookingId});
    final v = r is Map ? r['collected'] : null;
    return v is num ? v.toDouble() : 0;
  }

  /// When the driver's licence was first issued, once.
  Future<void> setDrivingSince(DateTime since) => _db.rpc('c2c_set_driving_since', params: {
    'p_since': '${since.year.toString().padLeft(4, '0')}-${since.month.toString().padLeft(2, '0')}-'
        '${since.day.toString().padLeft(2, '0')}',
  });
  // ---- Per-seat trips (0310) ------------------------------------------------------------------------

  Future<List<C2cSeatRule>> seatRules() async {
    final rows = await _db.from('c2c_seat_rules').select().order('created_at', ascending: true);
    return [for (final r in rows) C2cSeatRule.fromRow(r)];
  }

  /// Adds [r] (no id) or changes it.
  Future<void> saveSeatRule(C2cSeatRule r) async {
    if (r.id == null) {
      await _db.from('c2c_seat_rules').insert(r.toRow());
    } else {
      await _db.from('c2c_seat_rules').update(r.toRow()).eq('id', r.id!);
    }
  }

  Future<void> deleteSeatRule(String id) => _db.from('c2c_seat_rules').delete().eq('id', id);

  /// What the post screen needs for a trip from [from] to [to].
  Future<C2cPostTerms> postTerms({required C2cEnd from, required C2cEnd to, required double km, required double min}) async =>
      C2cPostTerms.fromJson(await _db.rpc('c2c_post_terms', params: {
        'p_lat': from.lat,
        'p_lng': from.lng,
        'p_from': from.placeJson,
        'p_to': to.placeJson,
        'p_km': km,
        'p_min': min,
      }));

  /// Posts a trip (and its repeats); the trips made and the repeats skipped.
  Future<({List<String> ids, int posted, int skipped})> postTrip({
    required C2cEnd from,
    required C2cEnd to,
    required double km,
    required double min,
    required DateTime leaveAt,
    required List<C2cMeetingPoint> points,
    required int seats,
    required double seatPrice,
    C2cJoinMode? join,
    bool womenOnly = false,
    bool door = false,
    int parcelSlots = 0,
    C2cParcelSize? parcelSize,
    double? parcelPrice,
    C2cRepeat repeat = C2cRepeat.none,
    DateTime? repeatUntil,
    bool suitcase = false,
    String? note,
    String? timezone,
  }) async {
    Map<String, dynamic> end(C2cEnd e) => {'name': e.name, 'address': ?e.address, 'lat': e.lat, 'lng': e.lng, 'place': e.placeJson};
    final r = await _db.rpc('c2c_post_trip', params: {
      'p_from': end(from),
      'p_to': end(to),
      'p_km': double.parse(km.toStringAsFixed(2)),
      'p_min': double.parse(min.toStringAsFixed(1)),
      'p_leave_at': leaveAt.toUtc().toIso8601String(),
      'p_meeting_points': [for (final p in points) p.toJson()],
      'p_seats': seats,
      'p_seat_price': c2cRound2(seatPrice),
      'p_join': join?.key,
      'p_women_only': womenOnly,
      'p_door': door,
      'p_parcel_slots': parcelSlots,
      'p_parcel_size': parcelSize?.key,
      'p_parcel_price': parcelPrice,
      'p_repeat': repeat == C2cRepeat.none ? null : repeat.key,
      'p_repeat_until': repeatUntil == null ? null : _day(repeatUntil),
      'p_luggage': suitcase ? 'suitcase' : 'small',
      'p_note': note,
      'p_timezone': timezone,
    });
    final m = r is Map ? r : const {};
    return (
      ids: [for (final e in m['ids'] is List ? m['ids'] as List : const []) '$e'],
      posted: (m['posted'] as num?)?.round() ?? 0,
      skipped: (m['skipped'] as num?)?.round() ?? 0,
    );
  }

  String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// The trips from [from] to [to] on [day] (null: the next 14 days) with
  /// [seats] seats left (0: room for a parcel).
  Future<List<C2cTrip>> searchTrips({required Geo from, required Geo to, DateTime? day, int seats = 1}) async {
    final r = await _db.rpc('c2c_search_trips', params: {
      'p_from': _geo(from),
      'p_to': _geo(to),
      'p_day': day == null ? null : _day(day),
      'p_seats': seats,
    });
    return [
      for (final e in r is List ? r : const [])
        if (e is Map) C2cTrip.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  /// One trip as riders see it; null when it can't be read.
  Future<C2cTrip?> tripForRider(String id) async {
    final r = await _db.rpc('c2c_trip_for_rider', params: {'p_trip': id});
    return r is Map ? C2cTrip.fromJson(Map<String, dynamic>.from(r)) : null;
  }

  /// The pay sheet before booking on [tripId].
  Future<C2cPayInfo> seatPayInfo(String tripId) async =>
      C2cPayInfo.fromJson(await _db.rpc('c2c_seat_pay_info', params: {'p_trip': tripId}));

  /// Books seats (or a parcel slot) on [tripId]; the booking's id and status.
  Future<({String id, String status})> bookSeat({
    required String tripId,
    required int seats,
    required Map<String, dynamic> pickup,
    required C2cPayment payment,
    List<C2cPassenger> passengers = const [],
    C2cPayWay? way,
    double? expected,
    Map<String, dynamic>? parcel,
    String? note,
    FamilyPick? family,
  }) async {
    final r = await _db.rpc('c2c_book_seat', params: {
      'p_trip': tripId,
      'p_seats': seats,
      'p_pickup': pickup,
      'p_payment': payment.key,
      'p_passengers': passengers.isEmpty ? null : c2cPassengersJson(passengers),
      'p_method': way?.key,
      'p_expected': expected == null ? null : c2cRound2(expected),
      'p_parcel': parcel,
      'p_note': note,
      // Family (0317): who in the family the seats are for (the host books).
      'p_family': family == null ? null : familyBookingColumns(passengerId: family.id, withAdult: family.withAdult)['family'],
    });
    final m = r is Map ? r : const {};
    return (id: '${m['id']}', status: '${m['status'] ?? ''}');
  }

  /// Who else rides on the trip of [bookingId] (where the rule shows them).
  Future<List<({String name, double? rating, String pickup, int seats})>> coriders(String bookingId) async {
    final r = await _db.rpc('c2c_coriders', params: {'p_booking': bookingId});
    return [
      for (final e in r is List ? r : const [])
        if (e is Map)
          (
            name: '${e['name'] ?? 'Rider'}',
            rating: (e['rating'] as num?)?.toDouble(),
            pickup: '${e['pickup'] ?? ''}',
            seats: (e['seats'] as num?)?.round() ?? 1,
          ),
    ];
  }

  /// The driver approves or declines seat request [bookingId].
  Future<void> seatDecide(String bookingId, {required bool approve, String? reason}) =>
      _db.rpc('c2c_seat_decide', params: {'p_booking': bookingId, 'p_approve': approve, 'p_reason': reason});

  /// The driver's posted trips with their requests and passengers.
  Future<List<C2cTrip>> driverSeatTrips() async {
    final r = await _db.rpc('c2c_driver_seat_trips');
    return [
      for (final e in r is List ? r : const [])
        if (e is Map) C2cTrip.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  /// Starts (on the trip) or finishes (done) trip [tripId].
  Future<void> tripProgress(String tripId, C2cTripStatus to) =>
      _db.rpc('c2c_trip_progress', params: {'p_trip': tripId, 'p_status': to.key});

  /// Cancels trip [tripId] (and the later trips of its repeat with
  /// [series]); the riders told and the give-up fees charged.
  Future<({int cancelled, double fees, int riders})> tripCancel(String tripId, {String? reason, bool series = false}) async {
    final r = await _db.rpc('c2c_trip_cancel', params: {'p_trip': tripId, 'p_reason': reason, 'p_series': series});
    final m = r is Map ? r : const {};
    return (
      cancelled: (m['cancelled'] as num?)?.round() ?? 0,
      fees: (m['fees'] as num?)?.toDouble() ?? 0,
      riders: (m['riders'] as num?)?.round() ?? 0,
    );
  }
}


final cityToCityRepositoryProvider = Provider((ref) => CityToCityRepository(ref.watch(supabaseProvider)));

final c2cSettingsProvider = FutureProvider.autoDispose<C2cSettings>((ref) {
  ref.watchLive('city_to_city_settings');
  return ref.watch(cityToCityRepositoryProvider).settings();
});

final c2cRulesProvider = FutureProvider.autoDispose<List<C2cRule>>((ref) {
  ref.watchLive('c2c_route_rules');
  return ref.watch(cityToCityRepositoryProvider).rules();
});

/// The whole-car route rules only (the routes page; 0310's per-seat route
/// rules are on the per-seat page).
final c2cWholeCarRulesProvider = Provider.autoDispose<AsyncValue<List<C2cRule>>>(
  (ref) => ref.watch(c2cRulesProvider).whenData((l) => [for (final r in l) if (r.tripKind == 'whole_car') r]),
);

final c2cCountryPermitsProvider = FutureProvider.autoDispose<List<C2cCountryPermit>>((ref) {
  ref.watchLive('c2c_country_permits');
  return ref.watch(cityToCityRepositoryProvider).countryPermits();
});

final c2cPermitTypesProvider = FutureProvider.autoDispose<List<C2cPermitType>>((ref) async {
  try {
    return await ref.watch(cityToCityRepositoryProvider).permitTypes();
  } catch (_) {
    return const [];
  }
});

final commissionServiceRatesProvider = FutureProvider.autoDispose<Map<String, double>>((ref) {
  ref.watchLive('commission_service_rates');
  return ref.watch(cityToCityRepositoryProvider).serviceRates();
});

/// The fare cards and the City to City service, for the rules page's example.
final c2cFareContextProvider =
    FutureProvider.autoDispose<({List<FareTariff> cards, C2cService service})>((ref) async {
  ref.watchLive('fare_tariffs');
  ref.watchLive('settings_entries');
  final repo = ref.watch(cityToCityRepositoryProvider);
  try {
    return (cards: await repo.fareCards(), service: await repo.service());
  } catch (_) {
    return (cards: const <FareTariff>[], service: (id: null, types: const <String>{}, rates: null, active: false));
  }
});

/// Whether the City to City Vehicle Service is switched on (the home box
/// opens the page only then).
final c2cServiceActiveProvider = FutureProvider.autoDispose<bool>((ref) async {
  ref.watchLive('settings_entries');
  try {
    return (await ref.watch(cityToCityRepositoryProvider).service()).active;
  } catch (_) {
    return false;
  }
});

/// The signed-in rider's City to City trips, live.
final c2cMyTripsProvider = FutureProvider.autoDispose<List<C2cBooking>>((ref) {
  ref.watchLive('c2c_bookings');
  return ref.watch(cityToCityRepositoryProvider).myTrips();
});

/// One trip, live.
final c2cBookingProvider = FutureProvider.autoDispose.family<C2cBooking?, String>((ref, id) {
  ref.watchLive('c2c_bookings');
  return ref.watch(cityToCityRepositoryProvider).booking(id);
});

/// The offers on one request, live.
final c2cOffersProvider = FutureProvider.autoDispose.family<List<C2cOffer>, String>((ref, id) {
  ref.watchLive('c2c_offers');
  return ref.watch(cityToCityRepositoryProvider).offers(id);
});

/// The other side of a booked trip (name and phone, c2c_contact); null
/// before booking, after the trip, or when it can't be read.
final c2cContactProvider = FutureProvider.autoDispose.family<({String name, String? phone})?, String>((ref, id) async {
  ref.watchLive('c2c_bookings');
  try {
    return await ref.watch(cityToCityRepositoryProvider).contact(id);
  } catch (_) {
    return null;
  }
});

/// The driver's City to City requests, live.
final c2cDriverFeedProvider = FutureProvider.autoDispose<C2cDriverFeed>((ref) {
  ref.watchLive('c2c_bookings');
  ref.watchLive('c2c_offers');
  return ref.watch(cityToCityRepositoryProvider).driverFeed();
});

/// The trips the driver is booked on, live.
final c2cDriverTripsProvider = FutureProvider.autoDispose<List<C2cBooking>>((ref) {
  ref.watchLive('c2c_bookings');
  return ref.watch(cityToCityRepositoryProvider).driverTrips();
});

/// The give-up rules by region, live (0309).
final c2cGiveUpRulesProvider = FutureProvider.autoDispose<List<C2cGiveUpRule>>((ref) {
  ref.watchLive('c2c_giveup_rules');
  return ref.watch(cityToCityRepositoryProvider).giveUpRules();
});

/// The in-app payment rules by region, live (0309).
final c2cPayRulesProvider = FutureProvider.autoDispose<List<C2cPayRule>>((ref) {
  ref.watchLive('c2c_pay_rules');
  return ref.watch(cityToCityRepositoryProvider).payRules();
});

/// What the signed-in account owes City to City, live; none when it can't
/// be read.
final c2cMyOwedProvider = FutureProvider.autoDispose<C2cOwed>((ref) async {
  ref.watchLive('c2c_bookings');
  ref.watchLive('c2c_driver_fees');
  ref.watchLive('wallets');
  try {
    return await ref.watch(cityToCityRepositoryProvider).myOwed();
  } catch (_) {
    return C2cOwed.none;
  }
});

/// The per-seat rules by region, live (0310).
final c2cSeatRulesProvider = FutureProvider.autoDispose<List<C2cSeatRule>>((ref) {
  ref.watchLive('c2c_seat_rules');
  return ref.watch(cityToCityRepositoryProvider).seatRules();
});

/// The driver's posted trips with their bookings, live (0310).
final c2cDriverSeatTripsProvider = FutureProvider.autoDispose<List<C2cTrip>>((ref) {
  ref.watchLive('c2c_trips');
  ref.watchLive('c2c_bookings');
  return ref.watch(cityToCityRepositoryProvider).driverSeatTrips();
});

/// One posted trip as riders see it, live; null when it can't be read.
final c2cRiderTripProvider = FutureProvider.autoDispose.family<C2cTrip?, String>((ref, id) async {
  ref.watchLive('c2c_trips');
  ref.watchLive('c2c_bookings');
  try {
    return await ref.watch(cityToCityRepositoryProvider).tripForRider(id);
  } catch (_) {
    return null;
  }
});

/// Who else rides with the rider of a seat booking; none when it can't be read.
final c2cCoridersProvider =
    FutureProvider.autoDispose.family<List<({String name, double? rating, String pickup, int seats})>, String>(
        (ref, id) async {
  ref.watchLive('c2c_bookings');
  try {
    return await ref.watch(cityToCityRepositoryProvider).coriders(id);
  } catch (_) {
    return const [];
  }
});

/// Who rides on a seat booking: the family members and children the host may
/// book a seat for (Family, 0317: family_passengers for 'seat_trip'); none
/// for anyone else, or where the admin hasn't allowed it.
final c2cPassengerChoicesProvider = FutureProvider.autoDispose<List<C2cPassenger>>((ref) async {
  final List<FamilyPassenger> list;
  try {
    list = await ref.watch(familyPassengersProvider(familyModuleSeatTrip).future);
  } catch (_) {
    return const [];
  }
  return [
    for (final p in list)
      if (p.allowed) (name: p.name, familyMemberId: p.id),
  ];
});
