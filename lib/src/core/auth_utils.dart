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
/// part (`+60` + `012 345 6789` → `+60123456789`) and the dial code when it
/// was typed again in the number field (`+60` + `60123456789`), as Expo's
/// phone screen does. The repeat is only dropped when a whole number is left
/// behind, so a short local number that happens to start with the same
/// digits stays as typed.
String composePhone(String dialCode, String local) {
  var l = local.replaceAll(RegExp(r'[^\d]'), '');
  final dial = dialCode.replaceAll(RegExp(r'[^\d]'), '');
  if (dial.isNotEmpty && l.startsWith(dial) && l.length - dial.length >= 7) l = l.substring(dial.length);
  if (l.startsWith('0')) l = l.substring(1);
  return normalizeE164('$dialCode$l');
}

/// The longest first name the sign-up accepts (Expo `name-entry`).
const signupNameMaxLength = 50;

/// Why [name] can't be a new account's name, or null when it can.
String? signupNameProblem(String name) {
  final n = name.trim();
  if (n.isEmpty) return 'Please enter your name.';
  if (n.length > signupNameMaxLength) return 'Your name can be at most $signupNameMaxLength characters.';
  return null;
}

/// [name] trimmed, with single spaces and each word capitalised
/// (`  ahmad   bin ali` → `Ahmad Bin Ali`).
String capitaliseName(String name) => name
    .trim()
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .map((w) => w[0].toUpperCase() + w.substring(1))
    .join(' ');

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

/// What the device guard says when it refuses a new account (Expo
/// `pin-setup`): an emulator the admin has blocked, or a phone that already
/// holds as many accounts as allowed.
String deviceGuardMessage({required bool emulator}) => emulator
    ? "This device isn't supported for creating an account. Please sign up on a physical phone, "
        'or contact support if you think this is a mistake.'
    : "This device is already linked to several accounts, so a new account can't be created here. "
        'Please sign in to your existing account, or contact support if you think this is a mistake.';

/// `device_registration_status`: whether this device may create an account.
class DeviceRegistration {
  const DeviceRegistration({required this.allowed, this.emulatorBlocked = false});

  /// Fails open: when the check can't be made, the server's own guard in
  /// `set_login_pin` still has the last word.
  static const unknown = DeviceRegistration(allowed: true);

  factory DeviceRegistration.fromRpc(Object? data) {
    final row = data is List ? (data.isEmpty ? null : data.first) : data;
    if (row is! Map) return unknown;
    return DeviceRegistration(
      allowed: row['allowed'] != false,
      emulatorBlocked: row['is_emulator'] == true && row['block_emulators'] == true,
    );
  }

  final bool allowed;
  final bool emulatorBlocked;

  /// Null when allowed, else what to tell the user.
  String? get problem => allowed ? null : deviceGuardMessage(emulator: emulatorBlocked);
}

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
