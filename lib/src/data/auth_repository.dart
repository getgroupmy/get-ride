import 'package:android_id/android_id.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/auth_utils.dart';

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
  const PinSignInError(this.message);
  final String message;
}

/// Phone OTP + 6-digit PIN authentication, wire-compatible with the Expo app
/// (`contexts/AuthContext.tsx`).
class AuthRepository {
  AuthRepository(this._db);
  final SupabaseClient _db;

  static const _deviceIdKey = 'get_ride_device_id';

  /// Set while an OTP sign-in still has to choose a PIN, so the router keeps
  /// the new session on the set-PIN screen instead of entering the app.
  static bool pinSetupPending = false;

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
  }

  Future<PinSignInResult> signInWithPin(String phone, String pin) async {
    try {
      await _db.auth.signInWithPassword(phone: phone, password: derivePinPassword(pin));
      return const PinSignInOk();
    } on AuthException catch (e) {
      if (!RegExp('invalid login credentials', caseSensitive: false).hasMatch(e.message)) {
        return PinSignInError(e.message);
      }
      // Wrong PIN, or right PIN with a drifted Auth password? Ask the
      // rate-limited server check, which compares against the bcrypt hash.
      try {
        final id = await _db.rpc('verify_pin_for_login', params: {'p_phone': phone, 'p_pin': pin});
        if (id != null) return const PinSignInNeedsOtp();
        return const PinSignInError('Incorrect PIN. Please try again.');
      } on PostgrestException catch (pe) {
        final lock = parsePinLockSeconds(pe.message);
        if (lock != null) return PinSignInError(pinLockMessage(lock));
        return const PinSignInError('Incorrect PIN. Please try again.');
      }
    }
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
      return "Couldn't check your PIN. Please try again.";
    } catch (_) {
      return "Couldn't check your PIN. Please try again.";
    }
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
    await syncPinPassword(pin);
  }

  Future<void> syncPinPassword(String pin) async {
    try {
      await _db.auth.updateUser(UserAttributes(password: derivePinPassword(pin)));
    } on AuthException catch (e) {
      // 422 same_password → already in sync.
      if (!RegExp(r'same.?password|different.*password', caseSensitive: false)
          .hasMatch(e.message)) {
        rethrow;
      }
    }
  }

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

  Future<void> signOut() => _db.auth.signOut();
}
