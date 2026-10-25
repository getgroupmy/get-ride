/// The server's per-country phone rules (migration 0292), as the sign-in
/// screens show them. The server refuses with "CODE: words" from the
/// phone lookup, the SMS code and the sign-up hook; the words are already
/// what the person reads.
library;

/// A number from a Blocked country, or on a country's blocked numbers.
const phoneBlocked = 'PHONE_BLOCKED';

/// Too short or too long for the country's mobile numbers.
const phoneLength = 'PHONE_LENGTH';

/// Not a mobile number (a landline): no code is sent to it.
const phoneNotMobile = 'PHONE_NOT_MOBILE';

/// No new accounts with the country's numbers.
const phoneRegistrationClosed = 'PHONE_REGISTRATION_CLOSED';

/// The country's codes for today are used up (new numbers only).
const phoneDailyLimit = 'PHONE_DAILY_LIMIT';

/// A refusal by the country rules.
class PhoneRuleRefusal implements Exception {
  const PhoneRuleRefusal(this.code, this.message);
  final String code;
  final String message;

  /// Shown under the number field (the number needs fixing), not in a popup.
  bool get inline => code == phoneLength || code == phoneNotMobile;

  /// The popup's title.
  String get title => switch (code) {
        phoneBlocked => 'Not available',
        phoneRegistrationClosed => 'New accounts closed',
        phoneDailyLimit => 'Too many sign-ups right now',
        _ => 'Check your number',
      };

  @override
  String toString() => message;
}

final _refusal = RegExp(r'(PHONE_[A-Z_]+):\s*([^"\n]*)');

/// The refusal in [text] (an error's message), or null when it is none.
PhoneRuleRefusal? parsePhoneRuleRefusal(Object? text) {
  final m = _refusal.firstMatch('${text ?? ''}');
  if (m == null) return null;
  // An error's toString() goes on after the words (", statusCode: 403)").
  final words = m.group(2)!.split(RegExp(r',\s*(?:statusCode|code|details|hint):')).first.trim();
  return PhoneRuleRefusal(m.group(1)!, words.isEmpty ? "This number can't be used to sign in." : words);
}
