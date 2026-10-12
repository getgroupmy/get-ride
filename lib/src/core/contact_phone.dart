/// A phone number on a form with a dial-code picker beside it (emergency
/// contacts): split a stored number back into the country and the local
/// part, and join them again for saving.
library;

import 'auth_utils.dart';
import 'dial_countries.dart';
import 'phone_input.dart';

/// [phone] as the picker and the number field show it. An international
/// number (`+60…`) picks the listed country with the longest matching dial
/// code; one from an unlisted country stays whole in the field, `+` and all.
/// A local number (`012…`, or an older contact saved without a code) goes on
/// the default country with its trunk `0` dropped.
({DialCountry country, String local}) splitContactPhone(String? phone, {required String defaultDialCode}) {
  final raw = (phone ?? '').trim();
  final fallback = dialCountryFor(defaultDialCode);
  if (!raw.startsWith('+')) return (country: fallback, local: withoutTrunkZero(raw));
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  DialCountry? best;
  for (final c in dialCountries) {
    final code = c.dialCode.substring(1);
    if (digits.startsWith(code) &&
        digits.length > code.length &&
        (best == null || code.length > best.dialCode.length - 1)) {
      best = c;
    }
  }
  if (best == null) return (country: fallback, local: raw);
  return (country: best, local: digits.substring(best.dialCode.length - 1));
}

/// The number to save: the picked dial code and the local part, or the
/// field as typed when it already starts with `+` (another country's code
/// keyed in by hand). Empty when there are no digits.
String composeContactPhone(String dialCode, String local) {
  final l = local.trim();
  if (l.replaceAll(RegExp(r'\D'), '').isEmpty) return '';
  return l.startsWith('+') ? normalizeE164(l) : composePhone(dialCode, l);
}
