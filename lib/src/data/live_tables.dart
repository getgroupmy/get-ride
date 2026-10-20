// Live admin settings, app-wide (Expo's DisplaySettingsContext pattern for
// every settings table): one realtime channel watches the tables admins
// configure, and each table has a revision number that moves when one of its
// rows changes. A provider that reads a table calls `ref.watchLive(table)`,
// so it refetches by itself on the next change — the change shows on every
// open screen without a reload. A channel that reopens (or coming back to the
// foreground while it is down) moves every revision, in case an update was
// missed while the socket was down; while it stays open only a slow, jittered
// safety net (about every 20 minutes) re-reads everything.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';
import 'app_connection.dart';
import 'realtime_backup.dart';

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
  // Airports' settings, waiting zones and fare zones (0249).
  'airport_settings',
  'airport_waiting_zones',
  'airport_fare_zones',
  // Vehicle services, lowest to highest (0249).
  'vehicle_service_order',
  // Whether that order applies to every booking (0250).
  'service_order_settings',
  'ip_access_rules',
  'admin_access',
  'vehicle_make_models',
  'countries',
  'states',
  'cities',
  'suburbs',
  'fare_tariffs',
  // Ride Options by place: charges, offered here, blocked services (0253).
  'ride_option_places',
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
  // Admin → Commission settings → tiers (0218).
  'commission_tiers',
  // Not settings, but the balances on screen: a commission or a transfer
  // lands without a pull to refresh (row-level security limits it to the
  // signed-in account's own wallets).
  'wallets',
  // messaging_devices is not here: every gateway's heartbeat rewrites its
  // row, so Admin → SMS / WhatsApp reads it on a timer instead (0229).
  'messaging_routes',
  'sms_outbox',
  'sms_inbox',
  'sms_settings',
  'sms_log',
  'sms_fallback_settings',
  // Lost item reports and the driver's answers (0154; parties only).
  'ride_lost_items',
  // Scheduled rides (0189): the rider's bookings and a driver's accepted
  // ones, as their state moves (row-level security keeps them to those).
  'scheduled_rides',
  // Handovers and passengers' choices of driver (0198; the parties only).
  'scheduled_ride_offers',
  // Mid-trip handovers (0199; the drivers and passenger in each only).
  'trip_handovers',
  // A handover offered to this partner, and when it closes.
  'trip_handover_candidates',
  // EV profiles for the OBD-II reader (0202; the active ones, or all for an admin).
  'ev_profiles',
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
  // The ride extras the driver turned off (0253).
  'driver_ride_extras': 'driver_id',
};

/// The region tables (Admin → Country / States / Cities / Suburbs, and the
/// legacy settings entries) that decide bidding, pricing and services.
const liveRegionTables = <String>['countries', 'states', 'cities', 'suburbs', 'settings_entries'];

/// The `app_settings` rows the map profile is made from (the `geo`
/// function reads these two alone). A change to one also moves
/// [liveMapSettings], so the map profile is asked for again only then, not
/// on every page-style, app-icon or other app setting an admin saves.
const mapSettingKeys = <String>{'map_config', 'api_providers'};

/// The revision that moves when one of [mapSettingKeys] changes; watched
/// like a table (`ref.watchLive(liveMapSettings)`).
const liveMapSettings = 'app_settings:map';

/// What a change to a row of [table] moves: the table, and for an
/// `app_settings` row of [mapSettingKeys] (or one whose key is not known)
/// [liveMapSettings] too. Pure.
List<String> liveRevisionsFor(String table, Map<String, dynamic> newRecord, Map<String, dynamic> oldRecord) {
  if (table != 'app_settings') return [table];
  final keys = [newRecord['key'], oldRecord['key']].whereType<String>();
  final map = keys.isEmpty || keys.any(mapSettingKeys.contains);
  return map ? [table, liveMapSettings] : [table];
}

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
    RealtimeBackup? backup;
    try {
      final client = ref.read(supabaseProvider);
      db = client;
      // A channel that reopened, or every couple of minutes (and on coming
      // back to the foreground) while it is down: everything is read again.
      // While it is open realtime delivers, so only a slow, jittered safety
      // net re-reads (a channel can report healthy while missing changes)
      // -- each full read refetches every live provider on the phone.
      backup = RealtimeBackup(
        () => changed([...liveSettingTables, liveMapSettings, ...liveOwnTables.keys]),
        every: const Duration(minutes: 2),
        healthy: realtimeBackupSafetyNetInterval,
        healthyJitter: realtimeBackupSafetyNetJitter,
        onOpen: false,
        resumeWhileOpen: false,
      );
      var c = client.channel(uid == null ? 'live_settings' : 'live_settings_$uid');
      for (final table in liveSettingTables) {
        c = c.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          callback: (p) => changed(liveRevisionsFor(table, p.newRecord, p.oldRecord)),
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
      final status = backup.onStatus;
      channel = c.subscribe((s, [e]) {
        status(s, e);
        // The connection strip (OfflineStrip) hears it too: no probe of its own.
        if (ref.mounted) ref.read(appOfflineProvider.notifier).realtime(s);
      });
    } catch (_) {
      // No client (tests, an unconfigured build): settings are read once, as before.
    }
    ref.onDispose(() {
      _debounce?.cancel();
      backup?.dispose();
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
  // SOS alerts (0193): the red banner on every admin screen.
  'safety_incidents',
  // Commission promotions (0224): admins only.
  'commission_promotions',
  // Rider promo codes and what they gave (0242): admins only.
  'promo_codes',
  'promo_redemptions',
  // Claude Code access (0228): the admin page follows the list live.
  'claude_access_rules',
  // The ride extras each driver turned off (0253): their admin page.
  'driver_ride_extras',
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
    RealtimeBackup? backup;
    try {
      final client = ref.read(supabaseProvider);
      db = client;
      // Re-read fast only while the channel is down (or as it reopens);
      // while it reports healthy, only the slow jittered safety net.
      backup = RealtimeBackup(
        () => changed(liveAdminTables),
        every: const Duration(seconds: 30),
        healthy: realtimeBackupSafetyNetInterval,
        healthyJitter: realtimeBackupSafetyNetJitter,
        onOpen: false,
        resumeWhileOpen: false,
      );
      var c = client.channel('live_admin');
      for (final table in liveAdminTables) {
        c = c.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          callback: (_) => changed([table]),
        );
      }
      final status = backup.onStatus;
      channel = c.subscribe((s, [e]) {
        status(s, e);
        // The connection strip (OfflineStrip) hears it too: no probe of its own.
        if (ref.mounted) ref.read(appOfflineProvider.notifier).realtime(s);
      });
    } catch (_) {
      // No client (tests): admin lists are read once, as before.
    }
    ref.onDispose(() {
      _debounce?.cancel();
      backup?.dispose();
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
