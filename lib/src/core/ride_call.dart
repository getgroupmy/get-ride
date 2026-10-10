// In-app voice calls between a rider and their driver (`ride_calls`,
// migration 0131): the row, its statuses, who may do what, and what each end
// is shown. Pure and tested in test/ride_call_test.dart.
//
// A ride call runs on the support-call engine (CallSession over WebRTC); it
// only differs in where it lives and in its rules: the two people on it are
// the ride's rider and driver, it rings only while the ride is in progress,
// the callee answers or declines, the caller cancels, and either ends it.
import '../data/models.dart';
import 'ride_chat.dart';
import 'support_call.dart';

/// `ride_calls.status` for [s]: the database says 'answered' where the
/// engine says accepted.
String rideCallStatusName(CallStatus s) => s == CallStatus.accepted ? 'answered' : s.name;

/// [raw] (`ride_calls.status`) as the engine's status; unknown as ended.
CallStatus parseRideCallStatus(Object? raw) => '$raw' == 'answered' ? CallStatus.accepted : CallStatus.parse(raw);

class RideCall implements CallRecord<RideCall> {
  RideCall(this.raw);
  final Map<String, dynamic> raw;

  @override
  String get id => '${raw['id']}';
  String get requestId => '${raw['request_id']}';
  String? get callerId => raw['caller_id'] as String?;
  String? get calleeId => raw['callee_id'] as String?;

  /// Which side of the ride rang.
  RideChatRole? get callerRole => RideChatRole.parse(raw['caller_role'] as String?);
  String? get callerName => _text(raw['caller_name']);
  String? get calleeName => _text(raw['callee_name']);

  @override
  CallStatus get status => parseRideCallStatus(raw['status']);
  @override
  DateTime? get createdAt => _time(raw['created_at']);
  @override
  DateTime? get startedAt => _time(raw['answered_at']);

  @override
  bool startedBy(String? uid) => uid != null && uid == callerId;

  /// Whether [uid] is one of the two people on the call.
  bool involves(String? uid) => uid != null && (uid == callerId || uid == calleeId);

  @override
  RideCall withStatus(CallStatus status) => RideCall({...raw, 'status': rideCallStatusName(status)});

  /// The caller hanging up before an answer cancels; the callee declines;
  /// once answered, either ends it.
  @override
  CallStatus hangUpStatus({required bool outgoing}) =>
      status == CallStatus.ringing ? (outgoing ? CallStatus.cancelled : CallStatus.declined) : CallStatus.ended;

  static String? _text(Object? v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }

  static DateTime? _time(Object? v) => v == null ? null : DateTime.tryParse('$v');
}

/// Whether the two people on [ride] can call each other in the app: a
/// driver is on the job (the database refuses a call otherwise).
bool rideCallsAvailable(RideRequest ride) =>
    ride.riderId != null && ride.partnerId != null && ride.riderId != ride.partnerId && rideChatOpen(ride.status);

/// Whether the driver's Call goes straight to the passenger's phone: on a
/// ride booked for someone else, the person waiting at the pickup is the
/// passenger, and the in-app call would ring the booker's account instead.
bool callsPassengerDirectly(RideRequest ride, String? me) =>
    ride.isForOthers && me != null && me == ride.partnerId;

/// Whether a call on a ride now at [status] has to end: the ride is over,
/// or went back to looking for a driver.
bool rideCallMustEnd(RideStatus status) => !rideChatOpen(status);

/// Whether [uid] can answer or decline [call] at [now]: they are the one
/// being called, and it is still ringing.
bool canAnswerRideCall(RideCall call, String? uid, DateTime now) =>
    uid != null && uid == call.calleeId && call.status == CallStatus.ringing && !rangOut(call, now);

/// Whether [uid] can cancel [call]: they rang, and nobody has answered.
bool canCancelRideCall(RideCall call, String? uid) => call.startedBy(uid) && call.status == CallStatus.ringing;

/// Whether [uid] can end [call]: either of the two, once it is answered.
bool canEndRideCall(RideCall call, String? uid) => call.involves(uid) && call.status == CallStatus.accepted;

/// The other person on [call], as [me] sees them.
String rideCallPeerName(RideCall call, String? me) {
  final outgoing = call.startedBy(me);
  final name = outgoing ? call.calleeName : call.callerName;
  if (name != null) return name;
  // The side the other person is on.
  final peerIsDriver = outgoing ? call.callerRole == RideChatRole.rider : call.callerRole == RideChatRole.partner;
  return peerIsDriver ? 'Your driver' : 'Your passenger';
}

/// The line under the name: which side of the ride they are and where the
/// ride goes, so a call is never mistaken for any other.
String rideCallContext(RideCall call, String? me, {RideRequest? ride}) {
  final outgoing = call.startedBy(me);
  final peerIsDriver = outgoing ? call.callerRole == RideChatRole.rider : call.callerRole == RideChatRole.partner;
  final who = peerIsDriver ? 'Your driver' : 'Your passenger';
  final plate = peerIsDriver ? ride?.partnerPlate : null;
  final to = ride?.dropLabel.trim() ?? '';
  return [
    if (plate != null && plate.trim().isNotEmpty) '$who · ${plate.trim()}' else who,
    if (to.isNotEmpty) 'Ride to $to',
  ].join('\n');
}

/// Where the call screen goes back to once a call is over and there is no
/// screen under it: the ride, from the side [me] is on.
String rideCallHome(RideCall call, String? me) {
  final callerIsDriver = call.callerRole == RideChatRole.partner;
  final iAmDriver = call.startedBy(me) ? callerIsDriver : !callerIsDriver;
  final ride = Uri.encodeComponent(call.requestId);
  return iAmDriver ? '/drive/trip/$ride' : '/ride/$ride';
}

/// What to tell someone whose call could not be placed, from what the
/// database said.
String rideCallFailure(Object error) {
  final s = '$error';
  if (s.contains('23505') || s.contains('ride_calls_one_live_idx')) return 'There is already a call on this ride.';
  if (s.contains('RIDE_CALL_NOT_ALLOWED') || s.contains('42501')) return 'Calls are only available during the ride.';
  return "Couldn't place the call. Check your connection and try again.";
}
