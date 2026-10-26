// Whether the app knows it can't reach GET.ride right now, from what it
// already hears: each request to the server answering or not
// (`httpOutcomes`), the live-settings realtime channel opening
// (`LiveTables`), and the launch connection check behind the connection
// popups. No probe of its own.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

import 'timeout_http_client.dart' show httpOutcomes;

/// What a realtime channel status says about the connection: online once
/// subscribed, nothing otherwise. A channel that errors or times out says
/// nothing either: networks that block WebSockets still reach the server,
/// and the requests themselves tell ([httpOutcomes]). Pure.
bool? offlineFromRealtime(RealtimeSubscribeStatus status) => switch (status) {
  RealtimeSubscribeStatus.subscribed => false,
  _ => null,
};

class AppOffline extends Notifier<bool> {
  /// Unknown counts as online: no strip until something says otherwise.
  @override
  bool build() {
    final sub = httpOutcomes.listen((ok) => set(!ok));
    ref.onDispose(sub.cancel);
    return false;
  }

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
