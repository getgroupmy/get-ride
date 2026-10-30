// myGiG (migration 0329): the driver's state and settings, the phone
// lookup, the server's price, sending the fare and the passenger's answer,
// the ride's own steps (arrived, start, waiting at a stop, change the
// route, no-show, complete, pay by link not paid), blocking numbers,
// passes, the passenger's side (accept, decline, cancel) and the trip
// link page (no sign-in). The ride itself is a ride_requests row the
// server makes when the passenger accepts (mygig_make_ride), so booking
// is here: this is the myGiG module's repository (booking_modules.dart).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/mygig.dart';
import '../core/mygig_extras.dart';
import '../core/mygig_hire.dart';
import '../providers.dart';
import 'live_tables.dart';

/// A refusal from the server (its MYGIG_* code), as one sentence.
class MygigError implements Exception {
  const MygigError(this.message, {this.code});
  final String message;
  final String? code;

  static Object wrap(Object e) {
    if (e is! PostgrestException) return e;
    final hint = e.hint?.trim();
    final code = e.message.trim().split(RegExp(r'\s')).first;
    if (code.startsWith('RATE_LIMITED')) {
      return MygigError('Too many numbers checked. Try again in a few minutes.', code: 'RATE_LIMITED');
    }
    return MygigError(hint != null && hint.isNotEmpty ? hint : mygigRefusalText(code), code: code);
  }

  @override
  String toString() => message;
}

/// What sending gave back: the offer, the token (the link and "Show on
/// this phone"), the link and the message for WhatsApp.
class MygigSent {
  const MygigSent({required this.offerId, required this.way, this.token, this.link, this.message, this.expiresAt, this.total = 0, this.phone});

  factory MygigSent.fromJson(Map<String, dynamic> j) => MygigSent(
    offerId: '${j['offerId'] ?? j['id'] ?? ''}',
    way: mygigWayFrom(j['way']) ?? MygigWay.here,
    token: j['token'] as String?,
    link: j['link'] as String?,
    message: j['message'] as String?,
    expiresAt: DateTime.tryParse('${j['expiresAt'] ?? ''}')?.toLocal(),
    total: j['total'] is num ? (j['total'] as num).toDouble() : double.tryParse('${j['total']}') ?? 0,
    phone: j['phone'] as String?,
  );

  final String offerId;
  final MygigWay way;
  final String? token;
  final String? link;
  final String? message;
  final DateTime? expiresAt;
  final double total;
  final String? phone;
}

/// An offer as the waiting screen, the passenger's app and the link read it.
class MygigOffer {
  const MygigOffer(this.raw);
  final Map<String, dynamic> raw;

  String get id => '${raw['id'] ?? ''}';
  String get kind => '${raw['kind'] ?? 'new'}';
  String get status => '${raw['status'] ?? 'waiting'}';
  MygigWay get way => mygigWayFrom(raw['way']) ?? MygigWay.here;
  String? get rideId => raw['rideId'] as String?;
  String? get name => raw['name'] as String?;
  String? get phone => raw['phone'] as String?;
  Map<String, dynamic> get trip => raw['trip'] is Map ? Map<String, dynamic>.from(raw['trip']) : const {};
  MygigQuote get quote => MygigQuote(raw['quote'] is Map ? Map<String, dynamic>.from(raw['quote']) : const {});
  double get total => raw['total'] is num ? (raw['total'] as num).toDouble() : quote.total;
  DateTime? get expiresAt => DateTime.tryParse('${raw['expiresAt'] ?? ''}')?.toLocal();
  Map<String, dynamic> get driver => raw['driver'] is Map ? Map<String, dynamic>.from(raw['driver']) : const {};
  MygigPay get pay => mygigPayFrom(trip['pay']);
  bool get waiting => status == 'waiting';
  Map<String, int> get bags => {
    for (final s in const ['small', 'medium', 'large'])
      s: (trip['bags'] is Map && (trip['bags'] as Map)[s] is num) ? ((trip['bags'] as Map)[s] as num).toInt() : 0,
  };
}

