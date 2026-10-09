// The rider ↔ driver chat of one ride (`ride_messages`, migration 0129): who
// is who, the quick replies each side is offered, the ticks, what is unread,
// how the thread is split into days and when it takes new messages. Pure.
import 'package:intl/intl.dart';

import '../data/models.dart';

/// Which side of the ride a message comes from (`ride_messages.sender_role`).
enum RideChatRole {
  rider,
  partner;

  static RideChatRole? parse(String? s) => switch (s) {
    'rider' => rider,
    'partner' => partner,
    _ => null,
  };
}

/// `ride_messages.type`. A quick reply is a canned line, still text in `body`.
enum RideMessageType {
  text,
  quick,
  location;

  static RideMessageType parse(String? s) => switch (s) {
    'quick' => quick,
    'location' => location,
    _ => text,
  };
}

/// `ride_messages.status`: one grey tick, two grey ticks, two coloured ticks.
/// Only ever moves forward.
enum RideMessageStatus {
  sent,
  delivered,
  read;

  static RideMessageStatus parse(String? s) => switch (s) {
    'delivered' => delivered,
    'read' => read,
    _ => sent,
  };

  String get label => switch (this) {
    sent => 'Sent',
    delivered => 'Delivered',
    read => 'Read',
  };
}

/// The longest message the database takes.
const rideMessageMaxLength = 1000;

class RideMessage {
  const RideMessage({
    required this.id,
    required this.requestId,
    required this.senderId,
    required this.senderRole,
    this.type = RideMessageType.text,
    this.body,
    this.latitude,
    this.longitude,
    this.status = RideMessageStatus.sent,
    this.createdAt,
  });

  final String id;
  final String requestId;
  final String senderId;
  final RideChatRole senderRole;
  final RideMessageType type;
  final String? body;
  final double? latitude;
  final double? longitude;
  final RideMessageStatus status;
  final DateTime? createdAt;

  /// Null for a row that isn't a message (no id, or a role this app doesn't
  /// know).
  static RideMessage? fromRow(Map<String, dynamic> r) {
    final id = r['id'] as String?;
    final role = RideChatRole.parse(r['sender_role'] as String?);
    if (id == null || role == null) return null;
    return RideMessage(
      id: id,
      requestId: (r['request_id'] as String?) ?? '',
      senderId: (r['sender_id'] as String?) ?? '',
      senderRole: role,
      type: RideMessageType.parse(r['type'] as String?),
      body: r['body'] as String?,
      latitude: (r['latitude'] as num?)?.toDouble(),
      longitude: (r['longitude'] as num?)?.toDouble(),
      status: RideMessageStatus.parse(r['status'] as String?),
      createdAt: DateTime.tryParse((r['created_at'] as String?) ?? ''),
    );
  }

  RideMessage copyWith({RideMessageStatus? status}) => RideMessage(
    id: id,
    requestId: requestId,
    senderId: senderId,
    senderRole: senderRole,
    type: type,
    body: body,
    latitude: latitude,
    longitude: longitude,
    status: status ?? this.status,
    createdAt: createdAt,
  );

  bool get hasLocation => type == RideMessageType.location && latitude != null && longitude != null;

  /// One line for a preview or a notification.
  String get summary => type == RideMessageType.location ? 'Shared a location' : (body ?? '').trim();
}

/// The side [userId] is on in [ride], or null when they're neither.
RideChatRole? rideChatRoleFor(RideRequest ride, String? userId) {
  if (userId == null || userId.isEmpty) return null;
  if (ride.partnerId == userId) return RideChatRole.partner;
  if (ride.riderId == userId) return RideChatRole.rider;
  return null;
}

/// The lines each side can send with one tap.
List<String> rideQuickReplies(RideChatRole role) => switch (role) {
  RideChatRole.rider => const ["I'm at the pickup point", 'Running 2 minutes late', 'Please call me', 'OK'],
  RideChatRole.partner => const ["I've arrived", "I'm on my way", 'Stuck in traffic, 5 minutes', 'OK'],
};

