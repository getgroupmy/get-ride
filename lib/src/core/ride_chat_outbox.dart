// Chat messages written with no connection (reliability Phase C): kept on
// the phone under the id they will be stored with (`client_msg_id`,
// migration 0146) and sent when the connection is back, so a message is
// never lost and never stored twice. Pure.
import 'ride_chat.dart';

/// A message waiting to reach the server. Only text, quick replies and
/// locations are queued; a photo or voice note needs its upload first.
class PendingRideMessage {
  const PendingRideMessage({
    required this.clientMsgId,
    required this.requestId,
    required this.senderId,
    required this.role,
    required this.type,
    this.body,
    this.latitude,
    this.longitude,
    required this.createdAt,
  });

  final String clientMsgId;
  final String requestId;
  final String senderId;
  final RideChatRole role;
  final RideMessageType type;
  final String? body;
  final double? latitude;
  final double? longitude;
  final DateTime createdAt;

  /// The row to insert (the server stamps the rest).
  Map<String, dynamic> toRow() => {
    'request_id': requestId,
    'sender_role': role.name,
    'type': type.name,
    'client_msg_id': clientMsgId,
    if (body != null) 'body': body,
    if (latitude != null) 'latitude': latitude,
    if (longitude != null) 'longitude': longitude,
  };

  Map<String, dynamic> toJson() => {
    'client_msg_id': clientMsgId,
    'request_id': requestId,
    'sender_id': senderId,
    'role': role.name,
    'type': type.name,
    'body': body,
    'latitude': latitude,
    'longitude': longitude,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  /// Null for a stored entry this build can't read.
  static PendingRideMessage? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['client_msg_id'], request = j['request_id'], sender = j['sender_id'];
    final role = RideChatRole.parse(j['role'] as String?);
    final at = DateTime.tryParse('${j['created_at'] ?? ''}');
    if (id is! String || request is! String || sender is! String || role == null || at == null) return null;
    final type = RideMessageType.parse(j['type'] as String?);
    if (!queueableRideMessageTypes.contains(type)) return null;
    return PendingRideMessage(
      clientMsgId: id,
      requestId: request,
      senderId: sender,
      role: role,
      type: type,
      body: j['body'] as String?,
      latitude: (j['latitude'] as num?)?.toDouble(),
      longitude: (j['longitude'] as num?)?.toDouble(),
      createdAt: at.toLocal(),
    );
  }

  /// How it shows in the thread until the server has it.
  RideMessage toMessage() => RideMessage(
    id: 'pending-$clientMsgId',
    requestId: requestId,
    senderId: senderId,
    senderRole: role,
    type: type,
    body: body,
    latitude: latitude,
    longitude: longitude,
    createdAt: createdAt,
    clientMsgId: clientMsgId,
    pending: true,
  );
}

/// The kinds a message may be queued as.
const queueableRideMessageTypes = {RideMessageType.text, RideMessageType.quick, RideMessageType.location};

/// A queued message older than this is given up on: the ride has most
/// likely moved on, and a "I'm at the gate" from an hour ago only confuses.
const rideOutboxMaxAge = Duration(minutes: 30);

/// How often an open chat tries its queue again.
const rideOutboxRetryEvery = Duration(seconds: 15);

/// The thread as the screen shows it: what the server has, then what is
/// still waiting, minus anything the server already has (same id).
List<RideMessage> withPendingMessages(List<RideMessage> sent, Iterable<PendingRideMessage> pending, String requestId) {
  final onServer = {for (final m in sent) ?m.clientMsgId};
  return [
    ...sent,
    for (final p in pending)
      if (p.requestId == requestId && !onServer.contains(p.clientMsgId)) p.toMessage(),
  ];
}

/// The queue without what the server already has, and without what is
/// too old to send.
List<PendingRideMessage> prunePending(
  List<PendingRideMessage> pending, {
  required Set<String> onServer,
  required DateTime now,
}) => [
  for (final p in pending)
    if (!onServer.contains(p.clientMsgId) && now.difference(p.createdAt) < rideOutboxMaxAge) p,
];
