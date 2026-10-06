// Live admin settings, app-wide (Expo's DisplaySettingsContext pattern for
// every settings table): one realtime channel watches the tables admins
// configure, and each table has a revision number that moves when one of its
// rows changes. A provider that reads a table calls `ref.watchLive(table)`,
// so it refetches by itself on the next change — the change shows on every
// open screen without a reload. Coming back to the foreground moves every
// revision, in case the socket dropped while the app was away.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';

/// The tables admins configure that the app reads. Each must be in the
/// `supabase_realtime` publication (migration 0102 adds those that were not).
const liveSettingTables = <String>[
  'admin_display_settings',
  'settings_entries',
  'app_settings',
  'app_branding',
  'meter_digital_settings',
  'get_coin_settings',
  'commission_rates',
  'airport_areas',
  'multi_gate',
  'ip_access_rules',
  'admin_access',
  'vehicle_make_models',
  'countries',
  'states',
  'cities',
  'suburbs',
];

/// Changes landing this close together are one refetch, not one each (an
/// admin save can touch several rows of a table at once).
const liveDebounce = Duration(milliseconds: 300);

/// Moves [revisions] for [tables]: one more for each. Pure.
Map<String, int> bumpRevisions(Map<String, int> revisions, Iterable<String> tables) => {
  ...revisions,
  for (final t in tables) t: (revisions[t] ?? 0) + 1,
};

class LiveTables extends Notifier<Map<String, int>> {
  final _pending = <String>{};
  Timer? _debounce;

  @override
  Map<String, int> build() {
    RealtimeChannel? channel;
    SupabaseClient? db;
    try {
      final client = ref.read(supabaseProvider);
      db = client;
      var c = client.channel('live_settings');
      for (final table in liveSettingTables) {
        c = c.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          callback: (_) => changed([table]),
        );
      }
      channel = c.subscribe();
    } catch (_) {
      // No client (tests, an unconfigured build): settings are read once, as before.
    }
    AppLifecycleListener? lifecycle;
    try {
      lifecycle = AppLifecycleListener(onResume: () => changed(liveSettingTables));
    } catch (_) {}
    ref.onDispose(() {
      _debounce?.cancel();
      lifecycle?.dispose();
      if (channel != null) unawaited(db!.removeChannel(channel));
    });
    return const {};
  }

  /// Marks [tables] as changed; their readers refetch after [liveDebounce].
  void changed(Iterable<String> tables) {
    _pending.addAll(tables);
    _debounce?.cancel();
    _debounce = Timer(liveDebounce, () {
      final due = {..._pending};
      _pending.clear();
      if (ref.mounted) state = bumpRevisions(state, due);
    });
  }
}

final liveTablesProvider = NotifierProvider<LiveTables, Map<String, int>>(LiveTables.new);

extension LiveTableRef on Ref {
  /// Re-runs this provider whenever a row of [table] changes (see
  /// [liveSettingTables]).
  void watchLive(String table) => watch(liveTablesProvider.select((r) => r[table] ?? 0));
}
