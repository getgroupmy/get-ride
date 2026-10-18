// One realtime channel per table, event and filter, however many streams on
// the phone follow those rows (PERF-52). Every stream that followed a ride,
// a chat, a call or a transfer used to open a channel of its own (named with
// the time, so none was ever shared): two screens on the same ride were two
// channels and two subscription rows on the server. Streams now take a
// listener on the shared channel, which closes with the last of them.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';

/// A status callback, as `channel.subscribe(...)` takes one
/// ([RealtimeBackup.onStatus] fits).
typedef RealtimeStatusCallback = void Function(RealtimeSubscribeStatus status, [Object? error]);

/// Opens a channel on [table] for [event] and [filter], delivering to
/// [onChange] and [onStatus]; returns what [RealtimeClose] takes to close it.
typedef RealtimeOpen =
    Object Function(
      String name,
      String table,
      PostgresChangeEvent event,
      PostgresChangeFilter? filter,
      void Function(PostgresChangePayload payload) onChange,
      RealtimeStatusCallback onStatus,
    );
typedef RealtimeClose = void Function(Object channel);

/// The key two followers share a channel on: the same table, event and
/// filter. Pure.
String realtimeKey(String table, PostgresChangeEvent event, PostgresChangeFilter? filter) => [
  table,
  event.name,
  if (filter != null) ...[filter.type.name, filter.column, '${filter.value}'],
].join('|');

/// A follower's hold on a shared channel; [cancel] lets go of it (the
/// channel closes with its last follower). Cancelling twice is harmless.
class RealtimeListen {
  RealtimeListen._(this._cancel);
  final void Function() _cancel;
  bool _done = false;

  void cancel() {
    if (_done) return;
    _done = true;
    _cancel();
  }
}

class _Follower {
  _Follower(this.onChange, this.onStatus);
  final void Function(PostgresChangePayload payload) onChange;
  final RealtimeStatusCallback? onStatus;
}

class _Shared {
  late final Object channel;
  final followers = <_Follower>[];
  RealtimeSubscribeStatus? status;
  Object? error;

  void change(PostgresChangePayload p) {
    for (final f in [...followers]) {
      try {
        f.onChange(p);
      } catch (_) {}
    }
  }

  void report(RealtimeSubscribeStatus s, [Object? e]) {
    status = s;
    error = e;
    for (final f in [...followers]) {
      try {
        f.onStatus?.call(s, e);
      } catch (_) {}
    }
  }
}

/// The phone's shared realtime channels, counted by their followers.
class RealtimeHub {
  /// A hub over [open] and [close] (tests); [RealtimeHub.of] for a client.
  RealtimeHub(this._open, this._close);

  static final _hubs = Expando<RealtimeHub>();

  /// The hub of [db]: repositories built on the same client share it.
  static RealtimeHub of(SupabaseClient db) => _hubs[db] ??= RealtimeHub(
    (name, table, event, filter, onChange, onStatus) => db
        .channel(name)
        .onPostgresChanges(event: event, schema: 'public', table: table, filter: filter, callback: onChange)
        .subscribe(onStatus),
    (channel) => unawaited(db.removeChannel(channel as RealtimeChannel).then((_) {}, onError: (Object _) {})),
  );

  final RealtimeOpen _open;
  final RealtimeClose _close;
  final _channels = <String, _Shared>{};
  var _opened = 0;

  /// The channels open now, and how many were ever opened.
  int get openChannels => _channels.length;
  int get channelsOpened => _opened;

  /// Follows changes to [table] matching [event] and [filter]: [onChange]
  /// for each, [onStatus] with the channel's state (at once with the last
  /// one when the channel is already open). A channel that cannot be opened
  /// (no client) throws, as `channel(...)` did.
  RealtimeListen listen({
    required String table,
    PostgresChangeEvent event = PostgresChangeEvent.all,
    PostgresChangeFilter? filter,
    required void Function(PostgresChangePayload payload) onChange,
    RealtimeStatusCallback? onStatus,
  }) {
    final key = realtimeKey(table, event, filter);
    var shared = _channels[key];
    if (shared == null) {
      final s = _Shared();
      s.channel = _open(
        'shared_${key.replaceAll('|', '_')}_${DateTime.now().microsecondsSinceEpoch}',
        table,
        event,
        filter,
        s.change,
        s.report,
      );
      _channels[key] = shared = s;
      _opened++;
    }
    final follower = _Follower(onChange, onStatus);
    final s = shared;
    s.followers.add(follower);
    final known = s.status;
    if (known != null) onStatus?.call(known, s.error);
    return RealtimeListen._(() {
      s.followers.remove(follower);
      if (s.followers.isNotEmpty || !identical(_channels[key], s)) return;
      _channels.remove(key);
      _close(s.channel);
    });
  }
}

/// The hub of the app's client.
final realtimeHubProvider = Provider<RealtimeHub>((ref) => RealtimeHub.of(ref.watch(supabaseProvider)));
