// City ride safety (migration 0311): trip reports, blocked drivers, the
// driver's request filters (on the account and on the phone), passenger
// cover and the admin's settings. Pure logic: lib/src/core/ride_safety.dart.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/ride_safety.dart';
import '../providers.dart';
import 'live_tables.dart';

class RideSafetyRepository {
  RideSafetyRepository(this._db);
  final SupabaseClient _db;

  // ---- Settings and the admin's tables ------------------------------------------------------------

  Future<RideSafetySettings> settings() async =>
      RideSafetySettings.fromRow(await _db.from('ride_safety_settings').select().eq('id', 1).maybeSingle());

  Future<void> saveSettings(RideSafetySettings s) => _db.from('ride_safety_settings').update(s.toRow()).eq('id', 1);

  /// Every category, removed ones too (the admin's list shows the active ones).
  Future<List<TripReportCategory>> categories() async {
    final rows = await _db
        .from('trip_report_categories')
        .select()
        .order('position', ascending: true)
        .order('created_at', ascending: true);
    return [for (final r in rows) TripReportCategory.fromJson(r)];
  }

  /// Adds [c] (no id) or changes it.
  Future<void> saveCategory(TripReportCategory c) => c.id == null
      ? _db.from('trip_report_categories').insert(c.toRow())
      : _db.from('trip_report_categories').update(c.toRow()).eq('id', c.id!);

  /// Removed, but kept for the reports that name it.
  Future<void> removeCategory(String id) =>
      _db.from('trip_report_categories').update({'active': false}).eq('id', id);

  Future<List<CoverRule>> coverRules() async {
    final rows = await _db.from('passenger_cover_rules').select().order('created_at', ascending: true);
    return [for (final r in rows) CoverRule.fromJson(r)];
  }

  Future<void> saveCoverRule(CoverRule r) => r.id == null
      ? _db.from('passenger_cover_rules').insert(r.toRow())
      : _db.from('passenger_cover_rules').update(r.toRow()).eq('id', r.id!);

  Future<void> removeCoverRule(String id) => _db.from('passenger_cover_rules').delete().eq('id', id);

  // ---- The rider ----------------------------------------------------------------------------------

  /// The receipt's safety part; null for anyone but the trip's rider, or a
  /// database before 0311.
  Future<TripSafetyInfo?> tripInfo({String? requestId, String? c2cBookingId}) async {
    try {
      return TripSafetyInfo.fromJson(
        await _db.rpc('trip_safety_info', params: {'p_request': requestId, 'p_c2c_booking': c2cBookingId}),
      );
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202' || e.code == '42883') return null;
      rethrow;
    }
  }

  Future<TripReportResult> report({
    String? requestId,
    String? c2cBookingId,
    required String categoryId,
    String? note,
    bool alsoBlock = false,
  }) async =>
      TripReportResult.fromJson(await _db.rpc('trip_report_create', params: {
        'p_request': requestId,
        'p_category': categoryId,
        'p_note': note,
        'p_also_block': alsoBlock,
        'p_c2c_booking': c2cBookingId,
      }));

  Future<void> block({String? driverId, String? requestId, String? c2cBookingId, String source = 'receipt'}) =>
      _db.rpc('rider_block_driver', params: {
        'p_driver': driverId,
        'p_request': requestId,
        'p_c2c_booking': c2cBookingId,
        'p_source': source,
      });

  Future<void> unblock(String driverId) => _db.rpc('rider_unblock_driver', params: {'p_driver': driverId});

