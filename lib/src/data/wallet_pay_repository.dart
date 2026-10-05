import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';

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
    final data = await _db.rpc(
      'wallet_pay',
      params: {'p_user': uid, 'p_amount': amount, 'p_note': note, 'p_method': 'qr_scan', 'p_redeem_coins': redeemCoins},
    );
    return WalletPayResult.fromRpc(data, amount: amount);
  }
}

final walletPayRepositoryProvider = Provider((ref) => WalletPayRepository(ref.watch(supabaseProvider)));
