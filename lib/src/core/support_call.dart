// Support calls with audio (migration 0105): the rows, and the rules both
// ends of a call follow. Pure and tested in test/support_call_test.dart.
//
// A call is a `support_calls` row. Either side can ring: an agent rings a
// user from their ticket (caller_role 'admin'), or a user rings support
// (caller_role 'user') and whichever agent answers first takes it. The voice
// itself goes peer to peer over WebRTC; `support_call_signals` carries the
// setup between the two people on the call.
//
// The engine (CallSession) is not tied to support calls: rider ↔ driver
// calls (lib/src/core/ride_call.dart, migration 0131) run on it too, through
// [CallRecord] and [CallSignalling].

enum CallStatus {
  ringing,
  accepted,
  declined,
  ended,
  missed,

  /// The caller hung up before it was answered (ride calls only; a support
  /// call given up on is `ended`).
  cancelled;

  static CallStatus parse(Object? raw) =>
      CallStatus.values.firstWhere((s) => s.name == '$raw', orElse: () => CallStatus.ended);

  bool get isOver => this == declined || this == ended || this == missed || this == cancelled;
}

/// One call as the engine sees it, whichever table it lives in.
abstract interface class CallRecord<C extends CallRecord<C>> {
  String get id;
  CallStatus get status;
  DateTime? get createdAt;

  /// When it was answered.
  DateTime? get startedAt;

  /// Whether [uid] started this call (and so sends the WebRTC offer).
  bool startedBy(String? uid);

  /// This call with its status moved to [status] (shown before the database
  /// confirms it).
  C withStatus(CallStatus status);

  /// What hanging up on this end records.
  CallStatus hangUpStatus({required bool outgoing});
}

/// What the engine needs from where a kind of call is kept: its row, its
/// signals, hanging up, and the ICE servers.
abstract interface class CallSignalling<C extends CallRecord<C>> {
  Stream<C> watch(String callId);
  Stream<CallSignal> watchSignals(String callId);
  Future<void> sendSignal(String callId, String kind, Map<String, dynamic> payload);
  Future<void> finish(String callId, CallStatus status);
  Future<List<Map<String, dynamic>>> iceServers();
}

/// How long a call rings before the caller gives up on it (Expo's call
/// screen let it ring indefinitely; a phone stops after about this long).
const callRingTimeout = Duration(seconds: 45);

/// How long an answered call may take to get audio flowing before it is
/// given up as unable to connect (a network that blocks it, or an app at
/// the other end with no audio, such as Expo's call screen).
const callConnectTimeout = Duration(seconds: 30);

class SupportCall implements CallRecord<SupportCall> {
  SupportCall(this.raw);
  final Map<String, dynamic> raw;

  @override
  String get id => '${raw['id']}';
  String? get ticketId => raw['ticket_id'] as String?;

  /// The user the call is about.
  String get profileId => '${raw['profile_id']}';

  /// True when the user rang support; false when an agent rang the user.
  bool get fromUser => raw['caller_role'] == 'user';
  String? get callerId => raw['caller_id'] as String?;
  String? get callerName => _text(raw['caller_name']);
  String? get answeredBy => raw['answered_by'] as String?;
  String? get answeredByName => _text(raw['answered_by_name']);
  @override
  CallStatus get status => CallStatus.parse(raw['status']);
  @override
  DateTime? get startedAt => _time(raw['started_at']);
  @override
  DateTime? get createdAt => _time(raw['created_at']);

  @override
  bool startedBy(String? uid) =>
      uid != null && (callerId == uid || (callerId == null && !fromUser && uid != profileId));

  /// Whether [uid] is one of the two people on the call.
  bool involves(String? uid) => uid != null && (uid == profileId || uid == callerId || uid == answeredBy);

  @override
  SupportCall withStatus(CallStatus status) => SupportCall({...raw, 'status': status.name});

  /// An unanswered incoming call is declined, anything else ended.
  @override
  CallStatus hangUpStatus({required bool outgoing}) =>
      status == CallStatus.ringing && !outgoing ? CallStatus.declined : CallStatus.ended;

  static String? _text(Object? v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }

  static DateTime? _time(Object? v) => v == null ? null : DateTime.tryParse('$v');
}

/// Whether a ringing call has rung out by [now].
bool rangOut(CallRecord c, DateTime now) {
  final at = c.createdAt;
  return c.status == CallStatus.ringing && at != null && now.difference(at) >= callRingTimeout;
}

/// Who the person on this end is talking to. An agent sees the caller's
/// name; a user sees the agent who answered, or "Support".
String callPeerName(SupportCall c, {required bool asAgent, String? userName}) {
  if (asAgent) return (c.fromUser ? c.callerName : null) ?? userName ?? 'Customer';
  return (c.fromUser ? c.answeredByName : c.callerName) ?? 'Support';
}

/// m:ss, then h:mm:ss.
String formatCallDuration(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// What the call screen says under the name. [connected] is the audio
/// actually flowing, which lags the row turning `accepted`.
String callHeadline(
  CallStatus status, {
  required bool outgoing,
  required bool connected,
  Duration elapsed = Duration.zero,
}) => switch (status) {
  CallStatus.ringing => outgoing ? 'Calling…' : 'Incoming call',
  CallStatus.accepted => connected ? formatCallDuration(elapsed) : 'Connecting…',
  CallStatus.declined => outgoing ? 'Call declined' : 'Call ended',
  CallStatus.missed => outgoing ? 'No answer' : 'Missed call',
  CallStatus.ended => 'Call ended',
  CallStatus.cancelled => outgoing ? 'Call cancelled' : 'Missed call',
};

/// The ICE servers turn-credentials answered, shaped for WebRTC; Google's
/// public STUN when it answered nothing usable (calls then connect wherever
/// a direct connection does).
List<Map<String, dynamic>> parseIceServers(Object? body) {
  final list = body is Map ? body['iceServers'] : null;
  final out = <Map<String, dynamic>>[];
  if (list is List) {
    for (final e in list) {
      if (e is! Map) continue;
      final urls = e['urls'];
      final u = urls is String
          ? [urls]
          : urls is List
          ? [for (final x in urls) '$x']
          : const <String>[];
      if (u.isEmpty) continue;
      out.add({
        'urls': u,
        if (e['username'] != null) 'username': '${e['username']}',
        if (e['credential'] != null) 'credential': '${e['credential']}',
      });
    }
  }
  return out.isEmpty
      ? [
          {
            'urls': ['stun:stun.l.google.com:19302'],
          },
        ]
      : out;
}

/// One WebRTC setup message between the two people on a call.
class CallSignal {
  const CallSignal({required this.id, required this.sender, required this.kind, required this.payload});

  factory CallSignal.fromRow(Map<String, dynamic> r) => CallSignal(
    id: (r['id'] as num).toInt(),
    sender: '${r['sender']}',
    kind: '${r['kind']}',
    payload: (r['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
  );

  final int id;
  final String sender;

  /// offer, answer, ice or bye.
  final String kind;
  final Map<String, dynamic> payload;
}