class MygigRepository {
  MygigRepository(this._db);
  final SupabaseClient _db;

  Future<T> _call<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      throw MygigError.wrap(e);
    }
  }

  Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  Future<MygigConfig> config({double? lat, double? lng}) => _call(() async {
    final v = await _db.rpc('mygig_config', params: {'p_lat': lat, 'p_lng': lng});
    return v is Map ? MygigConfig.fromJson(Map<String, dynamic>.from(v)) : MygigConfig.none;
  });

  Future<MygigPrefs> savePrefs(MygigPrefs p, {double? lat, double? lng}) => _call(() async {
    final v = await _db.rpc('mygig_save_prefs', params: {'p_prefs': p.raw, 'p_lat': lat, 'p_lng': lng});
    return MygigPrefs(_map(v));
  });

  Future<MygigLookup> lookup(String phone, {double? lat, double? lng}) => _call(() async {
    final v = await _db.rpc('mygig_lookup_phone', params: {'p_phone': phone, 'p_lat': lat, 'p_lng': lng});
    return MygigLookup.fromJson(_map(v));
  });

  /// The server's price for [trip] (pickup, drop, stops, round, km, min,
  /// pax, bags, approachKm, waiveApproach, pay).
  Future<MygigQuote> quote(Map<String, dynamic> trip) => _call(() async {
    final v = await _db.rpc('mygig_quote', params: {'p_trip': trip});
    return MygigQuote(_map(v));
  });

  Future<MygigSent> create({
    required Map<String, dynamic> trip,
    String? phone,
    String? name,
    required MygigWay way,
    double? lat,
    double? lng,
    Map<String, dynamic>? booking,
  }) => _call(() async {
    final v = await _db.rpc('mygig_create', params: {
      'p': {'trip': trip, 'phone': phone, 'name': name, 'way': way.name, 'booking': ?booking},
      'p_lat': lat,
      'p_lng': lng,
    });
    return MygigSent.fromJson(_map(v));
  });

  Future<MygigOffer> offer(String id) => _call(() async {
    return MygigOffer(_map(await _db.rpc('mygig_offer_status', params: {'p_offer': id})));
  });

  /// Send it again ([way]: another way). A new token: the old link ends.
  Future<MygigSent> resend(String id, {MygigWay? way}) => _call(() async {
    final v = _map(await _db.rpc('mygig_resend', params: {'p_offer': id, 'p_way': way?.name}));
    return MygigSent.fromJson(v);
  });

  Future<void> cancelOffer(String id) => _call(() => _db.rpc('mygig_cancel_offer', params: {'p_offer': id}));

  /// The passenger agrees (or not) on the driver's phone.
  Future<String?> answerHere(String id, {required bool accept}) => _call(() async {
    final v = _map(await _db.rpc('mygig_accept_here', params: {'p_offer': id, 'p_accept': accept}));
    return v['rideId'] as String?;
  });

  // ---- The passenger's app ------------------------------------------------------------------------
  Future<List<MygigOffer>> myOffers() => _call(() async {
    final v = await _db.rpc('mygig_my_offers');
    return [for (final o in (v is List ? v : const [])) if (o is Map) MygigOffer(Map<String, dynamic>.from(o))];
  });

  Future<String?> answer(String id, {required bool accept}) => _call(() async {
    final v = _map(await _db.rpc('mygig_accept', params: {'p_offer': id, 'p_accept': accept}));
    return v['rideId'] as String?;
  });

  /// The passenger cancels after accepting ({fee, feeStatus}).
  Future<double> cancelRide({String? rideId, String? token}) => _call(() async {
    final v = _map(await _db.rpc('mygig_cancel_ride', params: {'p_ride': rideId, 'p_token': token}));
    return v['fee'] is num ? (v['fee'] as num).toDouble() : 0;
  });

  // ---- The trip link (no sign-in) -------------------------------------------------------------------
  Future<Map<String, dynamic>> linkView(String token) =>
      _call(() async => _map(await _db.rpc('mygig_link_view', params: {'p_token': token})));

  Future<String?> linkAnswer(String token, {required bool accept}) => _call(() async {
    final v = _map(await _db.rpc('mygig_link_answer', params: {'p_token': token, 'p_accept': accept}));
    return v['rideId'] as String?;
  });

  // ---- The ride -------------------------------------------------------------------------------------
  Future<void> arrived(String ride, {double? lat, double? lng}) =>
      _call(() => _db.rpc('mygig_arrived', params: {'p_ride': ride, 'p_lat': lat, 'p_lng': lng}));

  Future<void> start(String ride) => _call(() => _db.rpc('mygig_start', params: {'p_ride': ride}));

  Future<void> stopWait(String ride, {required bool on}) =>
      _call(() => _db.rpc('mygig_stop_wait', params: {'p_ride': ride, 'p_on': on}));

  /// Change destination or add a stop ({drop?, stops?, km, min}): a change
  /// offer back to the passenger.
  Future<MygigSent> reprice(String ride, Map<String, dynamic> change) => _call(() async {
    return MygigSent.fromJson(_map(await _db.rpc('mygig_reprice', params: {'p_ride': ride, 'p_change': change})));
  });

  /// Passenger didn't come: {fee, feeStatus}.
  Future<double> noShow(String ride) => _call(() async {
    final v = _map(await _db.rpc('mygig_no_show', params: {'p_ride': ride}));
    return v['fee'] is num ? (v['fee'] as num).toDouble() : 0;
  });

  /// {needsPayment, owed} while a pay-by-link passenger still owes what was
  /// added (Complete waits), else the completed ride's figures. Null tolls
  /// and other charges keep what was entered before.
  Future<Map<String, dynamic>> complete(String ride, {double? tolls, double? other, String? note}) => _call(() async {
    return _map(await _db.rpc('mygig_complete',
        params: {'p_ride': ride, 'p_tolls': tolls, 'p_other': other, 'p_note': note}));
  });

  /// A cash passenger paid for coming to the pickup.
  Future<void> approachCash(String ride) => _call(() => _db.rpc('mygig_approach_cash', params: {'p_ride': ride}));

  Future<void> takeCash(String ride) => _call(() => _db.rpc('mygig_take_cash', params: {'p_ride': ride}));

  Future<void> block({String? phone, String? ride}) =>
      _call(() => _db.rpc('mygig_block', params: {'p_phone': phone, 'p_ride': ride}));

  Future<void> unblock(String digits) => _call(() => _db.rpc('mygig_unblock', params: {'p_digits': digits}));

  Future<MygigPass?> buyPass({required bool fromWallet}) => _call(() async {
    return MygigPass.fromJson(await _db.rpc('mygig_buy_pass', params: {'p_from': fromWallet ? 'wallet' : 'credit'}));
  });

  /// The payments function sends the passenger the pay link: for a ride,
  /// or (0330) a booking's id.
  Future<void> sendPayLink(String ride) => _call(() async {
    await _db.functions.invoke('payments/mygig-link', body: {'request_id': ride});
  });

  // ---- Bookings and hire (0330) ------------------------------------------------------------------------
  /// Scheduled myGiG: the driver's bookings, soonest first.
  Future<List<MygigBooking>> scheduled() => _call(() async => mygigBookingsFrom(await _db.rpc('mygig_scheduled')));

  /// The passenger's myGiG bookings.
  Future<List<MygigBooking>> myBookings() => _call(() async => mygigBookingsFrom(await _db.rpc('mygig_my_bookings')));

  /// Start (when due): the next day as a ride; its id.
  Future<String?> startBooking(String booking) => _call(() async {
    final v = _map(await _db.rpc('mygig_booking_start', params: {'p_booking': booking}));
    return v['rideId'] as String?;
  });

  /// The passenger paid what the booking still needs in cash.
  Future<double> bookingCash(String booking) => _call(() async {
    final v = _map(await _db.rpc('mygig_booking_cash', params: {'p_booking': booking}));
    return v['cash'] is num ? (v['cash'] as num).toDouble() : 0;
  });

  /// Cancels a booking (the driver's, the passenger's, or by the trip link's [token]).
  Future<Map<String, dynamic>> cancelBooking({String? booking, String? token, String? reason}) => _call(() async {
    return _map(await _db.rpc('mygig_booking_cancel', params: {'p_booking': booking, 'p_token': token, 'p_reason': reason}));
  });

  /// Ends a hire's day: the km driven, tolls and other charges. needsPayment
  /// when something is left to pay first.
  Future<Map<String, dynamic>> hireEnd(String ride, {double? km, double? tolls, double? other, String? note}) =>
      _call(() async => _map(await _db.rpc('mygig_hire_end',
          params: {'p_ride': ride, 'p_km': km, 'p_tolls': tolls, 'p_other': other, 'p_note': note})));

  // ---- Reassign (0331) ------------------------------------------------------------------------------
  /// The reasons and nearby drivers for a ride ([ride]) or a booking ([booking]).
  Future<MygigReassignOptions> reassignOptions({String? ride, String? booking}) => _call(() async =>
      MygigReassignOptions(_map(await _db.rpc('mygig_reassign_options', params: {'p_ride': ride, 'p_booking': booking}))));

  /// Asks [to] (or the driver with [code]) to take it over.
  Future<MygigReassign> reassignStart({String? ride, String? booking, String? to, String? code, required String reason}) =>
      _call(() async => MygigReassign(_map(await _db.rpc('mygig_reassign_start', params: {
            'p_ride': ride,
            'p_booking': booking,
            'p_to': to,
            'p_code': code,
            'p_reason': reason,
          }))));

  Future<MygigReassign> reassignView(String id) =>
      _call(() async => MygigReassign(_map(await _db.rpc('mygig_reassign_view', params: {'p_reassign': id}))));

  /// Open reassigns the caller is part of.
  Future<List<MygigReassign>> reassignsMine() => _call(() async {
    final v = await _db.rpc('mygig_reassigns_mine');
    return [for (final r in (v is List ? v : const [])) if (r is Map) MygigReassign(Map<String, dynamic>.from(r))];
  });

  /// The new driver: accept (with the tick) or decline.
  Future<MygigReassign> reassignDriverAnswer(String id, {required bool accept, bool ack = false}) => _call(() async =>
      MygigReassign(_map(await _db.rpc('mygig_reassign_driver_answer',
          params: {'p_reassign': id, 'p_accept': accept, 'p_ack': ack}))));

  /// The passenger: confirm (with the tick), keep or cancel; in the app or
  /// on the driver's phone ([id]), or on the trip link ([token]).
  Future<MygigReassign> reassignAnswer({String? id, String? token, required String answer, bool ack = false}) =>
      _call(() async => MygigReassign(_map(await _db.rpc('mygig_reassign_answer',
          params: {'p_reassign': id, 'p_token': token, 'p_answer': answer, 'p_ack': ack}))));

  /// The first driver: a new link for the passenger ({token, link, message, phone}).
  Future<Map<String, dynamic>> reassignResend(String id) =>
      _call(() async => _map(await _db.rpc('mygig_reassign_resend', params: {'p_reassign': id})));

  Future<void> reassignStop(String id) => _call(() => _db.rpc('mygig_reassign_stop', params: {'p_reassign': id}));

  // ---- Hotspots, quick trips, regulars (0331) ------------------------------------------------------
  Future<MygigHotspots> hotspots({required double lat, required double lng}) => _call(() async =>
      MygigHotspots(_map(await _db.rpc('mygig_hotspots', params: {'p_lat': lat, 'p_lng': lng}))));

  Future<List<MygigPlace>> quickTrips() => _call(() async {
    final v = await _db.rpc('mygig_quick_trips');
    return [for (final p in (v is List ? v : const [])) if (p is Map) MygigPlace(Map<String, dynamic>.from(p))];
  });

  Future<MygigRegular?> regular(String phone) =>
      _call(() async => MygigRegular.of(await _db.rpc('mygig_regular', params: {'p_phone': phone})));

  // ---- After the trip (0331): the passenger in the app ([ride]) or on the link ([token]) ------------
  Future<MygigAfter> afterView({String? ride, String? token}) => _call(() async =>
      MygigAfter(_map(await _db.rpc('mygig_after_view', params: {'p_ride': ride, 'p_token': token}))));

  Future<void> afterRate(String token, int stars, {String? comment}) =>
      _call(() => _db.rpc('mygig_after_rate', params: {'p_token': token, 'p_stars': stars, 'p_comment': comment}));

  /// A tip: in the app from GET.wallet; on the link [how] 'link' (gives a
  /// pay part to pay) or 'cash'.
  Future<Map<String, dynamic>> afterTip({String? ride, String? token, required double amount, String how = 'link'}) =>
      _call(() async => _map(await _db.rpc('mygig_after_tip',
          params: {'p_ride': ride, 'p_token': token, 'p_amount': amount, 'p_how': how})));

  /// Splits what is owed between [parts] people; [phones] for the others.
  Future<Map<String, dynamic>> split({String? ride, String? token, required int parts, required List<String> phones}) =>
      _call(() async => _map(await _db.rpc('mygig_split',
          params: {'p_ride': ride, 'p_token': token, 'p_parts': parts, 'p_phones': phones})));

  Future<Map<String, dynamic>> einvoice({String? ride, String? token, required Map<String, dynamic> details}) =>
      _call(() async => _map(await _db.rpc('mygig_einvoice_request',
          params: {'p_ride': ride, 'p_token': token, 'p': details})));

  Future<Map<String, dynamic>> bookAgain({String? ride, String? token}) =>
      _call(() async => _map(await _db.rpc('mygig_book_again', params: {'p_ride': ride, 'p_token': token})));

  /// A share's own page (the link texted to another person).
  Future<Map<String, dynamic>> payPartView(String token) =>
      _call(() async => _map(await _db.rpc('mygig_pay_part_view', params: {'p_token': token})));

  /// The hosted page to pay a part (a share, a tip) or what the ride owes:
  /// signed in, or on the trip link with its [token]. The url.
  Future<String?> payLinkUrl(String request, {String? token}) => _call(() async {
    final r = await _db.functions.invoke('payments/mygig-link', body: {'request_id': request, 'token': ?token});
    final data = r.data;
    return data is Map ? data['url'] as String? : null;
  });

  // ---- Admin ----------------------------------------------------------------------------------------
  Future<MygigDashboard> adminDashboard({DateTime? day}) => _call(() async => MygigDashboard(_map(await _db.rpc(
      'mygig_admin_dashboard',
      params: {'p_day': day == null ? null : '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-'
          '${day.day.toString().padLeft(2, '0')}'}))));

  Future<List<Map<String, dynamic>>> adminBookings({String kind = '', String status = 'open', String search = ''}) =>
      _call(() async {
        final v = await _db.rpc('mygig_admin_bookings',
            params: {'p_kind': kind, 'p_status': status, 'p_search': search, 'p_limit': 200});
        return [for (final r in (v is List ? v : const [])) if (r is Map) Map<String, dynamic>.from(r)];
      });

  Future<void> adminEinvoiceSet(String id, String state, {String? note}) =>
      _call(() => _db.rpc('mygig_admin_einvoice_set', params: {'p_id': id, 'p_state': state, 'p_note': note}));

  // ---- Admin ----------------------------------------------------------------------------------------
  Future<Map<String, dynamic>> global() => _call(() async => _map(await _db.rpc('mygig_global')));

  Future<Map<String, dynamic>> saveGlobal({required String who, required MygigFee fee}) => _call(() async {
    return _map(await _db.rpc('set_mygig_global', params: {'p': {'who': who, 'fee': fee.toJson()}}));
  });

  Future<List<Map<String, dynamic>>> adminDrivers(String search) => _call(() async {
    final v = await _db.rpc('mygig_admin_drivers', params: {'p_search': search, 'p_limit': 100});
    return [for (final r in (v is List ? v : const [])) if (r is Map) Map<String, dynamic>.from(r)];
  });

  Future<void> adminDriverSet(String driver, {bool? allowed, required String charge, MygigFee? custom}) => _call(() async {
    await _db.rpc('mygig_admin_driver_set', params: {
      'p_driver': driver,
      'p': {'allowed': allowed, 'charge': charge, 'custom': custom?.toJson() ?? const {}},
    });
  });

  Future<List<Map<String, dynamic>>> adminPlaces() => _call(() async {
    final v = await _db.rpc('mygig_admin_places');
    return [for (final r in (v is List ? v : const [])) if (r is Map) Map<String, dynamic>.from(r)];
  });

  Future<void> adminPlaceSet(String area, String? rule) =>
      _call(() => _db.rpc('mygig_admin_place_set', params: {'p_area': area, 'p_rule': rule ?? 'allowed'}));

  /// The region rules (Default first).
  Future<List<Map<String, dynamic>>> rules() => _call(() async {
    final rows = await _db.from('mygig_rules').select().order('place_key', ascending: true);
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  });

  Future<void> saveRule({String? id, required String level, String? country, String? state, String? city, String? suburb,
      required Map<String, dynamic> settings}) => _call(() async {
    final row = {'level': level, 'country': country, 'state': state, 'city': city, 'suburb': suburb, 'settings': settings};
    if (id == null) {
      await _db.from('mygig_rules').insert(row);
    } else {
      await _db.from('mygig_rules').update({'settings': settings}).eq('id', id);
    }
  });

  Future<void> deleteRule(String id) => _call(() => _db.from('mygig_rules').delete().eq('id', id));
}

