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
  }) => _call(() async {
    final v = await _db.rpc('mygig_create', params: {
      'p': {'trip': trip, 'phone': phone, 'name': name, 'way': way.name},
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

  /// The payments function sends the passenger the pay link.
  Future<void> sendPayLink(String ride) => _call(() async {
    await _db.functions.invoke('payments/mygig-link', body: {'request_id': ride});
  });

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

/// The passenger's offers waiting in their app.
final mygigMyOffersProvider = FutureProvider.autoDispose<List<MygigOffer>>(
  (ref) => ref.watch(mygigRepositoryProvider).myOffers(),
);

/// Rounds a position to about 1 km, so the config isn't asked again on every fix.
MygigAt mygigAt(double? lat, double? lng) =>
    (lat: lat == null ? null : (lat * 100).roundToDouble() / 100, lng: lng == null ? null : (lng * 100).roundToDouble() / 100);
