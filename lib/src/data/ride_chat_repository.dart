import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/ride_chat.dart';
import '../providers.dart';

/// The rider ↔ driver chat of a ride (`ride_messages`, migration 0129). RLS
/// keeps each thread to the ride's two participants; a trigger lets only the
/// receiver move a tick.
class RideChatRepository {
  RideChatRepository(this._db);
  final SupabaseClient _db;

  Future<List<RideMessage>> messages(String requestId) async {
    final rows = await _db.from('ride_messages').select().eq('request_id', requestId).order('created_at');
    return [for (final r in rows) ?RideMessage.fromRow(r)];
  }

  /// The thread for [requestId], re-read whenever a message arrives or a
  /// tick moves.
  Stream<List<RideMessage>> watch(String requestId) {
    final controller = StreamController<List<RideMessage>>();
    RealtimeChannel? channel;
    Future<void> refresh() async {
      try {
        final list = await messages(requestId);
        if (!controller.isClosed) controller.add(list);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      }
    }

    controller.onListen = () {
      refresh();
      channel = _db
          .channel('ride_chat_${requestId}_${DateTime.now().microsecondsSinceEpoch}')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'ride_messages',
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'request_id', value: requestId),
            callback: (_) => refresh(),
          )
          .subscribe();
    };
    controller.onCancel = () async {
      if (channel != null) await _db.removeChannel(channel!);
      await controller.close();
    };
    return controller.stream;
  }

  Future<void> _send(Map<String, dynamic> row) => _db.from('ride_messages').insert(row);

  Future<void> sendText(String requestId, RideChatRole role, String body, {bool quick = false}) async {
    final text = rideMessageText(body);
    if (text == null) return;
    await _send({'request_id': requestId, 'sender_role': role.name, 'type': quick ? 'quick' : 'text', 'body': text});
  }

  Future<void> sendLocation(String requestId, RideChatRole role, double lat, double lng) =>
      _send({'request_id': requestId, 'sender_role': role.name, 'type': 'location', 'latitude': lat, 'longitude': lng});

  /// Moves the tick of the messages [ids] up to [to]; rows already past it
  /// are left alone (the database refuses a tick going back).
  Future<void> mark(List<String> ids, RideMessageStatus to) async {
    if (ids.isEmpty || to == RideMessageStatus.sent) return;
    final behind = to == RideMessageStatus.read ? ['sent', 'delivered'] : ['sent'];
    await _db.from('ride_messages').update({'status': to.name}).inFilter('id', ids).inFilter('status', behind);
  }
}

final rideChatRepositoryProvider = Provider((ref) => RideChatRepository(ref.watch(supabaseProvider)));

/// The live thread of a ride. Incoming messages are marked delivered as soon
/// as they reach this device. Empty when signed out or unreadable.
final rideMessagesProvider = StreamProvider.autoDispose.family<List<RideMessage>, String>((ref, requestId) {
  final String? uid;
  final RideChatRepository repo;
  try {
    uid = ref.watch(currentUserIdProvider);
    if (uid == null) return Stream.value(const []);
    repo = ref.watch(rideChatRepositoryProvider);
  } catch (_) {
    return Stream.value(const []);
  }
  return repo.watch(requestId).map((list) {
    final ids = rideMessagesToDeliver(list, uid);
    if (ids.isEmpty) return list;
    unawaited(repo.mark(ids, RideMessageStatus.delivered).catchError((_) {}));
    return withRideMessageStatus(list, ids.toSet(), RideMessageStatus.delivered);
  });
});

/// Unread messages in a ride's chat (the badge on Message); 0 when unknown.
final rideChatUnreadProvider = Provider.autoDispose.family<int, String>((ref, requestId) {
  final String? uid;
  try {
    uid = ref.watch(currentUserIdProvider);
  } catch (_) {
    return 0;
  }
  if (uid == null) return 0;
  final list = ref.watch(rideMessagesProvider(requestId)).value ?? const <RideMessage>[];
  return rideUnreadCount(list, uid);
});
