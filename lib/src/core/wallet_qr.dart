/// Wallet QR codes and QR payments (Expo `app/wallet-receive.tsx`,
/// `wallet-scan.tsx`, `wallet-coin-qr.tsx`).
///
/// A GET account's QR is `getpay://u/<user id>`, optionally with
/// `?amt=12.50` for a fixed amount; the payload is the same for receiving
/// money and GET.coin. Scanning one sends GET.coin to that account through
/// the transfer handshake, so the person shown on the code is the one who is
/// paid. Any other code is refused: `wallet_pay` only debits the payer, so
/// "paying" a code nobody on GET receives would take the money to no one.
library;

import 'server_timeout.dart';

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

/// Anything that isn't a GET account's code. Nothing is paid to it.
class UnsupportedQr extends ScannedQr {
  const UnsupportedQr(this.text, {this.damagedGetCode = false});
  final String text;

  /// A `getpay://` code whose account id doesn't read: cut off, mistyped
  /// or made by hand.
  final bool damagedGetCode;

  /// What the person scanning is told.
  String get message => damagedGetCode
      ? "This GET code can't be read. Ask for a new one."
      : "This isn't a GET payment code. Scan a GET.wallet QR to pay.";
}

/// Reads a scanned code, or null for an empty one.
ScannedQr? parseWalletQr(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (!text.toLowerCase().startsWith(walletQrScheme)) return UnsupportedQr(text);
  final rest = text.substring(walletQrScheme.length);
  final q = rest.indexOf('?');
  final id = (q < 0 ? rest : rest.substring(0, q)).trim().toLowerCase();
  if (!_uuid.hasMatch(id)) return UnsupportedQr(text, damagedGetCode: true);
  double? amount;
  if (q >= 0) {
    final amt = Uri.splitQueryString(rest.substring(q + 1))['amt'];
    final v = amt == null ? null : double.tryParse(amt);
    if (v != null && v.isFinite && v > 0) amount = (v * 100).roundToDouble() / 100;
  }
  return GetAccountQr(id, amount: amount);
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

/// Up to the next hundredth, as the server rounds coins spent (0174). The
/// small allowance keeps float noise (330.00000000000006) from adding a cent.
double coinsUp(double v) => (v * 100 - 1e-6).ceilToDouble() / 100;

CoinSplit computeCoinSplit(double amount, double coinBalance, double coinsPerCurrency) {
  if (!(amount > 0) || !(coinBalance > 0) || !(coinsPerCurrency > 0)) {
    return (coinsUsed: 0, coinValue: 0, walletShare: amount > 0 ? _round2(amount) : 0);
  }
  final maxCoinValue = (coinBalance / coinsPerCurrency * 100).floorToDouble() / 100;
  final coinValue = maxCoinValue < amount ? maxCoinValue : _round2(amount);
  return (
    coinsUsed: coinsUp(coinValue * coinsPerCurrency),
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
  final slow = serverTimeoutText(error);
  if (slow != null) return slow;
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

/// The file name a shared or saved wallet code travels under.
String walletQrFileName({required bool coin, double? amount}) {
  final base = coin ? 'getride-coin-qr' : 'getride-wallet-qr';
  return amount != null && amount > 0 ? '$base-${amount.toStringAsFixed(2).replaceAll('.', '-')}.png' : '$base.png';
}

/// The caption printed under a shared wallet code. GET.wallet and GET.coin
/// codes both name the rider's account number, never the internal user id
/// (the code itself carries that).
String walletQrCaption({required bool coin, required String userId, String? name}) {
  final who = (name ?? '').trim().toUpperCase();
  final id = 'Account no. ${walletAccountNumber(userId)}';
  return who.isEmpty ? id : '$who\n$id';
}

/// The text sent beside a shared wallet code. [amountLabel] is the
/// formatted fixed amount, when the code carries one (it expires after
/// [walletAmountQrTtl], so the text says so).
String walletQrShareText({required bool coin, required String userId, String? name, String? amountLabel}) {
  final who = (name ?? '').trim();
  return [
    coin
        ? 'Scan this code in GET.ride to send GET.coin${who.isEmpty ? '' : ' to $who'}.'
        : 'Scan this code in GET.ride to pay ${who.isEmpty ? 'me' : who}.',
    if (amountLabel != null) 'Amount: $amountLabel (the code expires after ${walletAmountQrTtl.inSeconds} seconds).',
    'Account no. ${walletAccountNumber(userId)}',
  ].join('\n');
}

/// The steps the Scan & Pay help sheet walks through.
const scanPayHowToSteps = [
  "Point the camera at the other person's GET.ride QR code, with the whole code inside the frame.",
  'Too dark to read? Turn on the flashlight with the torch button.',
  "No camera, or the code won't read? Paste the code's text into the box under the camera.",
  'Their code opens Send GET.coin to that person. Codes from outside GET.ride are not paid.',
  'Enter the amount and check the confirmation before you send.',
];
