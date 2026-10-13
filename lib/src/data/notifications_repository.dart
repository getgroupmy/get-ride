import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/inbox.dart';
import '../providers.dart';
import 'realtime_backup.dart';

/// The notifications page's rows (`user_notifications`, migration 0167):
/// read live, marked read and removed through the owner-only functions.
class NotificationsRepository {
  NotificationsRepository(this._db);

  final SupabaseClient _db;

  static const _table = 'user_notifications';

  /// How many the page keeps on screen.
  static const pageSize = 100;

  Future<List<InboxItem>> list(String userId) async {
    final rows = await _db
        .from(_table)
        .select()
        .eq('profile_id', userId)
        .order('created_at', ascending: false)
        .limit(pageSize);
    return [for (final r in rows) InboxItem.fromRow(r)];
  }

  /// The list, re-read whenever a row of this account's changes (and on the
  /// realtime backup's schedule while realtime is down). A database without
  /// the table answers an empty list.
  Stream<List<InboxItem>> watch(String userId) {
    final controller = StreamController<List<InboxItem>>();
    RealtimeChannel? channel;
    RealtimeBackup? backup;
    controller.onListen = () {
      Future<void> reread() async {
        try {
          final items = await list(userId);
          if (!controller.isClosed) controller.add(items);
        } catch (e) {
          if (!controller.isClosed) controller.add(const []);
        }
      }

      backup = RealtimeBackup(reread);
      channel = _db
          .channel('user_notifications_${userId}_${DateTime.now().microsecondsSinceEpoch}')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: _table,
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'profile_id', value: userId),
            callback: (_) => unawaited(reread()),
          )
          .subscribe(backup!.onStatus);
      unawaited(reread());
    };
    controller.onCancel = () async {
      backup?.dispose();
      if (channel != null) await _db.removeChannel(channel!);
      await controller.close();
    };
    return controller.stream;
  }

  /// Marks [ids] read, or every unread one when null.
  Future<void> markRead([List<String>? ids]) => _db.rpc('notifications_mark_read', params: {'p_ids': ids});

  Future<void> delete(List<String> ids) => _db.rpc('notifications_delete', params: {'p_ids': ids});
}

final notificationsRepositoryProvider = Provider((ref) => NotificationsRepository(ref.watch(supabaseProvider)));

/// This account's kept notifications, live; empty when signed out.
final notificationsProvider = StreamProvider<List<InboxItem>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(const []);
  return ref.watch(notificationsRepositoryProvider).watch(userId);
});

/// The mode the app is in ('rider' / 'partner'), as the router reports it
/// (pushModeAt). The page and its badge show that mode's notifications.
class AppModeNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? mode) {
    if (mode != null && mode != state) state = mode;
  }
}

final appModeProvider = NotifierProvider<AppModeNotifier, String?>(AppModeNotifier.new);

/// The side menu row's badge.
final unreadNotificationsProvider = Provider<int>((ref) {
  final items = ref.watch(notificationsProvider).value ?? const <InboxItem>[];
  return inboxUnread(items, ref.watch(appModeProvider));
});
