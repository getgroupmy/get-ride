// Family (migration 0317): the host's family, a member's invite and terms,
// the booking screens' Family row and passengers, a trip's "Shared with
// family" state, the child's pickup code (host and driver), and Admin ›
// People › Family. Everything goes through the family_* functions: nobody
// reads the family tables directly.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/commission.dart' show Geo;
import '../core/family.dart';
import '../providers.dart';
import 'live_tables.dart';

Map<String, dynamic> _place(Geo? g) => {
  if (g?.country != null) 'country': g!.country,
  if (g?.state != null) 'state': g!.state,
  if (g?.city != null) 'city': g!.city,
  if (g?.suburb != null) 'suburb': g!.suburb,
};

class FamilyRepository {
  FamilyRepository(this._db);
  final SupabaseClient _db;

  /// Runs [f], turning a family refusal into its words.
  Future<T> _call<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on PostgrestException catch (e) {
      throw familyRefusal(e.message, e.hint) ?? e;
    }
  }

  Future<FamilyView> mine({Geo? place}) =>
      _call(() async => FamilyView.fromJson(await _db.rpc('family_mine', params: {'p_place': _place(place)})));

  Future<FamilyMember> invite({
    required String phone,
    required String name,
    String? relation,
    double? monthlyLimit,
    double? perRideLimit,
    List<String>? services,
    FamilyLocationRule location = FamilyLocationRule.ride,
    Geo? place,
  }) => _call(() async => FamilyMember.fromJson(Map<String, dynamic>.from(await _db.rpc('family_invite', params: {
    'p_place': _place(place),
    'p_phone': phone,
    'p_name': name,
    'p_relation': relation,
    'p_monthly': monthlyLimit,
    'p_per_ride': perRideLimit,
    'p_services': services,
    'p_location': location.db,
  }) as Map)));

  Future<FamilyMember> addChild({
    required String name,
    required String birthDate,
    String? photoUrl,
    String? relation,
    List<String>? services,
    Geo? place,
  }) => _call(() async => FamilyMember.fromJson(Map<String, dynamic>.from(await _db.rpc('family_add_child', params: {
    'p_place': _place(place),
    'p_name': name,
    'p_birth_date': birthDate,
    'p_photo_url': photoUrl,
    'p_relation': relation,
    'p_services': services,
  }) as Map)));

  /// [patch]: monthlyLimit, perRideLimit, services, location, name, relation, birthDate, photoUrl.
  Future<FamilyMember> updateMember(String id, Map<String, dynamic> patch) => _call(() async => FamilyMember.fromJson(
      Map<String, dynamic>.from(await _db.rpc('family_update_member', params: {'p_member': id, 'p_patch': patch}) as Map)));

  /// A child's photo, for the driver's check: the host's folder in the
  /// `avatars` bucket (as profile photos). Returns its address.
  Future<String> uploadChildPhoto(Uint8List bytes) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw StateError('Sign in to add a photo.');
    final path = '$uid/family_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final bucket = _db.storage.from('avatars');
    await bucket.uploadBinary(path, bytes, fileOptions: const FileOptions(upsert: true, contentType: 'image/jpeg'));
    return bucket.getPublicUrl(path);
  }

  Future<void> removeMember(String id) => _call(() => _db.rpc('family_remove_member', params: {'p_member': id}));

  Future<void> requestCap(int wanted, {String? reason}) =>
      _call(() => _db.rpc('family_request_cap', params: {'p_wanted': wanted, 'p_reason': reason}));

  Future<List<FamilyInvite>> invites() => _call(() async {
    final res = await _db.rpc('family_my_invites');
    return [
      if (res is List)
        for (final r in res)
          if (r is Map) FamilyInvite.fromJson(Map<String, dynamic>.from(r)),
    ];
  });

  /// Join (with what was shown) or Not now.
  Future<void> respond(String memberId, {required bool join, List<String> shown = const []}) => _call(() => _db.rpc(
    'family_respond',
    params: {'p_member': memberId, 'p_join': join, 'p_terms': {'shown': shown}},
  ));

  Future<void> leave() => _call(() => _db.rpc('family_leave'));

  /// The member's switches: accept (or refuse) the host's raise; Share with family.
  Future<void> consent({bool? acceptRaise, bool? shareAlways}) => _call(() => _db.rpc(
    'family_member_consent',
    params: {'p_accept_raise': acceptRaise, 'p_share_always': shareAlways},
  ));

  Future<FamilyPayOption?> payOption(String module, {Geo? place, double? amount}) async {
    try {
      return FamilyPayOption.fromJson(await _db.rpc('family_pay_option',
          params: {'p_module': module, 'p_place': _place(place), 'p_amount': amount}));
    } catch (_) {
      return null; // a database without 0317, or signed out: no Family row
    }
  }

  Future<List<FamilyPassenger>> passengers(String module, {Geo? place}) async {
    try {
      final res = await _db.rpc('family_passengers', params: {'p_module': module, 'p_place': _place(place)});
      return [
        if (res is List)
          for (final r in res)
            if (r is Map) FamilyPassenger.fromJson(Map<String, dynamic>.from(r)),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<FamilyTripStatus> tripStatus(String tripId) async {
    try {
      return FamilyTripStatus.fromJson(await _db.rpc('family_trip_status', params: {'p_trip': tripId}));
    } catch (_) {
      return const FamilyTripStatus();
    }
  }

  Future<List<FamilyLiveItem>> live() => _call(() async {
    final res = await _db.rpc('family_live');
    return [
      if (res is List)
        for (final r in res)
          if (r is Map) FamilyLiveItem.fromJson(Map<String, dynamic>.from(r)),
    ];
  });

  Future<FamilyChildCode?> childCode(String tripId) async {
    try {
      return FamilyChildCode.fromJson(await _db.rpc('family_child_code', params: {'p_trip': tripId}));
    } catch (_) {
      return null;
    }
  }

  Future<FamilyChildCode?> newChildCode(String tripId) =>
      _call(() async => FamilyChildCode.fromJson(await _db.rpc('family_child_code_new', params: {'p_trip': tripId})));

  /// The child on the driver's trip, or null when it is not a child's trip.
  Future<FamilyChildCheck?> driverChild(String tripId) async {
    try {
      return FamilyChildCheck.fromJson(await _db.rpc('family_driver_child', params: {'p_trip': tripId}));
    } catch (_) {
      return null;
    }
  }

  Future<({bool ok, int triesLeft, bool locked})> verifyPickupCode(String tripId, String code) => _call(() async {
    final r = await _db.rpc('family_verify_pickup_code', params: {'p_trip': tripId, 'p_code': code.trim()});
    final m = r is Map ? r : const {};
    return (
      ok: m['ok'] == true,
      triesLeft: (m['triesLeft'] as num?)?.toInt() ?? 0,
      locked: m['locked'] == true,
    );
  });

  Future<List<FamilyViewLogEntry>> myViewLog() => _call(() async {
    final res = await _db.rpc('family_my_view_log');
    return [
      if (res is List)
        for (final r in res)
          if (r is Map) FamilyViewLogEntry.fromJson(Map<String, dynamic>.from(r)),
    ];
  });

  // ---- Admin › People › Family ----

  Future<List<FamilyPlaceRules>> places() async {
    final rows = await _db.from('family_places').select().order('level', ascending: true);
    final out = [for (final r in rows) FamilyPlaceRules.fromRow(r)]
      ..sort((a, b) => a.place.rank != b.place.rank ? a.place.rank.compareTo(b.place.rank) : a.place.label.compareTo(b.place.label));
    return out;
  }

  Future<void> savePlace(FamilyPlaceRules p) async {
    if (p.id == null) {
      await _db.from('family_places').insert(p.toRow());
    } else {
      await _db.from('family_places').update({'rules': p.rules}).eq('id', p.id!);
    }
  }

  Future<void> deletePlace(String id) => _db.from('family_places').delete().eq('id', id);

  Future<List<({String key, String name})>> registeredModules() async {
    final rows = await _db.from('booking_modules').select('key, name').order('position', ascending: true);
    return [for (final r in rows) (key: '${r['key']}', name: '${r['name']}')];
  }

  Future<List<FamilyModuleRule>> moduleRules() async {
    final rows = await _db.from('family_module_rules').select().order('module_key', ascending: true);
    return [for (final r in rows) FamilyModuleRule.fromRow(r)];
  }

  /// Saves one module's switches at a place (a new row, or the existing one).
  Future<void> saveModuleRule(FamilyModuleRule r) async {
    if (r.id == null) {
      await _db.from('family_module_rules').insert(r.toRow());
    } else {
      await _db.from('family_module_rules').update({
        'family_pays': r.familyPays,
        'book_for_member': r.bookForMember,
        'child_allowed': r.childAllowed,
        'live_share': r.liveShare,
      }).eq('id', r.id!);
    }
  }

  Future<List<FamilyAdminRow>> adminList({String? search}) => _call(() async {
    final res = await _db.rpc('family_admin_list', params: {'p_search': search, 'p_limit': 100, 'p_offset': 0});
    return [
      if (res is List)
        for (final r in res)
          if (r is Map) FamilyAdminRow.fromJson(Map<String, dynamic>.from(r)),
    ];
  });

  Future<void> setCap(String familyId, int? cap) =>
      _call(() => _db.rpc('family_admin_set_cap', params: {'p_family': familyId, 'p_cap': cap}));

  Future<List<FamilyCapRequest>> capRequests() => _call(() async {
    final res = await _db.rpc('family_admin_requests', params: {'p_status': 'pending'});
    return [
      if (res is List)
        for (final r in res)
          if (r is Map) FamilyCapRequest.fromJson(Map<String, dynamic>.from(r)),
    ];
  });

  Future<void> decide(String requestId, {required bool approve, String? note}) => _call(() => _db.rpc(
    'family_admin_decide',
    params: {'p_request': requestId, 'p_approve': approve, 'p_note': note},
  ));

  /// God View, logged: the family with its members and recent trips.
  Future<Map<String, dynamic>> adminView(String familyId, String kind, String reason) => _call(() async =>
      Map<String, dynamic>.from(await _db.rpc('family_admin_view',
          params: {'p_family': familyId, 'p_reason_kind': kind, 'p_reason': reason}) as Map));

  Future<List<FamilyViewLogEntry>> adminViewLog({String? familyId}) => _call(() async {
    final res = await _db.rpc('family_admin_view_log', params: {'p_family': familyId, 'p_limit': 100});
    return [
      if (res is List)
        for (final r in res)
          if (r is Map) FamilyViewLogEntry.fromJson(Map<String, dynamic>.from(r)),
    ];
  });
}

final familyRepositoryProvider = Provider((ref) => FamilyRepository(ref.watch(supabaseProvider)));

final familyMineProvider = FutureProvider.autoDispose<FamilyView>((ref) {
  ref.watchLive('family_places');
  ref.watchLive('family_module_rules');
  return ref.watch(familyRepositoryProvider).mine();
});

final familyInvitesProvider = FutureProvider.autoDispose<List<FamilyInvite>>((ref) async {
  try {
    return await ref.watch(familyRepositoryProvider).invites();
  } catch (_) {
    return const [];
  }
});

final familyLiveProvider = FutureProvider.autoDispose<List<FamilyLiveItem>>((ref) async {
  try {
    return await ref.watch(familyRepositoryProvider).live();
  } catch (_) {
    return const [];
  }
});

final familyViewLogProvider = FutureProvider.autoDispose<List<FamilyViewLogEntry>>((ref) {
  return ref.watch(familyRepositoryProvider).myViewLog();
});

/// The Family row for a booking screen of [module]; null when the caller is
/// not a member (or the database has no Family yet).
final familyPayOptionProvider = FutureProvider.autoDispose.family<FamilyPayOption?, String>((ref, module) {
  ref.watchLive('family_module_rules');
  return ref.watch(familyRepositoryProvider).payOption(module);
});

/// The members and children the host may book [module] for.
final familyPassengersProvider = FutureProvider.autoDispose.family<List<FamilyPassenger>, String>((ref, module) {
  ref.watchLive('family_module_rules');
  return ref.watch(familyRepositoryProvider).passengers(module);
});

final familyTripStatusProvider = FutureProvider.autoDispose.family<FamilyTripStatus, String>((ref, tripId) {
  return ref.watch(familyRepositoryProvider).tripStatus(tripId);
});

final familyChildCodeProvider = FutureProvider.autoDispose.family<FamilyChildCode?, String>((ref, tripId) {
  return ref.watch(familyRepositoryProvider).childCode(tripId);
});

final familyDriverChildProvider = FutureProvider.autoDispose.family<FamilyChildCheck?, String>((ref, tripId) {
  return ref.watch(familyRepositoryProvider).driverChild(tripId);
});

// Admin.
final familyPlacesProvider = FutureProvider.autoDispose<List<FamilyPlaceRules>>((ref) {
  ref.watchLive('family_places');
  return ref.watch(familyRepositoryProvider).places();
});

final familyRegisteredModulesProvider = FutureProvider.autoDispose<List<({String key, String name})>>((ref) {
  ref.watchLive('booking_modules');
  return ref.watch(familyRepositoryProvider).registeredModules();
});

final familyModuleRulesProvider = FutureProvider.autoDispose<List<FamilyModuleRule>>((ref) {
  ref.watchLive('family_module_rules');
  return ref.watch(familyRepositoryProvider).moduleRules();
});

/// The families whose host's name or phone holds the search ('' for all).
final familyAdminListProvider = FutureProvider.autoDispose.family<List<FamilyAdminRow>, String>((ref, q) {
  return ref.watch(familyRepositoryProvider).adminList(search: q.trim().isEmpty ? null : q.trim());
});

final familyCapRequestsProvider = FutureProvider.autoDispose<List<FamilyCapRequest>>((ref) {
  return ref.watch(familyRepositoryProvider).capRequests();
});

final familyAdminLogProvider = FutureProvider.autoDispose<List<FamilyViewLogEntry>>((ref) {
  return ref.watch(familyRepositoryProvider).adminViewLog();
});
