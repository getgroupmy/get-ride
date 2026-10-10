import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/call_ring.dart';
import '../core/push_logic.dart';

/// The phone's own incoming-call screen for ride calls (migration 0134):
/// CallKit on an iPhone, flutter_callkit_incoming's full-screen call on
/// Android. Rings with the system ringtone over the lock screen, and reports
/// what was pressed as [actions].
///
/// Only Android and iOS have one; elsewhere (web, desktop) [available] is
/// false and the in-app incoming-call screen rings instead.
abstract class CallRinger {
  bool get available;

  /// Rings [ring] on the phone's call screen. False when it couldn't.
  Future<bool> ring(CallRing ring);

  /// Stops ringing (or ends the phone's record of) [callId].
  Future<void> stop(String callId);

  /// Tells the phone the answered call is connected (its timer starts).
  Future<void> connected(String callId);

  /// Presses on the phone's call screen: (what, call id).
  Stream<(RingAction, String)> get actions;

  /// Calls already accepted on the phone's screen before the app was
  /// listening (a closed app is opened by Accept).
  Future<List<String>> acceptedCalls();

  /// The iPhone's PushKit (VoIP) token, for push_register_device.
  Future<String?> voipToken();
}

final callRingerProvider = Provider<CallRinger>(
  (ref) => nativeCallRingerAvailable ? NativeCallRinger() : NoCallRinger(),
);

/// Whether this platform has a call screen the app can ring.
bool get nativeCallRingerAvailable =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

class NoCallRinger implements CallRinger {
  @override
  bool get available => false;
  @override
  Future<bool> ring(CallRing ring) async => false;
  @override
  Future<void> stop(String callId) async {}
  @override
  Future<void> connected(String callId) async {}
  @override
  Stream<(RingAction, String)> get actions => const Stream.empty();
  @override
  Future<List<String>> acceptedCalls() async => const [];
  @override
  Future<String?> voipToken() async => null;
}

/// The plugin's parameters for [ring]: no video, no hold or keypad, the
/// system ringtone, and the call's own id so every later step finds it.
CallKitParams callKitParams(CallRing ring) => CallKitParams(
  id: ring.callId,
  nameCaller: ring.callerName,
  appName: 'GET.ride',
  handle: 'Ride call',
  type: 0,
  duration: ring.ringMillis,
  extra: ring.extra,
  missedCallNotification: const NotificationParams(
    showNotification: true,
    isShowCallback: false,
    subtitle: 'Missed call about your ride',
  ),
  android: const AndroidParams(
    isCustomNotification: true,
    isShowLogo: false,
    ringtonePath: 'system_ringtone_default',
    backgroundColor: '#1F2937',
    actionColor: '#22C55E',
    textColor: '#FFFFFF',
    incomingCallNotificationChannelName: 'Ride calls',
    missedCallNotificationChannelName: 'Missed ride calls',
    isShowFullLockedScreen: true,
    isImportant: true,
    textAccept: 'Accept',
    textDecline: 'Decline',
  ),
  ios: const IOSParams(
    handleType: 'generic',
    supportsVideo: false,
    maximumCallGroups: 1,
    maximumCallsPerCallGroup: 1,
    supportsDTMF: false,
    supportsHolding: false,
    supportsGrouping: false,
    supportsUngrouping: false,
    includesCallsInRecents: false,
    ringtonePath: 'system_ringtone_default',
    configureAudioSession: true,
  ),
);

/// What the plugin reported, as (action, call id); null for anything the app
/// doesn't act on.
(RingAction, String)? ringActionFor(CallEvent? event) {
  (RingAction, String)? of(RingAction a, CallKitParams p) {
    final id = callIdFromExtra(p.extra, fallbackId: p.id);
    return id == null ? null : (a, id);
  }

  return switch (event) {
    CallEventActionCallAccept(:final callKitParams) => of(RingAction.accept, callKitParams),
    CallEventActionCallDecline(:final callKitParams) => of(RingAction.decline, callKitParams),
    CallEventActionCallEnded(:final callKitParams) => of(RingAction.end, callKitParams),
    CallEventActionCallTimeout(:final id) => (RingAction.timeout, id),
    _ => null,
  };
}

class NativeCallRinger implements CallRinger {
  @override
  bool get available => true;

  @override
  Future<bool> ring(CallRing ring) async {
    try {
      await FlutterCallkitIncoming.showCallkitIncoming(callKitParams(ring));
      return true;
    } catch (e) {
      debugPrint('[call] could not ring: $e');
      return false;
    }
  }

  @override
  Future<void> stop(String callId) async {
    try {
      await FlutterCallkitIncoming.endCall(callId);
    } catch (e) {
      debugPrint('[call] could not stop ringing: $e');
    }
  }

  @override
  Future<void> connected(String callId) async {
    try {
      await FlutterCallkitIncoming.setCallConnected(callId);
    } catch (_) {}
  }

  @override
  Stream<(RingAction, String)> get actions =>
      FlutterCallkitIncoming.onEvent.map(ringActionFor).where((a) => a != null).cast<(RingAction, String)>();

  @override
  Future<List<String>> acceptedCalls() async {
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      return [
        for (final c in calls)
          if (c.isAccepted) ?callIdFromExtra(c.extra, fallbackId: c.id),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<String?> voipToken() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return null;
    try {
      final token = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
      return token == null || token.trim().isEmpty ? null : token.trim();
    } catch (_) {
      return null;
    }
  }
}

/// Firebase's handler for a push that reaches the app while it is in the
/// background or closed (Android). Runs in its own isolate, with nothing of
/// the app started: a ride call rings the phone's call screen, and a call
/// that stopped ringing stops it (with a missed-call notification if it was
/// still ringing). Everything else was a notification the OS already showed.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundPush(RemoteMessage message) async {
  final data = message.data;
  final ring = callRingFromPush(data);
  final ended = endedCallFromPush(data);
  if (ring == null && ended == null) return;
  try {
    if (Firebase.apps.isEmpty) {
      final options = firebaseOptionsFor(defaultTargetPlatform, const FirebaseEnv.fromEnvironment(), isWeb: kIsWeb);
      if (options != null) await Firebase.initializeApp(options: options);
    }
  } catch (_) {}
  if (ring != null) {
    await NativeCallRinger().ring(ring);
    return;
  }
  try {
    final active = await FlutterCallkitIncoming.activeCalls();
    final ringing = active.where((c) => callIdFromExtra(c.extra, fallbackId: c.id) == ended && !c.isAccepted);
    if (ringing.isEmpty) return;
    await FlutterCallkitIncoming.endCall(ended!);
    await FlutterCallkitIncoming.showMissCallNotification(ringing.first);
  } catch (e) {
    debugPrint('[call] could not stop ringing: $e');
  }
}
