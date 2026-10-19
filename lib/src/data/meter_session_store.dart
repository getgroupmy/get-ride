import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The driver's "meter on or off" for one sign-in (Meter at sign-in,
/// migration 0243), kept on the device. A sign-in is the account and when it
/// signed in (`meterLaunchSessionProvider`), so the answer from an earlier
/// sign-in, or another account's, never carries over. Cleared on sign-out.
class MeterSessionStore {
  static const key = 'meter_session_choice_v1';

  /// This sign-in's answer: true on, false off, null not chosen yet.
  Future<bool?> read(String session) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      if (raw == null) return null;
      final m = jsonDecode(raw);
      if (m is! Map || m['session'] != session) return null;
      final on = m['on'];
      return on is bool ? on : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String session, bool on) async {
    try {
      final user = session.split('|').first;
      await (await SharedPreferences.getInstance()).setString(
        key,
        jsonEncode({'user': user, 'session': session, 'on': on}),
      );
    } catch (_) {}
  }

  /// Forgets the answer: signing out ends the sign-in it was for.
  static Future<void> clear() async {
    try {
      await (await SharedPreferences.getInstance()).remove(key);
    } catch (_) {}
  }
}
