// A read that stays current: rows read once, then again on every realtime
// change to them, and on the RealtimeBackup timer, so they still arrive when
// the realtime connection is down (a network that blocks WebSockets, a
// socket that dropped). A bare `.stream()` reads once and then relies on
// realtime alone.
import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'realtime_backup.dart';
import 'realtime_hub.dart';

/// [read] now and again whenever a row of [table] matching [column] =
/// [value] changes, or the backup's timer comes round ([every] while
/// realtime is down; [backoff] false keeps to [every] however long it stays
/// down, for lists a person is waiting on).
Stream<T> liveQuery<T>(
  SupabaseClient db, {
  required String table,
  required String column,
  required Object value,
  required Future<T> Function() read,
  Duration every = realtimeBackupInterval,
  bool backoff = true,
}) {
  final controller = StreamController<T>();
  RealtimeListen? channel;
  RealtimeBackup? backup;
  Future<void> refresh() async {
    try {
      final v = await read();
      if (!controller.isClosed) controller.add(v);
    } catch (e, st) {
      if (!controller.isClosed) controller.addError(e, st);
    }
  }

  controller.onListen = () {
    backup = RealtimeBackup(refresh, every: every, backoff: backoff, onOpen: true);
    refresh();
    channel = RealtimeHub.of(db).listen(
      table: table,
      filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: column, value: value),
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
