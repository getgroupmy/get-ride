// Premium service rules and GET.Plus (migration 0316): the rules by place
// the admin keeps, the rider's terms and membership, the driver's Premium
// status, and the admin's members and revenue.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/premium_plus.dart';
import '../providers.dart';
import 'geo_service.dart' show knownPosition;
import 'live_tables.dart';

/// Where the rider is asking about: the pickup's point and names.
typedef PlusPlaceArgs = ({double? lat, double? lng, String? country, String? state, String? city});

class PremiumPlusRepository {
  PremiumPlusRepository(this._db);
  final SupabaseClient _db;

  // ---- The rules (admins write; everyone signed in reads) ----------------------------------------

  Future<List<PremiumPlusPlace>> places() async {
    final rows = await _db.from(premiumPlusTable).select().order('created_at', ascending: true);
    final out = [for (final r in rows) PremiumPlusPlace.fromRow(r)];
    out.sort((a, b) {
      final c = a.rank.compareTo(b.rank);
      return c != 0 ? c : a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    return out;
  }

  /// Adds [p] (no id) or changes its rules.
  Future<PremiumPlusPlace> savePlace(PremiumPlusPlace p) async {
    final row = p.id == null
        ? await _db.from(premiumPlusTable).insert(p.toRow()).select().single()
        : await _db.from(premiumPlusTable).update({'rules': p.rules}).eq('id', p.id!).select().single();
    return PremiumPlusPlace.fromRow(row);
  }

  Future<void> deletePlace(String id) => _db.from(premiumPlusTable).delete().eq('id', id);

  // ---- The rider -------------------------------------------------------------------------------

  Future<PremiumPlusTerms> terms(PlusPlaceArgs at) async => PremiumPlusTerms.fromJson(await _db.rpc(
    'premium_plus_terms',
    params: {'p_lat': at.lat, 'p_lng': at.lng, 'p_country': at.country, 'p_state': at.state, 'p_city': at.city},
  ));

  /// Joins (paid now from GET.wallet) at [expected] a month; what was charged.
  Future<double> join(PlusPlaceArgs at, {required double expected}) async {
    final r = await _db.rpc('plus_join', params: {
      'p_lat': at.lat,
      'p_lng': at.lng,
      'p_country': at.country,
      'p_state': at.state,
      'p_city': at.city,
      'p_expected': expected,
    });
    final c = r is Map ? r['charged'] : null;
    return c is num ? c.toDouble() : 0;
  }

  /// Off: cancel (kept to the end of the month); on: keep it.
  Future<void> setAutoRenew(bool on) => _db.rpc('plus_set_auto_renew', params: {'p_on': on});

  Future<List<PlusReceipt>> receipts() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return const [];
    final rows = await _db
        .from('plus_charges')
        .select()
        .eq('rider_id', uid)
        .order('created_at', ascending: false)
        .limit(36);
    return [for (final r in rows) PlusReceipt.fromRow(r)];
  }

  // ---- The driver ------------------------------------------------------------------------------

  Future<List<PremiumStatus>> myPremiumStatus({double? lat, double? lng}) async {
    final r = await _db.rpc('my_premium_status', params: {'p_lat': lat, 'p_lng': lng});
    return [for (final x in (r is List ? r : const [])) if (x is Map) PremiumStatus.fromJson(Map<String, dynamic>.from(x))];
  }

  // ---- The admin -------------------------------------------------------------------------------

  Future<PlusMembersPage> members({String? status, String? search, int limit = 50, int offset = 0}) async =>
      plusMembersPageFromJson(await _db.rpc('admin_plus_members', params: {
        'p_status': status,
        'p_search': search,
        'p_limit': limit,
        'p_offset': offset,
      }));

  Future<PlusRevenue> revenue({int days = 30}) async =>
      PlusRevenue.fromJson(await _db.rpc('admin_plus_revenue', params: {'p_days': days}));
}

final premiumPlusRepositoryProvider = Provider<PremiumPlusRepository>(
  (ref) => PremiumPlusRepository(ref.watch(supabaseProvider)),
);

/// The rules by place, live.
final premiumPlusPlacesProvider = FutureProvider.autoDispose<List<PremiumPlusPlace>>((ref) {
  ref.watchLive(premiumPlusTable);
  return ref.watch(premiumPlusRepositoryProvider).places();
});

/// The rider's terms at a place; [PremiumPlusTerms.none] when they can't be
/// read (an older server, no connection): the booking shows plain prices.
final premiumPlusTermsProvider = FutureProvider.autoDispose.family<PremiumPlusTerms, PlusPlaceArgs>((ref, at) async {
  ref.watchLive(premiumPlusTable);
  try {
    return await ref.watch(premiumPlusRepositoryProvider).terms(at);
  } catch (_) {
    return PremiumPlusTerms.none;
  }
});

final plusReceiptsProvider = FutureProvider.autoDispose<List<PlusReceipt>>(
  (ref) => ref.watch(premiumPlusRepositoryProvider).receipts(),
);

/// Where the driver is, never asking; a provider so tests can place them.
final premiumStatusPositionProvider = Provider<Future<LatLng?> Function()>((_) => knownPosition);

/// The signed-in driver's Premium services where they are (else their
/// service area); empty when none (or unreadable).
final myPremiumStatusProvider = FutureProvider.autoDispose<List<PremiumStatus>>((ref) async {
  ref.watchLive(premiumPlusTable);
  ref.watchLive('settings_entries');
  try {
    final at = await ref.watch(premiumStatusPositionProvider)();
    return await ref.watch(premiumPlusRepositoryProvider).myPremiumStatus(lat: at?.latitude, lng: at?.longitude);
  } catch (_) {
    return const [];
  }
});
