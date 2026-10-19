// Whether the app knows it can't reach GET.ride right now, from what it
// already hears: the live-settings realtime channel dropping or coming
// back (`LiveTables`), and the launch connection check behind the
// connection popups. No probe of its own.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

/// What a realtime channel status says about the connection: offline on an
/// error or a timeout, online once subscribed, nothing new otherwise (a
/// channel closed on purpose says nothing). Pure.
bool? offlineFromRealtime(RealtimeSubscribeStatus status) => switch (status) {
  RealtimeSubscribeStatus.subscribed => false,
  RealtimeSubscribeStatus.channelError || RealtimeSubscribeStatus.timedOut => true,
  RealtimeSubscribeStatus.closed => null,
};

class AppOffline extends Notifier<bool> {
  /// Unknown counts as online: no strip until something says otherwise.
  @override
  bool build() => false;

  /// From the live channel's status ([offlineFromRealtime]).
  void realtime(RealtimeSubscribeStatus status) {
    final offline = offlineFromRealtime(status);
    if (offline != null) set(offline);
  }

  /// From the launch connection check: whether the server answered.
  void reachable(bool ok) => set(!ok);

  void set(bool offline) {
    if (ref.mounted && state != offline) state = offline;
  }
}

/// True while the app knows it is offline (see [AppOffline]).
final appOfflineProvider = NotifierProvider<AppOffline, bool>(AppOffline.new);
