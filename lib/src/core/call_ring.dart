// A ride call (migration 0131) ringing like a phone call: the phone's own
// incoming-call screen (CallKit on iPhone, a full-screen call on Android)
// instead of a notification, even when the app is closed (migration 0134).
// What rings, and what the call screen's buttons mean, is decided here; the
// plugin is driven by lib/src/data/call_ringer.dart. Pure and tested in
// test/call_ring_test.dart.
library;

import 'ride_call.dart';
import 'support_call.dart' show CallStatus, callRingTimeout;

/// The capability a build registers its push token with when it shows the
/// phone's call screen (`push_tokens.capabilities`, migration 0134).
const callUiCapability = 'call_ui';

/// `push_tokens.platform` of an iPhone's PushKit (VoIP) token.
const voipPlatform = 'ios_voip';

/// One ride call to ring: the call's id is the call screen's id (CallKit
/// needs a UUID, and `ride_calls.id` is one).
class CallRing {
  const CallRing({required this.callId, required this.requestId, required this.callerName, this.role, this.ringFor});

  final String callId;
  final String requestId;
  final String callerName;

  /// The callee's side of the ride ('rider' or 'partner'), for the screen a
  /// tap opens.
  final String? role;

  /// How much longer it should ring; null is the full [callRingTimeout].
  final Duration? ringFor;

  /// What the call screen hands back when it is answered or turned down.
  Map<String, dynamic> get extra => {
    'type': 'ride_call',
    'call_id': callId,
    'request_id': requestId,
    'caller_name': callerName,
    if (role != null) 'role': role,
  };

  /// How long to ring, in milliseconds: what is left of the call's 45
  /// seconds, at least a moment.
  int get ringMillis {
    final left = ringFor ?? callRingTimeout;
    return left.inMilliseconds.clamp(1000, callRingTimeout.inMilliseconds);
  }

  @override
  bool operator ==(Object other) =>
      other is CallRing &&
      other.callId == callId &&
      other.requestId == requestId &&
      other.callerName == callerName &&
      other.role == role &&
      other.ringFor == ringFor;

  @override
  int get hashCode => Object.hash(callId, requestId, callerName, role, ringFor);

  @override
  String toString() => 'CallRing($callId, $callerName)';
}

String? _str(Object? v) {
  final s = v is String ? v.trim() : null;
  return s == null || s.isEmpty ? null : s;
}

/// "Aina is calling" → "Aina".
String _nameFromTitle(String? title) {
  final name = (title ?? '').replaceFirst(RegExp(r'\s+is calling\s*$', caseSensitive: false), '').trim();
  return name.isEmpty ? 'GET.ride' : name;
}

/// The call a `ride_call` push rings, or null when [data] is something else.
/// The caller's name is in the data (0134) or, from an older server, only in
/// the title.
CallRing? callRingFromPush(Map<String, dynamic> data) {
  if (data['type'] != 'ride_call') return null;
  final call = _str(data['call_id']);
  final ride = _str(data['request_id']);
  if (call == null || ride == null) return null;
  return CallRing(
    callId: call,
    requestId: ride,
    callerName: _str(data['caller_name']) ?? _nameFromTitle(_str(data['title'])),
    role: _str(data['role']),
  );
}

/// The call a `ride_call_end` push says stopped ringing, or null.
String? endedCallFromPush(Map<String, dynamic> data) => data['type'] == 'ride_call_end' ? _str(data['call_id']) : null;

/// The call [me] is being rung for, seen on the `ride_calls` row while the
/// app is open; null when it is not ringing them (any more). Rings for what
/// is left of its 45 seconds.
CallRing? callRingFromCall(RideCall call, String? me, DateTime now) {
  if (!canAnswerRideCall(call, me, now)) return null;
  final created = call.createdAt;
  return CallRing(
    callId: call.id,
    requestId: call.requestId,
    callerName: call.callerName ?? 'GET.ride',
    role: switch (call.callerRole?.name) {
      'rider' => 'partner',
      'partner' => 'rider',
      _ => null,
    },
    ringFor: created == null ? null : callRingTimeout - now.difference(created),
  );
}

/// The call id in what the call screen hands back ([CallRing.extra], or the
/// plugin's own id).
String? callIdFromExtra(Map<dynamic, dynamic>? extra, {String? fallbackId}) =>
    _str(extra?['call_id']) ?? _str(fallbackId);

/// The in-app call screen, answering as it opens when [answer] (the phone's
/// own Accept was pressed).
String rideCallRoute(String callId, {bool answer = false}) =>
    '/ride-call/${Uri.encodeComponent(callId)}${answer ? '?answer=1' : ''}';

/// What a press on the phone's call screen means for the call.
enum RingAction {
  /// Accept: open the call and answer it.
  accept,

  /// Decline: turn the call down.
  decline,

  /// The phone's End on a call in progress (iPhone lock screen): hang up.
  end,

  /// It rang out on the phone: nothing to do, the caller's end records it.
  timeout,
}

/// Whether the phone's call screen should stop for a call now [status].
bool ringShouldStop(CallStatus status) => status != CallStatus.ringing;
