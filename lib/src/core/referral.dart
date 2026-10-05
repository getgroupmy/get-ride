/// Referrals (Expo `utils/referral.ts`, get.ride migrations 0078 / 0079):
/// invite a friend with your code, and both accounts earn the bonus GET.coin
/// the admin set. The server (`apply_referral`) resolves a code to an
/// explicit `profiles.referral_code` first, else to the account whose id
/// starts with it, so the code shared here is whichever of the two the
/// account has.
library;

/// Letters and digits only, upper-cased.
String normalizeReferralCode(String? raw) => (raw ?? '').replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();

/// Whether [raw] can be a code at all (the server refuses anything shorter).
bool isPlausibleReferralCode(String? raw) => normalizeReferralCode(raw).length >= 4;

/// The code this account shares: its explicit `referral_code` when the admin
/// set one, else the first eight characters of its id (Expo
/// `referralCodeForUser`).
String referralCodeFor({required String userId, String? explicitCode}) {
  final explicit = normalizeReferralCode(explicitCode);
  if (explicit.length >= 4) return explicit;
  final fromId = normalizeReferralCode(userId);
  return fromId.isEmpty ? 'GETRIDE' : fromId.substring(0, fromId.length < 8 ? fromId.length : 8);
}

/// The web link that opens sign-up with [code] attached.
String referralLink(String code, {String base = 'https://getride.my/'}) =>
    Uri.parse(base).replace(queryParameters: {'ref': code}).toString();

/// The invitation text, as Expo shares it.
String referralMessage(String code, String link) =>
    'Join me on GET.ride!\n\n'
    'Sign up with my referral code $code and we both earn bonus GET.coin '
    'to spend on rides.\n\n$link';

/// The `ref` code carried by an incoming link, or null.
String? referralCodeFromUri(Uri uri) {
  final code = normalizeReferralCode(uri.queryParameters['ref']);
  return code.length >= 4 ? code : null;
}

/// What `apply_referral` answered.
class ApplyReferralResult {
  const ApplyReferralResult({required this.ok, this.error, this.referredCoins = 0, this.referrerCoins = 0});

  final bool ok;
  final String? error;

  /// GC credited to the new account.
  final double referredCoins;

  /// GC credited to the inviter.
  final double referrerCoins;

  factory ApplyReferralResult.fromRpc(Object? data) {
    final m = data is Map ? data : const {};
    double n(Object? v) {
      final d = v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
      return d > 0 ? d : 0;
    }

    final error = m['error'];
    return ApplyReferralResult(
      ok: m['ok'] == true,
      error: error is String && error.isNotEmpty ? error : null,
      referredCoins: n(m['referred_coins']),
      referrerCoins: n(m['referrer_coins']),
    );
  }
}

/// What to tell the new account about an applied (or refused) code.
String applyReferralMessage(ApplyReferralResult r, {String Function(double)? coins}) {
  final fmt = coins ?? (v) => '${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2)} GC';
  if (r.ok) {
    return r.referredCoins > 0
        ? 'Referral applied. Welcome bonus: ${fmt(r.referredCoins)} added to your GET.coin.'
        : 'Referral applied.';
  }
  return switch (r.error) {
    'code_not_found' || 'invalid_code' => "That referral code wasn't found.",
    'self_referral' => "You can't use your own referral code.",
    'already_referred' => 'A referral code was already applied to this account.',
    'disabled' => 'Referral rewards are switched off right now.',
    'not_new_account' => 'Referral codes can only be used when an account is new.',
    'not_authenticated' => 'Sign in again to apply the referral code.',
    _ => "The referral code couldn't be applied.",
  };
}

/// Who invited this account (`get_my_referrer`).
class MyReferrer {
  const MyReferrer({this.name, this.code});
  final String? name;
  final String? code;

  static MyReferrer? fromRpc(Object? data) {
    if (data is! Map) return null;
    String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    return MyReferrer(name: s(data['name']), code: s(data['code']));
  }
}

/// A referral code picked up from the link the app was opened with, held
/// until a new account finishes signing up.
class PendingReferral {
  PendingReferral._();
  static String? code;
}
