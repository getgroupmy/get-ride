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
      // Unknown → treat as new; the OTP path works for everyone.
      return const PhoneLookup(hasProfile: false, hasPin: false, isDeleted: false);
    }
  }

  Future<void> sendOtp(String phone) => _db.auth.signInWithOtp(phone: phone);

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
          'This device has reached the limit of accounts it can register. '
          'Sign in with your existing account instead.',
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

  /// Stable per-install id used by the server's duplicate-account guard.
  Future<String> deviceIdentifier() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  Future<void> signOut() => _db.auth.signOut();
}
