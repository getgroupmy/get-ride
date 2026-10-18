import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/ride_chat.dart';
import '../core/ride_chat_outbox.dart';
import '../core/support_media.dart' show fileExt;
import '../providers.dart';
import 'realtime_backup.dart';
import 'realtime_hub.dart';
import 'storage_links.dart' show cachedSignedLink;

/// The rider ↔ driver chat of a ride (`ride_messages`, migration 0129). RLS
/// keeps each thread to the ride's two participants; a trigger lets only the
/// receiver move a tick.
class RideChatRepository {
  RideChatRepository(this._db);
  final SupabaseClient _db;

  Future<List<RideMessage>> messages(String requestId) async {
    final rows = await _db.from('ride_messages').select().eq('request_id', requestId).order('created_at');
    unawaited(_saveCache(requestId, rows));
    return [for (final r in rows) ?RideMessage.fromRow(r)];
  }

  // ---- The thread kept on the phone (reliability Phase C) -------------------
  // The last copy the server sent, so an open chat shows its history with no
  // connection. Best effort: a phone that can't store it just loads.

  static String _cacheKey(String requestId) => 'ride_chat_cache_v1_$requestId';

  /// What each thread was last kept as this session: a re-read that brings
  /// nothing new is not written again.
  final _keptThreads = <String, String>{};

  Future<void> _saveCache(String requestId, List<Map<String, dynamic>> rows) async {
    try {
      final json = jsonEncode(rows);
      if (_keptThreads[requestId] == json) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey(requestId), json);
      _keptThreads[requestId] = json;
    } catch (_) {}
  }

  /// The thread as last loaded on this phone; empty when there is none.
  Future<List<RideMessage>> cachedMessages(String requestId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey(requestId));
      if (raw == null) return const [];
      return [
        for (final r in jsonDecode(raw) as List)
          if (r is Map) ?RideMessage.fromRow(Map<String, dynamic>.from(r)),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// The thread for [requestId], re-read whenever a message arrives or a
  /// tick moves.
  Stream<List<RideMessage>> watch(String requestId) {
    final controller = StreamController<List<RideMessage>>();
    RealtimeListen? channel;
    var loaded = false;
    Future<void> refresh() async {
      try {
        final list = await messages(requestId);
        loaded = true;
        if (!controller.isClosed) controller.add(list);
      } catch (e, st) {
        // No connection: the copy kept on the phone, rather than an error
        // in place of the whole thread.
        final cached = loaded ? null : await cachedMessages(requestId);
        if (controller.isClosed) return;
        if (cached != null && cached.isNotEmpty) {
          controller.add(cached);
        } else if (!loaded) {
          controller.addError(e, st);
        }
      }
    }

    RealtimeBackup? backup;
    controller.onListen = () {
      backup = RealtimeBackup(refresh);
      // The copy on the phone first, so the thread is there at once; the
      // server's replaces it as soon as it answers.
      cachedMessages(requestId).then((cached) {
        if (!loaded && cached.isNotEmpty && !controller.isClosed) controller.add(cached);
      });
      refresh();
      channel = RealtimeHub.of(_db).listen(
        table: 'ride_messages',
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'request_id', value: requestId),
        onChange: (_) => refresh(),
        onStatus: backup!.onStatus,
      );
    };
    controller.onCancel = () async {
      backup?.dispose();
      channel?.cancel();
      await controller.close();
    };
    return controller.stream;
  }

  /// Inserts a message under an id of its own, trying again while the
  /// connection fails: the same id every time, so it is stored once
  /// (migration 0146). A database from before that id takes it without one.
  Future<void> _send(Map<String, dynamic> row) async {
    final withId = {...row, 'client_msg_id': const Uuid().v4()};
    var useId = true;
    for (var attempt = 0; ; attempt++) {
      try {
        if (useId) {
          await _db.from('ride_messages').upsert(withId, onConflict: 'client_msg_id', ignoreDuplicates: true);
        } else {
          await _db.from('ride_messages').insert(row);
        }
        return;
      } on PostgrestException catch (e) {
        if (useId && rideSendLacksClientId(e.code, e.message)) {
          useId = false;
          attempt--;
          continue;
        }
        rethrow;
      } catch (_) {
        // The connection, not the database (a refusal fails the same way
        // every time and is rethrown above).
        if (attempt >= rideSendRetryDelays.length) rethrow;
        await Future<void>.delayed(rideSendRetryDelays[attempt]);
      }
    }
  }

  /// Sends a message kept on the phone (ride_chat_outbox.dart), once, under
  /// its own id, so a send that reached the server before the connection
  /// dropped is not stored twice. Throws a [PostgrestException] when the
  /// database refused it, anything else when it didn't get there.
  Future<void> sendQueued(PendingRideMessage p) async {
    try {
      await _db.from('ride_messages').upsert(p.toRow(), onConflict: 'client_msg_id', ignoreDuplicates: true);
    } on PostgrestException catch (e) {
      if (!rideSendLacksClientId(e.code, e.message)) rethrow;
      await _db.from('ride_messages').insert(p.toRow()..remove('client_msg_id'));
    }
  }

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
  Future<String> mediaUrl(String path) => cachedSignedLink(
    '$rideChatMediaBucket/$path',
    ttl: rideChatMediaLinkTtl,
    sign: () => _db.storage.from(rideChatMediaBucket).createSignedUrl(path, rideChatMediaLinkTtl.inSeconds),
  );

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
