import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/ride_chat.dart';
import '../core/support_media.dart' show fileExt;
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

  /// Uploads a file into the ride's folder of the private bucket; its path.
  Future<String> _upload(String requestId, RideMessageType kind, Uint8List bytes, String ext) async {
    final path = rideChatMediaPath(requestId, kind, ext, DateTime.now(), const Uuid().v4().substring(0, 8));
    await _db.storage
        .from(rideChatMediaBucket)
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: rideChatContentType(kind, ext)));
    return path;
  }

  /// Sends a photo (from the gallery or the camera) with an optional caption.
  Future<void> sendPhoto(String requestId, RideChatRole role, Uint8List bytes, {required String name, String? caption}) async {
    final problem = ridePhotoProblem(bytes.length);
    if (problem != null) throw StateError(problem);
    final ext = fileExt(name);
    final path = await _upload(requestId, RideMessageType.image, bytes, ext.isEmpty ? 'jpg' : ext);
    final c = caption?.trim() ?? '';
    await _send({
      'request_id': requestId,
      'sender_role': role.name,
      'type': 'image',
      'media_path': path,
      if (c.isNotEmpty) 'body': c.length > rideMessageMaxLength ? c.substring(0, rideMessageMaxLength) : c,
    });
  }

  /// Sends a voice note.
  Future<void> sendVoiceNote(String requestId, RideChatRole role, Uint8List bytes, {required String ext, required Duration duration}) async {
    if (bytes.isEmpty) throw StateError('Nothing was recorded.');
    if (bytes.length > rideChatMediaMaxBytes) throw StateError('That voice note is too long to send.');
    final path = await _upload(requestId, RideMessageType.audio, bytes, ext);
    await _send({
      'request_id': requestId,
      'sender_role': role.name,
      'type': 'audio',
      'media_path': path,
      'media_duration': rideVoiceNoteSeconds(duration),
    });
  }

  /// A short-lived link to a photo or voice note; only the ride's two
  /// participants can get one.
  Future<String> mediaUrl(String path) =>
      _db.storage.from(rideChatMediaBucket).createSignedUrl(path, rideChatMediaLinkTtl.inSeconds);

  /// Moves the tick of the messages [ids] up to [to]; rows already past it
  /// are left alone (the database refuses a tick going back).
  Future<void> mark(List<String> ids, RideMessageStatus to) async {
    if (ids.isEmpty || to == RideMessageStatus.sent) return;
    final behind = to == RideMessageStatus.read ? ['sent', 'delivered'] : ['sent'];
    await _db.from('ride_messages').update({'status': to.name}).inFilter('id', ids).inFilter('status', behind);
  }
}

final rideChatRepositoryProvider = Provider((ref) => RideChatRepository(ref.watch(supabaseProvider)));

/// The link to a chat photo or voice note, renewed a little before the link
/// itself runs out so a stale one is never handed out.
final rideChatMediaUrlProvider = FutureProvider.autoDispose.family<String, String>((ref, path) async {
  final url = await ref.watch(rideChatRepositoryProvider).mediaUrl(path);
  final keep = ref.keepAlive();
  final timer = Timer(rideChatMediaLinkTtl - const Duration(minutes: 10), () {
    keep.close();
    ref.invalidateSelf();
  });
  ref.onDispose(timer.cancel);
  return url;
});

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
