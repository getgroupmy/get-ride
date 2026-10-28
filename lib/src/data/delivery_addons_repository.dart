// Freight and Courier add-ons (migration 0312): the admin's rules
// (`delivery_addon_rules`, read by every sender to price the add-ons), the
// driver's steps on the trip (the return leg, the cash on delivery) and the
// parcel cover claims.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/delivery_addons.dart';
import '../core/partner_type_rules.dart' show RegionScope;
import '../providers.dart';
import 'live_tables.dart';

const deliveryAddonRulesTable = 'delivery_addon_rules';
const coverClaimsTable = 'cover_claims';

class DeliveryAddonsRepository {
  DeliveryAddonsRepository(this._db);
  final SupabaseClient _db;

  /// Every rule; none when they can't be read (a database before 0312),
  /// which leaves every add-on off.
  Future<AddonRules> rules() async {
    try {
      final rows = await _db.from(deliveryAddonRulesTable).select();
      return AddonRules([for (final r in rows) AddonRule.fromRow(r)]);
    } catch (_) {
      return AddonRules.none;
    }
  }

  /// Saves [rule]; a region rule left with nothing of its own is removed
  /// (its place then follows the rule above). Default always stays.
  Future<void> save(AddonRule rule) async {
    if (rule.values.isEmpty && !rule.scope.isAll) {
      await remove(rule.scope);
      return;
    }
    await _db.from(deliveryAddonRulesTable).upsert(rule.toRow(), onConflict: 'place_key');
  }

  Future<void> remove(RegionScope scope) async {
    await _db.from(deliveryAddonRulesTable).delete().eq('place_key', scope.key);
  }

  /// The driver at a round trip's drop-off: the free wait starts.
  Future<void> returnArrived(String rideId) => _db.rpc('delivery_return_arrived', params: {'p_ride': rideId});

  /// The driver heads back: what the wait added.
  Future<Map<String, dynamic>> returnStart(String rideId) async =>
      Map<String, dynamic>.from(await _db.rpc('delivery_return_start', params: {'p_ride': rideId}) as Map);

  /// The courier has the cash: the COD moves from their GET.wallet to the
  /// sender's, less the fee.
  Future<Map<String, dynamic>> codCollected(String rideId) async =>
      Map<String, dynamic>.from(await _db.rpc('cod_collected', params: {'p_ride': rideId}) as Map);

  /// The recipient won't pay: the parcel goes back at the return rate.
  Future<Map<String, dynamic>> codRefused(String rideId) async =>
      Map<String, dynamic>.from(await _db.rpc('cod_refused', params: {'p_ride': rideId}) as Map);

  /// The sender's claim on a covered delivery.
  Future<CoverClaim> fileClaim(String rideId, double amount, String reason) async => CoverClaim.fromRow(
    Map<String, dynamic>.from(
      await _db.rpc('cover_claim_file', params: {'p_ride': rideId, 'p_amount': amount, 'p_reason': reason.trim()}) as Map,
    ),
  );

  /// The claim on a ride, if any (its sender and admins read it).
  Future<CoverClaim?> claimFor(String rideId) async {
    final r = await _db.from(coverClaimsTable).select().eq('ride_id', rideId).maybeSingle();
    return r == null ? null : CoverClaim.fromRow(r);
  }

  /// Every claim, open ones first then newest (admins).
  Future<List<CoverClaim>> claims({int limit = 200}) async {
    final rows = await _db
        .from(coverClaimsTable)
        .select()
        .order('status', ascending: false)
        .order('created_at', ascending: false)
        .limit(limit);
    final list = [for (final r in rows) CoverClaim.fromRow(r)];
    list.sort((a, b) => (a.open == b.open) ? 0 : (a.open ? -1 : 1));
    return list;
  }

  /// An admin approves (paying [amount] to the sender's GET.wallet) or
  /// rejects a claim.
  Future<void> decideClaim(String claimId, {required bool approve, double? amount, String? note}) =>
      _db.rpc('cover_claim_decide', params: {
        'p_claim': claimId,
        'p_approve': approve,
        'p_amount': amount,
        'p_note': (note ?? '').trim().isEmpty ? null : note!.trim(),
      });
}

final deliveryAddonsRepositoryProvider = Provider((ref) => DeliveryAddonsRepository(ref.watch(supabaseProvider)));

/// Every add-on rule, live; none when they can't be read.
final deliveryAddonRulesProvider = FutureProvider<AddonRules>((ref) async {
  ref.watchLive(deliveryAddonRulesTable);
  return ref.watch(deliveryAddonsRepositoryProvider).rules();
});

/// Every cover claim (Admin), live.
final coverClaimsProvider = FutureProvider.autoDispose<List<CoverClaim>>((ref) async {
  ref.watchLive(coverClaimsTable);
  return ref.watch(deliveryAddonsRepositoryProvider).claims();
});

/// The claim on a ride; null when none (or it can't be read).
final rideCoverClaimProvider = FutureProvider.autoDispose.family<CoverClaim?, String>((ref, rideId) async {
  ref.watchLive(coverClaimsTable);
  try {
    return await ref.watch(deliveryAddonsRepositoryProvider).claimFor(rideId);
  } catch (_) {
    return null;
  }
});