  Future<List<BlockedDriver>> blockedDrivers() async {
    final v = await _db.rpc('my_blocked_drivers');
    return [
      if (v is List)
        for (final r in v)
          if (r is Map) BlockedDriver.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  /// The Safety page's cover; null when none shows (or before 0311).
  Future<({PassengerCover? cover, bool showPermit})> myCover() async {
    try {
      final v = await _db.rpc('passenger_cover_mine');
      return (cover: PassengerCover.fromJson(v), showPermit: v is Map ? v['show_permit'] != false : true);
    } on PostgrestException {
      return (cover: null, showPermit: false);
    }
  }

  // ---- The driver's filters -------------------------------------------------------------------------

  Future<RequestFilters?> savedFilters(String driverId) async {
    final row = await _db.from('driver_request_filters').select().eq('driver_id', driverId).maybeSingle();
    return row == null ? null : RequestFilters.fromJson(row);
  }

  Future<void> saveFilters(String driverId, RequestFilters f) =>
      _db.from('driver_request_filters').upsert({'driver_id': driverId, ...f.toJson()});

  // ---- Admin --------------------------------------------------------------------------------------------

  Future<Map<String, DriverSafetyFlag>> flags() async {
    final rows = await _db.rpc('admin_driver_safety_flags');
    return driverSafetyFlagsByPartner([if (rows is List) for (final r in rows) if (r is Map) Map<String, dynamic>.from(r)]);
  }

  Future<AdminDriverSafety> driver(String partnerUserId) async =>
      AdminDriverSafety.fromJson(await _db.rpc('admin_driver_safety', params: {'p_partner': partnerUserId}));

  Future<void> markBlocksReviewed(String partnerUserId) =>
      _db.rpc('admin_driver_block_review', params: {'p_partner': partnerUserId});
}

final rideSafetyRepositoryProvider = Provider((ref) => RideSafetyRepository(ref.watch(supabaseProvider)));

final rideSafetySettingsProvider = FutureProvider.autoDispose<RideSafetySettings>((ref) async {
  ref.watchLive('ride_safety_settings');
  try {
    return await ref.watch(rideSafetyRepositoryProvider).settings();
  } on PostgrestException {
    // A database before 0311: the defaults.
    return const RideSafetySettings();
  }
});

final tripReportCategoriesProvider = FutureProvider.autoDispose<List<TripReportCategory>>((ref) {
  ref.watchLive('trip_report_categories');
  return ref.watch(rideSafetyRepositoryProvider).categories();
});

final coverRulesProvider = FutureProvider.autoDispose<List<CoverRule>>((ref) {
  ref.watchLive('passenger_cover_rules');
  return ref.watch(rideSafetyRepositoryProvider).coverRules();
});

final tripSafetyInfoProvider = FutureProvider.autoDispose.family<TripSafetyInfo?, String>((ref, requestId) {
  ref.watchLive('rider_blocks');
  return ref.watch(rideSafetyRepositoryProvider).tripInfo(requestId: requestId);
});

final blockedDriversProvider = FutureProvider.autoDispose<List<BlockedDriver>>((ref) {
  ref.watchLive('rider_blocks');
  return ref.watch(rideSafetyRepositoryProvider).blockedDrivers();
});

final myCoverProvider = FutureProvider.autoDispose<({PassengerCover? cover, bool showPermit})>((ref) {
  ref.watchLive('passenger_cover_rules');
  return ref.watch(rideSafetyRepositoryProvider).myCover();
});

/// Drivers flagged by reports or blocks, for the Partners list; none on a
/// database before 0311.
final adminDriverSafetyFlagsProvider = FutureProvider.autoDispose<Map<String, DriverSafetyFlag>>((ref) async {
  try {
    return await ref.watch(rideSafetyRepositoryProvider).flags();
  } catch (_) {
    return const {};
  }
});

final adminDriverSafetyProvider = FutureProvider.autoDispose.family<AdminDriverSafety, String>(
  (ref, partnerUserId) => ref.watch(rideSafetyRepositoryProvider).driver(partnerUserId),
);

// ---- The driver's filters: the phone first, the account behind it -----------------------------------

/// The phone's copy of the filters, per driver.
String requestFiltersKey(String driverId) => 'request_filters_$driverId';

/// The driver's filters as they set them (before the admin's limits).
class RequestFiltersNotifier extends Notifier<RequestFilters> {
  @override
  RequestFilters build() {
    final uid = _uid();
    if (uid != null) Future.microtask(() => _load(uid));
    return RequestFilters.none;
  }

  String? _uid() {
    try {
      return ref.read(currentUserIdProvider);
    } catch (_) {
      return null;
    }
  }

  Future<void> _load(String uid) async {
    try {
      final local = (await SharedPreferences.getInstance()).getString(requestFiltersKey(uid));
      if (local != null) state = RequestFilters.fromJson(jsonDecode(local));
    } catch (_) {}
    try {
      final saved = await ref.read(rideSafetyRepositoryProvider).savedFilters(uid);
      if (saved != null) state = saved;
    } catch (_) {
      // Offline or before 0311: the phone's copy stands.
    }
  }

  /// Saves [f] on the phone and to the account.
  Future<void> set(RequestFilters f) async {
    state = f;
    final uid = _uid();
    if (uid == null) return;
    try {
      await (await SharedPreferences.getInstance()).setString(requestFiltersKey(uid), jsonEncode(f.toJson()));
    } catch (_) {}
    try {
      await ref.read(rideSafetyRepositoryProvider).saveFilters(uid, f);
    } catch (_) {
      // Kept on the phone; saved to the account next time.
    }
  }
}

final requestFiltersProvider = NotifierProvider<RequestFiltersNotifier, RequestFilters>(RequestFiltersNotifier.new);

/// The filters as they apply: within the admin's limits, switched-off ones none.
final effectiveRequestFiltersProvider = Provider.autoDispose<RequestFilters>((ref) {
  final settings = ref.watch(rideSafetySettingsProvider).value ?? const RideSafetySettings();
  return ref.watch(requestFiltersProvider).within(settings);
});
