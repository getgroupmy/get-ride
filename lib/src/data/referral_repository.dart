import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/referral.dart';
import '../providers.dart';

/// Referral RPCs (get.ride migrations 0078 / 0079).
class ReferralRepository {
  ReferralRepository(this._db);
  final SupabaseClient _db;

  /// Applies [code] to the signed-in account; both sides are credited
  /// server-side. One referral per account.
  Future<ApplyReferralResult> apply(String code) async =>
      ApplyReferralResult.fromRpc(await _db.rpc('apply_referral', params: {'p_code': normalizeReferralCode(code)}));

  /// Who invited this account, or null (also when 0079 isn't applied).
  Future<MyReferrer?> myReferrer() async {
    try {
      return MyReferrer.fromRpc(await _db.rpc('get_my_referrer'));
    } catch (_) {
      return null;
    }
  }

  /// How many accounts joined with this account's code, or null when it
  /// can't be read (signed out, `referrals` table missing).
  Future<int?> myReferralCount() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return null;
    try {
      return await _db.from('referrals').count().eq('referrer_user_id', uid);
    } catch (_) {
      return null;
    }
  }
}

final referralRepositoryProvider = Provider((ref) => ReferralRepository(ref.watch(supabaseProvider)));
