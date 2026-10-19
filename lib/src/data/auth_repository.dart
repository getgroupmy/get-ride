import 'package:android_id/android_id.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/auth_utils.dart';
import '../features/auth/passkey/passkey.dart' as pk;
import 'meter_session_store.dart';
import 'session_guard.dart';
import 'function_region.dart';

/// What the server knows about a phone number (`profile_phone_lookup`).
class PhoneLookup {
  const PhoneLookup({required this.hasProfile, required this.hasPin, required this.isDeleted});
  final bool hasProfile;
  final bool hasPin;
  final bool isDeleted;
}

/// Outcome of a PIN sign-in attempt.
sealed class PinSignInResult {
  const PinSignInResult();
}

class PinSignInOk extends PinSignInResult {
  const PinSignInOk();
}

/// The PIN is right but the Auth password drifted from it — confirm the phone
/// by OTP, then re-sync the password.
class PinSignInNeedsOtp extends PinSignInResult {
  const PinSignInNeedsOtp();
}

/// The number couldn't be looked up (no signal, server down). Nothing is
/// assumed about the account: treating it as new would send an existing user
/// to choose a new PIN.
class PhoneLookupFailed implements Exception {
  const PhoneLookupFailed();
  @override
  String toString() => 'Could not verify number. Please try again.';
}

class PinSignInError extends PinSignInResult {
  const PinSignInError(this.message, {this.locked = false});
  final String message;

  /// The PIN can't be tried now (the account is locked, or this network has
  /// tried too often): signing in with an SMS code still works.
  final bool locked;
}

/// Too many number lookups from this network (migration 0137).
class PhoneLookupRateLimited implements Exception {
  const PhoneLookupRateLimited(this.seconds);
  final int seconds;
  @override
  String toString() => rateLimitMessage(seconds);
}

/// Phone OTP + 6-digit PIN authentication, wire-compatible with the Expo app
/// (`contexts/AuthContext.tsx`).
class AuthRepository {
  AuthRepository(this._db);
  final SupabaseClient _db;

  /// One device per account (migration 0180): every sign-in below claims
  /// the account for this device.
  late final SessionGuard guard = SessionGuard(
    _db,
    deviceId: deviceIdentifier,
    label: thisDeviceLabel(),
    platform: thisDevicePlatform(),
  );

  static const _deviceIdKey = 'get_ride_device_id';

  /// Set while an OTP sign-in still has to choose a PIN, so the router keeps
  /// the new session on the set-PIN screen instead of entering the app.
  static bool pinSetupPending = false;

  /// Set by a sign-in with number and PIN or SMS code, so the app offers
  /// once to save a passkey for next time.
  static bool offerPasskeyAfterSignIn = false;

  User? get currentUser => _db.auth.currentUser;
  Stream<AuthState> get authChanges => _db.auth.onAuthStateChange;

  Future<PhoneLookup> lookupPhone(String phone) async {
    try {
      final rows = await _db.rpc('profile_phone_lookup', params: {'p_phone': phone});
      final list = rows is List ? rows : [rows];
      if (list.isEmpty || list.first == null) {
        return const PhoneLookup(hasProfile: false, hasPin: false, isDeleted: false);
      }
      final r = Map<String, dynamic>.from(list.first as Map);
      return PhoneLookup(
        hasProfile: r['has_profile'] == true,
        hasPin: r['has_pin'] == true,
        isDeleted: r['is_deleted'] == true,
      );
    } on PostgrestException catch (e) {
      final wait = parseRateLimitSeconds(e.message);
      if (wait != null) throw PhoneLookupRateLimited(wait);
      throw const PhoneLookupFailed();
    } catch (_) {
      throw const PhoneLookupFailed();
    }
  }

  /// Texts a sign-in code. [createUser] is true only once someone has said
  /// they want a new account: signing in, a PIN reset or an account still
  /// without a PIN must never create one (Expo `shouldCreateUser`).
  Future<void> sendOtp(String phone, {required bool createUser}) =>
      _db.auth.signInWithOtp(phone: phone, shouldCreateUser: createUser);

  /// Whether this device may create another account (the admin's device
  /// guard), asked before a new account chooses its PIN. Fails open.
  Future<DeviceRegistration> deviceRegistration() async {
    try {
      final data = await _db.rpc('device_registration_status', params: {'p_device_id': await deviceIdentifier()});
      return DeviceRegistration.fromRpc(data);
    } catch (_) {
      return DeviceRegistration.unknown;
    }
  }

  /// Starts moving the signed-in account to [phone]: Supabase Auth texts a
  /// code to the new number (Expo `sendPhoneChangeOtp`).
  Future<void> requestPhoneChange(String phone) => _db.auth.updateUser(UserAttributes(phone: phone));

  /// Confirms the change with the code sent to [phone]. The account's
  /// `profiles.phone` follows by trigger (migration 0092).
  Future<void> confirmPhoneChange(String phone, String code) async {
    await _db.auth.verifyOTP(type: OtpType.phoneChange, phone: phone, token: code);
  }

