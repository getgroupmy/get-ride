/// Pure helpers shared with the Expo app's `contexts/AuthContext.tsx` and
/// `utils/pinLock.ts`. Keep these byte-for-byte compatible: a user who set a
/// PIN in the Expo app must be able to sign in from Flutter and vice versa.
library;

import 'dart:math';

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

/// A random Auth password nobody keeps: written over the PIN-derived one
/// whenever a PIN is set or confirmed, so it stops being guessable. PIN
/// sign-in goes through the pin-login function, which sets its own.
String throwawayPassword([Random? random]) {
  final r = random ?? Random.secure();
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  return List.generate(43, (_) => alphabet[r.nextInt(alphabet.length)]).join();
}

/// What a pin-login answer means for the sign-in screen (function in
/// supabase/functions/pin-login).
sealed class PinLoginOutcome {
  const PinLoginOutcome();
}

/// Signed in: the session to adopt.
class PinLoginSignedIn extends PinLoginOutcome {
  const PinLoginSignedIn(this.refreshToken);
  final String refreshToken;
}

class PinLoginWrongPin extends PinLoginOutcome {
  const PinLoginWrongPin();
}

/// Too many wrong PINs on the account, or tries from this network.
class PinLoginRefused extends PinLoginOutcome {
  const PinLoginRefused(this.message);
  final String message;
}

/// The PIN is right but there is no phone login to give it: SMS code.
class PinLoginNeedsOtp extends PinLoginOutcome {
  const PinLoginNeedsOtp();
}

/// The function isn't there or didn't answer: the older sign-in decides.
class PinLoginUnavailable extends PinLoginOutcome {
  const PinLoginUnavailable();
}

/// Reads a pin-login answer ([status] and its JSON [body]). Pure.
PinLoginOutcome pinLoginOutcome(int status, Object? body) {
  final map = body is Map ? body : const {};
  final wait = map['retry_after'] is num ? (map['retry_after'] as num).toInt() : null;
  switch (status) {
    case 200:
      final session = map['session'];
      final token = session is Map ? session['refresh_token'] : null;
      return token is String && token.isNotEmpty ? PinLoginSignedIn(token) : const PinLoginUnavailable();
    case 401:
      return const PinLoginWrongPin();
    case 409:
      return const PinLoginNeedsOtp();
    case 423:
      return PinLoginRefused(pinLockMessage(wait ?? pinLockDefaultSeconds));
    case 429:
      return PinLoginRefused(rateLimitMessage(wait ?? 60));
    default:
      return const PinLoginUnavailable();
  }
}

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

/// Parses the `RATE_LIMITED:<seconds>` marker the pre-login checks raise
/// when one network address has asked too often (migration 0137).
int? parseRateLimitSeconds(String? message) {
  final m = RegExp(r'RATE_LIMITED:?(\d+)?').firstMatch(message ?? '');
  if (m == null) return null;
  return int.tryParse(m.group(1) ?? '') ?? 60;
}

String rateLimitMessage(int seconds) {
  final mins = (seconds / 60).ceil().clamp(1, 1 << 30);
  return 'Too many tries from this network. Try again in $mins minute${mins == 1 ? '' : 's'}.';
}

/// What an SMS code confirms, from the OTP screen's `next`: choosing a PIN
/// (new account, forgot PIN), re-syncing a drifted password from the PIN
/// just typed, or signing in past a PIN lock without changing the PIN.
enum OtpNext { setPin, resync, unlock }

OtpNext otpNextFor(String next, {String? pin}) => switch (next) {
  'resync' when pin != null => OtpNext.resync,
  'unlock' => OtpNext.unlock,
  _ => OtpNext.setPin,
};

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
