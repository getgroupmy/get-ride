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
  'fare_tariffs',
  'get_coin_rate_history',
  'required_document',
  'document_type',
  'ev_vehicle_details',
  'ev_vehicle_inventory',
  'ev_delivery_advisors',
  'ev_finance_options',
  'ev_order_fee',
  'insurance_providers',
  'insurance_types',
  'insurance_durations',
  'insurance_premium',
  'driver_incentive',
  // Not settings, but the balances on screen: a commission or a transfer
  // lands without a pull to refresh (row-level security limits it to the
  // signed-in account's own wallets).
  'wallets',
  'messaging_devices',
  'messaging_routes',
  'sms_outbox',
  'sms_inbox',
];

/// The signed-in account's own rows that an admin decides on (approving,
/// rejecting or blocking the account, a document or a vehicle), each with
/// the column that names the account. Watched for that account only, so a
/// decision shows on the partner's open screens at once.
const liveOwnTables = <String, String>{
  'profiles': 'id',
  'partners': 'auth_user_id',
  'provider_documents': 'auth_user_id',
  'vehicle': 'auth_user_id',
  'vehicle_documents': 'auth_user_id',
};

/// The region tables (Admin → Country / States / Cities / Suburbs, and the
/// legacy settings entries) that decide bidding, pricing and services.
const liveRegionTables = <String>['countries', 'states', 'cities', 'suburbs', 'settings_entries'];

/// One number for [tables] that moves whenever any of them changes (each
/// revision only grows). Pure.
int liveStamp(Map<String, int> revisions, Iterable<String> tables) {
  var stamp = 0;
  for (final t in tables) {
    stamp += revisions[t] ?? 0;
  }
  return stamp;
}

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
    // A new account (signing in or out) is a new set of own rows to follow.
    String? uid;
    try {
      uid = ref.watch(currentUserIdProvider);
    } catch (_) {}
    try {
      final client = ref.read(supabaseProvider);
      db = client;
      var c = client.channel(uid == null ? 'live_settings' : 'live_settings_$uid');
      for (final table in liveSettingTables) {
        c = c.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          callback: (_) => changed([table]),
        );
      }
      if (uid != null) {
        for (final MapEntry(key: table, value: column) in liveOwnTables.entries) {
          c = c.onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: table,
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: column, value: uid),
            callback: (_) => changed([table]),
          );
        }
      }
      channel = c.subscribe();
    } catch (_) {
      // No client (tests, an unconfigured build): settings are read once, as before.
    }
    AppLifecycleListener? lifecycle;
    try {
      lifecycle = AppLifecycleListener(onResume: () => changed([...liveSettingTables, ...liveOwnTables.keys]));
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
  /// [liveSettingTables] and [liveOwnTables]).
  void watchLive(String table) => watch(liveTablesProvider.select((r) => r[table] ?? 0));
}

/// The tables admin pages list in full (every account's rows, not only the
/// admin's own): followed live only while an admin page that reads them is
/// open ([adminLiveTablesProvider] is built by those pages alone), so no
/// rider or driver ever opens this channel, and row-level security keeps
/// anyone but an admin from receiving its rows anyway.
const liveAdminTables = <String>[
  'profiles',
  'partners',
  'vehicle',
  'provider_documents',
  'vehicle_documents',
  'vehicle_user_assignment',
  'ride_requests',
  'support_tickets',
  'push_notifications',
  'ev_orders',
  'help_articles',
  'help_questions',
  'fare_ai_responses',
  'fare_ai_key_states',
  'user_sessions',
];

/// Rides and sessions change every few seconds while trips run; an admin
/// list re-reads at most this often.
const liveAdminDebounce = Duration(milliseconds: 1500);

/// Every row of [liveAdminTables], for admin pages (see [LiveTables] for the
/// settings and the account's own rows). Disposed when the last admin page
/// reading it closes.
class AdminLiveTables extends Notifier<Map<String, int>> {
  final _pending = <String>{};
  Timer? _debounce;

  @override
  Map<String, int> build() {
    RealtimeChannel? channel;
    SupabaseClient? db;
    try {
      final client = ref.read(supabaseProvider);
      db = client;
      var c = client.channel('live_admin');
      for (final table in liveAdminTables) {
        c = c.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          callback: (_) => changed([table]),
        );
      }
      channel = c.subscribe();
    } catch (_) {
      // No client (tests): admin lists are read once, as before.
    }
    AppLifecycleListener? lifecycle;
    try {
      lifecycle = AppLifecycleListener(onResume: () => changed(liveAdminTables));
    } catch (_) {}
    ref.onDispose(() {
      _debounce?.cancel();
      lifecycle?.dispose();
      if (channel != null) unawaited(db!.removeChannel(channel));
    });
    return const {};
  }

  /// Marks [tables] as changed; their readers refetch after [liveAdminDebounce].
  void changed(Iterable<String> tables) {
    _pending.addAll(tables);
    _debounce?.cancel();
    _debounce = Timer(liveAdminDebounce, () {
      final due = {..._pending};
      _pending.clear();
      if (ref.mounted) state = bumpRevisions(state, due);
    });
  }
}

final adminLiveTablesProvider = NotifierProvider.autoDispose<AdminLiveTables, Map<String, int>>(AdminLiveTables.new);

extension AdminLiveTableRef on Ref {
  /// Re-runs this admin provider whenever any row of [table] changes, the
  /// admin's own or anyone's: a settings table through [liveSettingTables],
  /// the rest through [liveAdminTables].
  void watchAdminLive(String table) {
    if (liveAdminTables.contains(table)) {
      watch(adminLiveTablesProvider.select((r) => r[table] ?? 0));
    } else {
      watchLive(table);
    }
  }
}

extension LiveTableWidgetRef on WidgetRef {
  /// Calls [onChange] whenever a row of any of [tables] changes, for a
  /// screen that loads in initState and must keep what is being typed (call
  /// it from build).
  void listenLive(List<String> tables, void Function() onChange) =>
      listen(liveTablesProvider.select((r) => liveStamp(r, tables)), (_, _) => onChange());

  /// [listenLive] for an admin page: every row of [tables], anyone's.
  void listenAdminLive(List<String> tables, void Function() onChange) {
    final admin = [for (final t in tables) if (liveAdminTables.contains(t)) t];
    final settings = [for (final t in tables) if (!liveAdminTables.contains(t)) t];
    if (admin.isNotEmpty) {
      listen(adminLiveTablesProvider.select((r) => liveStamp(r, admin)), (_, _) => onChange());
    }
    if (settings.isNotEmpty) listenLive(settings, onChange);
  }
}
