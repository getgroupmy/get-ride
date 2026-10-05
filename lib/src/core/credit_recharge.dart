/// Recharging GET.credit from GET.wallet (Expo `rechargeCredit`). The
/// `wallet_recharge_credit` RPC (migration 0066) moves the money
/// under a row lock; these checks only stop a request that cannot succeed.
library;

/// Parses a typed amount: digits with at most two decimals, else null.
double? parseRechargeAmount(String text) {
  final s = text.trim().replaceAll(',', '');
  if (!RegExp(r'^\d+(\.\d{0,2})?$').hasMatch(s)) return null;
  return double.tryParse(s);
}

/// Why [amount] cannot be recharged from a GET.wallet holding [walletBalance],
/// or null when it can.
String? rechargeCreditProblem(double? amount, double walletBalance) {
  if (amount == null || amount <= 0) return 'Enter an amount greater than 0.';
  if (amount > walletBalance + 1e-9) return 'Not enough balance in GET.wallet.';
  return null;
}

/// What to tell the partner when the RPC refuses.
String rechargeCreditErrorMessage(Object error) {
  final s = error.toString().toLowerCase();
  if (s.contains('insufficient_balance')) return 'Not enough balance in GET.wallet.';
  if (s.contains('invalid_amount')) return 'Enter an amount greater than 0.';
  if (s.contains('not_authorized') ||
      s.contains('42501') ||
      s.contains('permission denied') ||
      s.contains('row-level security')) {
    return "Your session can't access the shared wallet. Please sign in again.";
  }
  return 'Recharge failed. Please try again.';
}