  Future<void> verifyOtp(String phone, String code) async {
    final res = await _db.auth.verifyOTP(type: OtpType.sms, phone: phone, token: code);
    if (res.session == null) {
      throw const AuthException('Verification failed — no session returned.');
    }
    await guard.claim();
    offerPasskeyAfterSignIn = true;
  }

  /// Signs in with the PIN through the pin-login function (migration 0172):
  /// the server checks the PIN, with its lockout, and hands back a session.
  /// There is no other route: the PIN-derived Auth password is gone (0175),
  /// so when the function can't be reached the SMS code is the way in.
  Future<PinSignInResult> signInWithPin(String phone, String pin) async {
    final outcome = await _pinLogin(phone, pin);
    switch (outcome) {
      case PinLoginSignedIn(:final refreshToken):
        await _db.auth.setSession(refreshToken);
        await guard.claim();
        offerPasskeyAfterSignIn = true;
        return const PinSignInOk();
      case PinLoginWrongPin(:final attemptsLeft):
        final policy = attemptsLeft == null ? PinPolicy.standard : await pinPolicy();
        return PinSignInError(wrongPinMessage(attemptsLeft, policy), locked: attemptsLeft == 0);
      case PinLoginRefused(:final message):
        return PinSignInError(message, locked: true);
      case PinLoginNeedsOtp():
        return const PinSignInNeedsOtp();
      case PinLoginUnavailable():
        return const PinSignInError("Couldn't reach sign-in. Check your connection, or sign in with an SMS code.");
    }
  }

  Future<PinLoginOutcome> _pinLogin(String phone, String pin) async {
    try {
      final res = await _db.functions.invokeNearDb('pin-login', body: {'phone': normalizeE164(phone), 'pin': pin});
      return pinLoginOutcome(res.status, res.data);
    } on FunctionException catch (e) {
      return pinLoginOutcome(e.status, e.details);
    } catch (_) {
      return const PinLoginUnavailable();
    }
  }

  /// The admin's PIN policy (0192); the standard one when it can't be read.
  Future<PinPolicy> pinPolicy() async {
    try {
      return PinPolicy.fromJson(await _db.rpc('pin_policy'));
    } catch (_) {
      return PinPolicy.standard;
    }
  }

  /// Every account needs a PIN (0192): when the signed-in account has none,
  /// the router keeps it on "Set your PIN". Only ever raises the flag (a
  /// forgot-PIN code sets it for an account that has one); fails open, so
  /// an older database or no signal never traps anyone.
  Future<void> syncPinRequirement() async {
    if (_db.auth.currentSession == null) return;
    try {
      final state = await _db.rpc('my_sign_in_state');
      if (state is Map && state['pinSet'] == false && state['pinRequired'] != false) pinSetupPending = true;
    } catch (_) {}
  }

  /// Checks [pin] against the signed-in account's current PIN before it may
  /// be changed (Expo `change-pin.tsx`). Uses the same rate-limited server
  /// check as sign-in, so guessing is locked out the same way. Null when it
  /// matches, else what to tell the user; fails closed when it can't check.
  Future<String?> checkCurrentPin(String pin) async {
    final user = _db.auth.currentUser;
    final phone = user?.phone ?? '';
    if (user == null || phone.isEmpty) return 'Sign in again to change your PIN.';
    try {
      final id = await _db.rpc('verify_pin_for_login', params: {'p_phone': normalizeE164(phone), 'p_pin': pin});
      return id != null && '$id' == user.id ? null : 'Incorrect PIN. Please try again.';
    } on PostgrestException catch (pe) {
      final lock = parsePinLockSeconds(pe.message);
      if (lock != null) return pinLockMessage(lock);
      final wait = parseRateLimitSeconds(pe.message);
      if (wait != null) return rateLimitMessage(wait);
      return "Couldn't check your PIN. Please try again.";
    } catch (_) {
      return "Couldn't check your PIN. Please try again.";
    }
  }

  /// Lifts the signed-in account's PIN lock (`clear_my_pin_lock`, migration
  /// 0137): an SMS sign-in proved the number is theirs. Best effort — a
  /// database without it, or no signal, leaves the lock to run out.
  Future<void> clearPinLock() async {
    try {
      await _db.rpc('clear_my_pin_lock');
    } catch (_) {}
  }

  /// Saves the PIN server-side (bcrypt via `set_login_pin`) and syncs the
  /// derived Auth password so future PIN logins mint a real session.
  /// Requires an active session (call after OTP verification).
  Future<void> setPin(String pin) async {
    final deviceId = await deviceIdentifier();
    try {
      await _db.rpc('set_login_pin', params: {'p_pin': pin, 'p_device_id': deviceId});
    } on PostgrestException catch (e) {
      if (isRegistrationBlocked(e.message)) {
        throw AuthException(
          deviceGuardMessage(emulator: RegExp('EMULATOR', caseSensitive: false).hasMatch(e.message)),
        );
      }
      rethrow;
    }
    await retireDerivedPassword();
  }

