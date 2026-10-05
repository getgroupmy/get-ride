/// Wallet QR codes and QR payments (Expo `app/wallet-receive.tsx`,
/// `wallet-scan.tsx`, `wallet-coin-qr.tsx`).
///
/// A GET account's QR is `getpay://u/<user id>`, optionally with
/// `?amt=12.50` for a fixed amount; the payload is the same for receiving
/// money and GET.coin. Scanning one sends GET.coin to that account through
/// the transfer handshake, so the person shown on the code is the one who is
/// paid. Any other code (a merchant's) is a QR payment out of GET.wallet
/// through `wallet_pay`, which debits the payer only.
library;

const walletQrScheme = 'getpay://u/';

/// How long a fixed-amount code is shown before it must be regenerated.
const walletAmountQrTtl = Duration(seconds: 60);

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false);

/// The payload for [userId]'s code, with an amount when one is set.
String walletQrPayload(String userId, {double? amount}) {
  final base = '$walletQrScheme$userId';
  return amount != null && amount > 0 ? '$base?amt=${amount.toStringAsFixed(2)}' : base;
}

/// What a scanned code is.
sealed class ScannedQr {
  const ScannedQr();
}

/// Another GET account's code.
class GetAccountQr extends ScannedQr {
  const GetAccountQr(this.userId, {this.amount});
  final String userId;

  /// The amount the code asks for, when it carries one.
  final double? amount;
}

/// Anything else: paid as a QR payment, its text kept as the payment note.
class MerchantQr extends ScannedQr {
  const MerchantQr(this.text);
  final String text;

  /// Short form for the pay page and the ledger note.
  String get label => text.length > 42 ? '${text.substring(0, 42)}…' : text;
}

/// Reads a scanned code, or null for an empty one.
ScannedQr? parseWalletQr(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (text.toLowerCase().startsWith(walletQrScheme)) {
    final rest = text.substring(walletQrScheme.length);
    final q = rest.indexOf('?');
    final id = (q < 0 ? rest : rest.substring(0, q)).trim().toLowerCase();
    if (_uuid.hasMatch(id)) {
      double? amount;
      if (q >= 0) {
        final amt = Uri.splitQueryString(rest.substring(q + 1))['amt'];
        final v = amt == null ? null : double.tryParse(amt);
        if (v != null && v.isFinite && v > 0) amount = (v * 100).roundToDouble() / 100;
      }
      return GetAccountQr(id, amount: amount);
    }
  }
  return MerchantQr(text);
}

/// The display-only account number under a receive code: "2600" and 16
/// digits derived from the user id (same digits as Expo's `deriveDigits`).
String walletAccountNumber(String userId) => '2600${deriveWalletDigits(userId, 16)}';

/// FNV-1a over the id's UTF-16 code units, then an LCG one digit at a time.
String deriveWalletDigits(String userId, int length) {
  var h = 2166136261;
  for (final c in userId.codeUnits) {
    h = _imul32((h ^ c) & 0xFFFFFFFF, 16777619);
  }
  final out = StringBuffer();
  while (out.length < length) {
    h = (_imul32(h, 1103515245) + 12345) & 0xFFFFFFFF;
    out.write(h % 10);
  }
  return out.toString().substring(0, length);
}

/// `Math.imul` as an unsigned 32-bit product. Done in 16-bit halves so no
/// intermediate passes 2^53 (ints are doubles on the web build).
int _imul32(int a, int b) {
  final aHi = (a >> 16) & 0xFFFF, aLo = a & 0xFFFF;
  return ((aLo * b) + (((aHi * b) & 0xFFFF) << 16)) & 0xFFFFFFFF;
}

/// How a QR payment is split between GET.coin and GET.wallet when the payer
/// spends coins (Expo `computeCoinSplit`; `wallet_pay` settles with the same
/// arithmetic at the admin rate).
typedef CoinSplit = ({double coinsUsed, double coinValue, double walletShare});

double _round2(double v) => (v * 100).roundToDouble() / 100;

CoinSplit computeCoinSplit(double amount, double coinBalance, double coinsPerCurrency) {
  if (!(amount > 0) || !(coinBalance > 0) || !(coinsPerCurrency > 0)) {
    return (coinsUsed: 0, coinValue: 0, walletShare: amount > 0 ? _round2(amount) : 0);
  }
  final maxCoinValue = (coinBalance / coinsPerCurrency * 100).floorToDouble() / 100;
  final coinValue = maxCoinValue < amount ? maxCoinValue : _round2(amount);
  return (
    coinsUsed: _round2(coinValue * coinsPerCurrency),
    coinValue: coinValue,
    walletShare: _round2(amount - coinValue),
  );
}

/// Why a QR payment cannot go out, or null when it can.
String? walletPayProblem({required double amount, required double walletBalance, CoinSplit? split}) {
  if (!(amount > 0)) return 'Enter an amount greater than 0.';
  if (amount > 100000) return 'The most a single payment can be is RM100,000.';
  final fromWallet = split?.walletShare ?? amount;
  if (fromWallet > walletBalance + 0.0001) return 'Not enough balance in GET.wallet.';
  return null;
}

/// The message for a failed `wallet_pay` call.
String walletPayErrorMessage(Object error) {
  final s = error.toString().toLowerCase();
  if (s.contains('insufficient_balance')) return 'Not enough balance in GET.wallet.';
  if (s.contains('invalid_amount')) return 'Enter an amount between RM0.01 and RM100,000.';
  if (s.contains('not_authorized') ||
      s.contains('42501') ||
      s.contains('permission denied') ||
      s.contains('row-level security')) {
    return "Your session can't access the shared wallet. Please sign in again.";
  }
  return 'Payment failed. Please try again.';
}