/// Whether the chat takes new messages: only while a driver is on the job
/// (the database refuses anything else). Before that there's nobody to
/// write to; after it the thread is history.
bool rideChatOpen(RideStatus status) =>
    status == RideStatus.accepted || status == RideStatus.arrived || status == RideStatus.onTrip;

/// Whether there is a chat to show at all: once a driver took the ride.
bool rideChatAvailable(RideRequest ride) => ride.partnerId != null && ride.status != RideStatus.open;

/// The text to send, trimmed, or null when there is nothing to send or it is
/// too long.
String? rideMessageText(String input) {
  final t = input.trim();
  if (t.isEmpty || t.length > rideMessageMaxLength) return null;
  return t;
}

/// The tick under a message: only the sender's own messages carry one.
RideMessageStatus? rideMessageTick(RideMessage m, String? userId) => m.senderId == userId ? m.status : null;

bool _incoming(RideMessage m, String? userId) => userId != null && m.senderId != userId;

/// Messages to [userId] they haven't read yet (the badge on Message).
int rideUnreadCount(Iterable<RideMessage> messages, String? userId) =>
    messages.where((m) => _incoming(m, userId) && m.status != RideMessageStatus.read).length;

/// Incoming messages that reached this device but are still 'sent'.
List<String> rideMessagesToDeliver(Iterable<RideMessage> messages, String? userId) => [
  for (final m in messages)
    if (_incoming(m, userId) && m.status == RideMessageStatus.sent) m.id,
];

/// Incoming messages not yet marked read (while the chat is open on screen).
List<String> rideMessagesToRead(Iterable<RideMessage> messages, String? userId) => [
  for (final m in messages)
    if (_incoming(m, userId) && m.status != RideMessageStatus.read) m.id,
];

/// Raises the status of [ids] in [messages] to [to], never lowering one
/// (what the screen shows before realtime brings the row back).
List<RideMessage> withRideMessageStatus(List<RideMessage> messages, Set<String> ids, RideMessageStatus to) => [
  for (final m in messages)
    if (ids.contains(m.id) && m.status.index < to.index) m.copyWith(status: to) else m,
];

/// The heading over a day's messages: Today, Yesterday, a weekday within the
/// week, else the date.
String rideChatDayLabel(DateTime day, DateTime now) {
  final d = DateTime(day.year, day.month, day.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(d).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff > 1 && diff < 7) return DateFormat('EEEE').format(d);
  return DateFormat(d.year == now.year ? 'd MMM' : 'd MMM yyyy').format(d);
}

/// One row of the thread: a day heading or a message.
sealed class RideChatItem {
  const RideChatItem();
}

class RideChatDay extends RideChatItem {
  const RideChatDay(this.label);
  final String label;
}

class RideChatEntry extends RideChatItem {
  const RideChatEntry(this.message);
  final RideMessage message;
}

/// [messages] oldest first, with a heading before each new local day. A
/// message without a time stays under the day before it.
List<RideChatItem> rideChatItems(List<RideMessage> messages, DateTime now) {
  final sorted = [...messages]
    ..sort((a, b) {
      final at = a.createdAt, bt = b.createdAt;
      if (at == null || bt == null) return 0;
      return at.compareTo(bt);
    });
  final out = <RideChatItem>[];
  String? last;
  for (final m in sorted) {
    final at = m.createdAt?.toLocal();
    if (at != null) {
      final label = rideChatDayLabel(at, now);
      if (label != last) {
        out.add(RideChatDay(label));
        last = label;
      }
    }
    out.add(RideChatEntry(m));
  }
  return out;
}

/// Where a shared location opens: the maps app (or site) at that point.
Uri rideLocationUri(double lat, double lng) =>
    Uri.parse('https://www.google.com/maps/search/?api=1&query=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}');