  /// Whether the signed-in account has a sign-in PIN (Settings offers
  /// "Set PIN" instead of "Change PIN" when it hasn't).
  Future<bool> hasPinSet() async {
    final phone = _db.auth.currentUser?.phone ?? '';
    if (phone.isEmpty) return true;
    return (await lookupPhone(normalizeE164(phone))).hasPin;
  }

  /// The signed-in account's own number, for the forgot-PIN code.
  String? get currentPhone {
    final phone = _db.auth.currentUser?.phone ?? '';
    return phone.isEmpty ? null : normalizeE164(phone);
  }

  /// Changes the signed-in account's PIN from Settings: the PIN is saved,
  /// then the old PIN-derived Auth password is retired. PIN sign-in goes
  /// through pin-login, which needs no password kept in step with the PIN,
  /// so this is always true now; the result stays for the screen's sake.
  /// [retryAfter] is no longer used.
  ///
  /// An account that already has a PIN proves it is theirs (migration
  /// 0223): with [currentPin], or — after "Forgot PIN?" — by the SMS sign-in
  /// that just happened, which the server sees on the session.
  Future<bool> changePin(
    String pin, {
    String? currentPin,
    Duration retryAfter = const Duration(milliseconds: 800),
  }) async {
    final Object? ok;
    try {
      ok = await _db.rpc('set_login_pin', params: {
        'p_pin': pin,
        'p_device_id': await deviceIdentifier(),
        if (currentPin != null && currentPin.isNotEmpty) 'p_current_pin': currentPin,
      });
    } on PostgrestException catch (e) {
      if (e.message.contains('PIN_PROOF_REQUIRED')) {
        throw const AuthException('Confirm it\'s you first: enter your current PIN, or use "Forgot PIN?".');
      }
      final lock = parsePinLockSeconds(e.message);
      if (lock != null) throw AuthException(pinLockMessage(lock));
      rethrow;
    }
    if (ok == false) throw const AuthException('Incorrect current PIN. Please try again.');
    await retireDerivedPassword();
    return true;
  }

  /// Writes a random password over the account's Auth password, so no
  /// PIN-derived one (`teksi-pin-v1-<pin>`, builds before 1.4.5) works. Called whenever a
  /// PIN is set or confirmed by SMS; PIN sign-in no longer needs a password
  /// the phone knows (pin-login sets its own). Best effort: the next sign-in
  /// through pin-login replaces it anyway.
  ///
  /// Once per account on this phone: Auth signs an account out everywhere
  /// else whenever its password changes, and no build since 1.4.5 writes a
  /// PIN-derived one again, so doing it every time only signed out the
  /// account's other devices.
  Future<void> retireDerivedPassword() async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return;
    final key = '$_retiredPasswordKey$userId';
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(key) ?? false) return;
      await _db.auth.updateUser(UserAttributes(password: throwawayPassword()));
      await prefs.setBool(key, true);
    } catch (_) {}
  }

  static const _retiredPasswordKey = 'get_ride_derived_password_retired:';

  /// The id the server's duplicate-account guard counts accounts by. The
  /// phone's own id where it has one (Android ID, iOS identifier for vendor,
  /// as Expo uses), so reinstalling the app doesn't reset the count; a random
  /// id kept for this install elsewhere.
  Future<String> deviceIdentifier() async {
    final hardware = await _hardwareId();
    if (hardware != null) return hardware;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  static String? _cachedHardwareId;

  static Future<String?> _hardwareId() async {
    if (_cachedHardwareId != null || kIsWeb) return _cachedHardwareId;
    try {
      final id = switch (defaultTargetPlatform) {
        TargetPlatform.android => await const AndroidId().getId(),
        TargetPlatform.iOS => (await DeviceInfoPlugin().iosInfo).identifierForVendor,
        _ => null,
      };
      if (id != null && id.trim().isNotEmpty) _cachedHardwareId = id.trim();
    } catch (_) {
      // No plugin in this build (tests, desktop): the install id stands in.
    }
    return _cachedHardwareId;
  }

  /// Signs in with a passkey saved on this device (or a phone nearby): no
  /// number, PIN or SMS. GoTrue checks it and starts the session.
  Future<pk.PasskeyResult> signInWithPasskey() async {
    final result = await pk.signInWithPasskey(_db.auth);
    if (result.outcome == pk.PasskeyOutcome.signedIn) await guard.claim();
    return result;
  }

  /// Saves a passkey for the signed-in account on this device.
  Future<pk.PasskeyResult> savePasskey() => pk.enrolPasskey(_db.auth);

  /// The signed-in account's passkeys, newest first.
  // ignore: experimental_member_use
  Future<List<Passkey>> passkeys() async => (await _db.auth.passkey.list())
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// Removes one: a passkey on a lost phone is a key somebody else holds.
  // ignore: experimental_member_use
  Future<void> removePasskey(String id) => _db.auth.passkey.delete(passkeyId: id);

  /// Signs out, and forgets this sign-in's meter on/off (Meter at sign-in).
  Future<void> signOut() async {
    await MeterSessionStore.clear();
    await _db.auth.signOut();
  }
}
