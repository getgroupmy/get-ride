/// Pure helpers shared with the Expo app's `contexts/AuthContext.tsx` and
/// `utils/pinLock.ts`. Keep these byte-for-byte compatible: a user who set a
/// PIN in the Expo app must be able to sign in from Flutter and vice versa.
library;

/// Strips everything but digits and prefixes `+` (Expo `normalizeE164`).
String normalizeE164(String input) {
  final digits = input.trim().replaceAll(RegExp(r'[^\d]'), '');
  return digits.isEmpty ? '' : '+$digits';
}

/// Joins a dial code and a local number, dropping a trunk `0` from the local
/// part (`+60` + `012 345 6789` → `+60123456789`).
String composePhone(String dialCode, String local) {
  var l = local.replaceAll(RegExp(r'[^\d]'), '');
  if (l.startsWith('0')) l = l.substring(1);
  return normalizeE164('$dialCode$l');
}

/// Deterministic Supabase Auth password derived from the sign-in PIN, so a
/// PIN login can mint a real session via phone + password
/// (Expo `derivePinPassword`).
String derivePinPassword(String pin) => 'teksi-pin-v1-$pin';

/// Sign-in PINs are exactly six digits.
bool isValidPin(String pin) => RegExp(r'^\d{6}$').hasMatch(pin);

const pinLockDefaultSeconds = 15 * 60;

/// Parses the `PIN_LOCKED[:seconds]` marker raised by `verify_pin_for_login`.
int? parsePinLockSeconds(String? message) {
  final m = RegExp(r'PIN_LOCKED:?(\d+)?').firstMatch(message ?? '');
  if (m == null) return null;
  return int.tryParse(m.group(1) ?? '') ?? pinLockDefaultSeconds;
}

String pinLockMessage(int seconds) {
  final mins = (seconds / 60).ceil().clamp(1, 1 << 30);
  return 'Too many incorrect attempts. Try again in $mins minute${mins == 1 ? '' : 's'}.';
}

/// Errors from `set_login_pin` when the device-based duplicate-account guard
/// refuses a new registration.
bool isRegistrationBlocked(String? message) =>
    RegExp(r'DEVICE_LIMIT|EMULATOR|REGISTRATION_BLOCKED', caseSensitive: false)
        .hasMatch(message ?? '');

/// Why [newPhone] cannot replace [currentPhone], or null when it can.
/// [takenByAnother] is the `profile_phone_lookup` answer: a live profile
/// already holds the number.
String? phoneChangeProblem(String newPhone, String? currentPhone, {required bool takenByAnother}) {
  final digits = newPhone.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 8 || digits.length > 15) return 'Enter a valid phone number.';
  final current = (currentPhone ?? '').replaceAll(RegExp(r'\D'), '');
  if (current.isNotEmpty && current == digits) return 'That is already your number.';
  if (takenByAnother) return 'This number is already linked to another account.';
  return null;
}
