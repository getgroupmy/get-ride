// One device per account, on the phone's side (migration 0180), and the
// admin's sign-in switches (0179).
//
// The server does the enforcing: a session that is not the account's
// recorded one is refused on every API call. This file makes the phone
// behave well around that:
//   * claims the session after every sign-in (newest wins), and on launch
//     only when nothing is recorded yet (never stealing the account back);
//   * notices it was replaced — live from its own `active_sessions` row,
//     and by asking on resume and every few minutes — and signs out here
//     with a sentence saying why, instead of failing call after call.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/installed_app.dart';
import '../core/sign_in_security.dart';
import '../providers.dart';
import 'live_tables.dart';
import 'meter_session_store.dart';

/// The admin's switches; all off when they can't be read (an older
/// database, no signal), so nothing is offered that might not work.
final signInConfigProvider = FutureProvider<SignInConfig>((ref) async {
  // The admin's change applies live, like every other setting.
  ref.watchLive('app_settings');
  try {
    return SignInConfig.fromJson(await ref.watch(supabaseProvider).rpc('sign_in_config'));
  } catch (_) {
    return SignInConfig.off;
  }
});

/// Set when this device was signed out because the account signed in on
/// another one; the sign-in screen says so and clears it.
final signedOutElsewhere = ValueNotifier<bool>(false);

/// How many devices the account may use at once, as its last claim said
/// (0298); worded into the sign-out note.
final signedOutAllowance = ValueNotifier<int>(1);

/// How often an open app checks it is still the account's device, beside
/// the live row and every resume.
const sessionCheckEvery = Duration(minutes: 3);

class SessionGuard {
  SessionGuard(this._db, {required this.deviceId, this.label, this.platform});

  final SupabaseClient _db;
  final Future<String> Function() deviceId;
  final String? label;
  final String? platform;

  RealtimeChannel? _channel;
  bool _signingOut = false;

  /// Records this session as the account's one. After a sign-in: always
  /// ([onlyIfUnclaimed] false). On launch: only when nothing is recorded,
  /// so accounts already open on two phones when the admin turns it on
  /// settle on one. Best effort: a database without 0180 does nothing.
  Future<void> claim({bool onlyIfUnclaimed = false}) async {
    if (_db.auth.currentSession == null) return;
    try {
      final r = await _db.rpc(
        'claim_session',
        params: {
          'p_device_id': await deviceId(),
          'p_label': label,
          'p_platform': platform,
          'p_app_version': InstalledApp.version,
          'p_only_if_unclaimed': onlyIfUnclaimed,
        },
      );
      if (r is Map && r['allowed'] is num) signedOutAllowance.value = (r['allowed'] as num).toInt();
      // Opened after another device signed in: signed out here at once.
      if (r is Map && r['current'] == false) await signOutHere();
    } catch (e) {
      if (isSignedInElsewhere(e)) await signOutHere();
    }
  }

  /// Asks the server whether this is still the account's session; signs
  /// out here when it isn't. No signal, or a database without 0180,
  /// changes nothing.
  Future<void> check() async {
    if (_db.auth.currentSession == null) return;
    try {
      if (await _db.rpc('session_is_current') == false) await signOutHere();
    } catch (e) {
      if (isSignedInElsewhere(e)) await signOutHere();
    }
  }

  /// Watches the account's own row: a newer sign-in elsewhere replaces its
  /// session id, and this device signs out at once.
  void watch(String userId) {
    unwatch();
    try {
      _channel = _db
          .channel('active-session-$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'active_sessions',
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: userId),
            callback: (payload) {
              final mine = sessionIdOf(_db.auth.currentSession?.accessToken);
              if (replacedBy(payload.newRecord, mine)) unawaited(signOutHere());
            },
          )
          .subscribe();
    } catch (_) {
      _channel = null;
    }
  }

  void unwatch() {
    final c = _channel;
    _channel = null;
    if (c != null) unawaited(_db.removeChannel(c));
  }

  /// Signs out on this device only (the session is already gone on the
  /// server) and leaves the reason for the sign-in screen.
  Future<void> signOutHere() async {
    if (_signingOut || _db.auth.currentSession == null) return;
    _signingOut = true;
    signedOutElsewhere.value = true;
    unwatch();
    await MeterSessionStore.clear();
    try {
      await _db.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
    } finally {
      _signingOut = false;
    }
  }
}

/// A short name for this device for the admin's Users page.
String thisDeviceLabel() {
  if (kIsWeb) return 'Web browser';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android phone',
    TargetPlatform.iOS => 'iPhone',
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.windows => 'Windows PC',
    _ => 'Device',
  };
}

String thisDevicePlatform() => kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase();
