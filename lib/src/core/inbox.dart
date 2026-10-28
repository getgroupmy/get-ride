/// The notifications page (side menu -> Notifications): what an account was
/// sent, kept server-side in `user_notifications` (migration 0167). Pure:
/// the screen only draws the result.
library;

import 'push_logic.dart';

/// One kept notification.
class InboxItem {
  const InboxItem({
    required this.id,
    required this.title,
    required this.body,
    required this.data,
    required this.createdAt,
    this.kind,
    this.mode,
    this.readAt,
  });

  factory InboxItem.fromRow(Map<String, dynamic> row) => InboxItem(
    id: row['id'] as String,
    title: (row['title'] as String?) ?? '',
    body: (row['body'] as String?) ?? '',
    data: row['data'] is Map ? Map<String, dynamic>.from(row['data'] as Map) : const {},
    kind: row['kind'] as String?,
    mode: row['mode'] as String?,
    createdAt: DateTime.tryParse('${row['created_at']}')?.toLocal() ?? DateTime.now(),
    readAt: row['read_at'] == null ? null : DateTime.tryParse('${row['read_at']}')?.toLocal(),
  );

  final String id;
  final String title;
  final String body;
  final Map<String, dynamic> data;

  /// The push's `type` (ride_status, wallet_transfer_request…); null for an
  /// admin broadcast.
  final String? kind;

  /// 'rider' or 'partner' when it belongs to one mode; null when it is the
  /// account's own business, shown in either.
  final String? mode;
  final DateTime createdAt;
  final DateTime? readAt;

  bool get unread => readAt == null;

  /// Where tapping it goes, as tapping the push would (pushRouteFor).
  String? get route => pushRouteFor({...data, if (kind != null && data['type'] == null) 'type': kind});

  InboxItem markedRead(DateTime at) => InboxItem(
    id: id,
    title: title,
    body: body,
    data: data,
    kind: kind,
    mode: mode,
    createdAt: createdAt,
    readAt: readAt ?? at,
  );
}

/// The items the page shows in [mode] ('rider' / 'partner'): that mode's and
/// the account's own, newest first. With no mode known, all of them.
List<InboxItem> inboxFor(Iterable<InboxItem> items, String? mode) {
  final out = [
    for (final i in items)
      if (mode == null || i.mode == null || i.mode == mode) i,
  ];
  out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return out;
}

/// Rows on the page: notifications repeated word for word about the same
/// trip (a status push sent again) fold into one row with a count. Display
/// only: each kept notification stays as it is.
class InboxGroup {
  const InboxGroup(this.items);

  /// Newest first; never empty.
  final List<InboxItem> items;

  InboxItem get latest => items.first;
  int get count => items.length;
  bool get unread => items.any((i) => i.unread);
  List<String> get ids => [for (final i in items) i.id];
  List<String> get unreadIds => [for (final i in items) if (i.unread) i.id];
}

/// [items] (newest first) as rows: those with the same trip
/// (`request_id`), title and text together, at the newest one's place.
/// One without a trip is a row of its own.
List<InboxGroup> groupInbox(List<InboxItem> items) {
  final groups = <String, List<InboxItem>>{};
  final order = <String>[];
  for (final i in items) {
    final trip = '${i.data['request_id'] ?? ''}'.trim();
    final key = trip.isEmpty ? 'id:${i.id}' : 'trip:$trip\u0000${i.kind}\u0000${i.title.trim()}\u0000${i.body.trim()}';
    final list = groups.putIfAbsent(key, () {
      order.add(key);
      return [];
    });
    list.add(i);
  }
  return [for (final k in order) InboxGroup(groups[k]!)];
}

/// The badge on the menu row: unread items in [mode], capped for display.
int inboxUnread(Iterable<InboxItem> items, String? mode) => inboxFor(items, mode).where((i) => i.unread).length;

/// The badge's text: the count, or 99+.
String inboxBadgeText(int unread) => unread > 99 ? '99+' : '$unread';

/// What kind of icon a row gets.
enum InboxIcon { ride, wallet, approval, safety, broadcast, other }

InboxIcon inboxIconFor(String? kind) => switch (kind) {
  null => InboxIcon.broadcast,
  'ride_status' ||
  'ride_cancel_request' ||
  'ride_payment' ||
  'ride_expired' ||
  'ride_call_end' ||
  'lost_item' ||
  'c2c_reminder' ||
  'c2c_pay' => InboxIcon.ride,
  'wallet_transfer_request' || 'wallet_transfer_response' => InboxIcon.wallet,
  'partner_status' || 'vehicle_status' || 'document_status' || 'partner_review' => InboxIcon.approval,
  'trip_start_check' || 'trip_separation' => InboxIcon.safety,
  _ => InboxIcon.other,
};

/// "Just now", "5 min ago", "3 h ago", "Yesterday", or the date. Pure.
String inboxWhen(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 1) return 'Just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24 && now.day == at.day) return '${d.inHours} h ago';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  final days = today.difference(day).inDays;
  if (days == 1) return 'Yesterday';
  if (days < 7) return '$days days ago';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${at.day} ${months[at.month - 1]}${at.year == now.year ? '' : ' ${at.year}'}';
}

/// A stored notification body as shown: its first character capitalised
/// (older pushes were saved as "your car is waiting at …"); nothing else in
/// the text changes. Pure.
String inboxBodyText(String body) =>
    body.isEmpty ? body : body.substring(0, 1).toUpperCase() + body.substring(1);
