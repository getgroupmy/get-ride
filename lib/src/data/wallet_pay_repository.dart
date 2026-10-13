import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';
import 'wallet_once.dart';

/// What `wallet_pay` settled.
class WalletPayResult {
  const WalletPayResult({required this.walletPaid, required this.coinsUsed, required this.coinValue});

  final double walletPaid;
  final double coinsUsed;
  final double coinValue;

  factory WalletPayResult.fromRpc(Object? data, {required double amount}) {
    double n(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
    final m = data is Map ? data : const {};
    return WalletPayResult(
      walletPaid: m.containsKey('wallet_paid') ? n(m['wallet_paid']) : amount,
      coinsUsed: n(m['coins_used']),
      coinValue: n(m['coin_value']),
    );
  }
}

/// QR payments out of GET.wallet (Expo `payFromWallet`). The owner-scoped
/// `wallet_pay` RPC (migration 0066) prices any GET.coin part at the admin
/// rate, checks the balances under row locks and writes the ledger rows.
class WalletPayRepository {
  WalletPayRepository(this._db);
  final SupabaseClient _db;

  /// Throws with the RPC's error string on refusal (map it with
  /// `walletPayErrorMessage`).
  Future<WalletPayResult> pay(double amount, {required String note, bool redeemCoins = false}) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw StateError('not_authorized');
    // Once per payment, however often a timed-out tap is repeated (0164).
    final data = await callWalletOnce(_db, 'wallet_pay', {
      'p_user': uid,
      'p_amount': amount,
      'p_note': note,
      'p_method': 'qr_scan',
      'p_redeem_coins': redeemCoins,
    });
    return WalletPayResult.fromRpc(data, amount: amount);
  }
}

final walletPayRepositoryProvider = Provider((ref) => WalletPayRepository(ref.watch(supabaseProvider)));

/// GET.wallet → GET.credit for partners (Expo `rechargeCredit`), through the
/// owner-scoped `wallet_recharge_credit` RPC. Throws with the RPC's error on
/// refusal (map it with `rechargeCreditErrorMessage`).
class CreditRechargeRepository {
  CreditRechargeRepository(this._db);
  final SupabaseClient _db;

  Future<void> recharge(double amount) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw StateError('not_authorized');
    await callWalletOnce(_db, 'wallet_recharge_credit', {'p_user': uid, 'p_amount': amount});
  }
}

final creditRechargeRepositoryProvider = Provider((ref) => CreditRechargeRepository(ref.watch(supabaseProvider)));