final mygigRepositoryProvider = Provider((ref) => MygigRepository(ref.watch(supabaseProvider)));

/// Where the driver is, rounded so a small move doesn't ask again.
typedef MygigAt = ({double? lat, double? lng});

/// The driver's myGiG state where they are; it changes with the admin's
/// settings (live) and is read again after a ride.
final mygigConfigProvider = FutureProvider.autoDispose.family<MygigConfig, MygigAt>((ref, at) {
  ref.watchLive('app_settings');
  ref.watchLive(mygigRulesTable);
  return ref.watch(mygigRepositoryProvider).config(lat: at.lat, lng: at.lng);
});

/// The table of the admin's myGiG rules (live in both apps).
const mygigRulesTable = 'mygig_rules';

/// Scheduled myGiG (0330): the driver's bookings, live.
final mygigScheduledProvider = FutureProvider.autoDispose<List<MygigBooking>>((ref) {
  ref.watchLive(mygigBookingsTable);
  return ref.watch(mygigRepositoryProvider).scheduled();
});

/// The passenger's myGiG bookings (0330), live.
final mygigMyBookingsProvider = FutureProvider.autoDispose<List<MygigBooking>>((ref) {
  ref.watchLive(mygigBookingsTable);
  return ref.watch(mygigRepositoryProvider).myBookings();
});

/// The table of myGiG bookings (0330).
const mygigBookingsTable = 'mygig_bookings';

/// The passenger's offers waiting in their app.
final mygigMyOffersProvider = FutureProvider.autoDispose<List<MygigOffer>>(
  (ref) => ref.watch(mygigRepositoryProvider).myOffers(),
);

/// Rounds a position to about 1 km, so the config isn't asked again on every fix.
MygigAt mygigAt(double? lat, double? lng) =>
    (lat: lat == null ? null : (lat * 100).roundToDouble() / 100, lng: lng == null ? null : (lng * 100).roundToDouble() / 100);

/// The table of myGiG reassigns (0331), live in both apps.
const mygigReassignsTable = 'mygig_reassigns';

/// Open reassigns the caller is part of (0331), live.
final mygigReassignsMineProvider = FutureProvider.autoDispose<List<MygigReassign>>((ref) {
  ref.watchLive(mygigReassignsTable);
  return ref.watch(mygigRepositoryProvider).reassignsMine();
});

/// One reassign, live.
final mygigReassignProvider = FutureProvider.autoDispose.family<MygigReassign, String>((ref, id) {
  ref.watchLive(mygigReassignsTable);
  return ref.watch(mygigRepositoryProvider).reassignView(id);
});
