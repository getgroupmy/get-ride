// Data access for the Payments & commerce screens. Every call runs with the
// signed-in admin's session; RLS (`caller_is_admin()`) is the real gate.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../providers.dart';
import '../../admin_providers.dart';
import '../../admin_settings_models.dart';
import 'commerce_logic.dart';
import 'get_coin.dart';
import '../../../data/live_tables.dart';

SettingsCategory _cat(String key, String page, String title, String table) =>
    SettingsCategory(key: key, page: page, title: title, subtitle: '', table: table, fields: const []);

/// Storage for each entry-shaped category these screens edit (Expo
/// `CATEGORY_TABLE_MAP`; the rest live in `settings_entries`).
final commerceCategories = <String, SettingsCategory>{
  paymentTypeCategory: _cat(paymentTypeCategory, 'admin-settings-payment-type', 'Payment Type', 'settings_entries'),
  paymentGatewayCategory:
      _cat(paymentGatewayCategory, 'admin-settings-payment-gateway', 'Payment Gateways', 'settings_entries'),
  'ev-order-fee': _cat('ev-order-fee', 'admin-settings-ev-order-fee', 'Order Fee', 'ev_order_fee'),
  'ev-finance-options':
      _cat('ev-finance-options', 'admin-settings-ev-finance-options', 'EV Finance Options', 'ev_finance_options'),
  'ev-vehicle-details':
      _cat('ev-vehicle-details', 'admin-settings-ev-vehicle-details', 'EV Vehicle Details', 'ev_vehicle_details'),
  'ev-vehicle-inventory': _cat(
      'ev-vehicle-inventory', 'admin-settings-ev-vehicle-inventory', 'EV Vehicle Inventory', 'ev_vehicle_inventory'),
  'ev-delivery-advisors':
      _cat('ev-delivery-advisors', 'admin-settings-ev-delivery-advisors', 'Delivery Advisors', 'ev_delivery_advisors'),
  'ev-delivery-checklist':
      _cat('ev-delivery-checklist', 'admin-settings-ev-delivery-checklist', 'Delivery Checklist', 'settings_entries'),
  'country-states-cities':
      _cat('country-states-cities', 'admin-settings-country-states-cities', 'Countries', 'settings_entries'),
};

typedef Entry = ({String id, Map<String, dynamic> values});

/// Entries of one category, in `position` order.
final commerceEntriesProvider = FutureProvider.autoDispose.family<List<Entry>, String>((ref, key) async {
  ref.watchLive('settings_entries');
  final rows = await ref.watch(adminRepositoryProvider).settings(commerceCategories[key]!);
  return [for (final r in rows) (id: r.id, values: r.values)];
});

/// Active gateway accounts for the picker. Only the reference fields are
/// selected (JSON-path projection), so credentials never reach this client.
final gatewayAccountsProvider = FutureProvider.autoDispose<List<SelectedGateway>>((ref) async {
  ref.watchLive('settings_entries');
  final rows = await ref
      .watch(supabaseProvider)
      .from('settings_entries')
      .select('id, providerId:values->>providerId, providerName:values->>providerName, '
          'accountName:values->>accountName, mode:values->>mode, active:values->active')
      .eq('category', paymentGatewayCategory)
      .order('position');
  return pickableGateways([
    for (final r in rows)
      (
        id: r['id'] as String,
        values: {
          'providerId': r['providerId'],
          'providerName': r['providerName'],
          'accountName': r['accountName'],
          'mode': r['mode'],
          'active': r['active'],
        }..removeWhere((_, v) => v == null),
      ),
  ]);
});

class CommerceRepository {
  CommerceRepository(this._db);
  final SupabaseClient _db;

  String get _now => DateTime.now().toUtc().toIso8601String();

  // ---- GET.coin ------------------------------------------------------------

  Future<GetCoinSettings> getCoinSettings() async {
    final row = await _db.from('get_coin_settings').select().eq('id', 'master').maybeSingle();
    return row == null ? const GetCoinSettings() : GetCoinSettings.fromRow(row);
  }

  /// `get_coin_market_stats` RPC (read-only); zeros when not migrated.
  Future<CoinMarketStats> coinMarketStats() async {
    try {
      return CoinMarketStats.fromRpc(await _db.rpc('get_coin_market_stats'));
    } catch (_) {
      return const CoinMarketStats();
    }
  }

  /// Upserts the master row. On a database missing the market/referral
  /// columns it retries with the base rates only, then the rate alone, as
  /// Expo does.
  Future<void> saveGetCoin(Map<String, dynamic> row) async {
    try {
      await _db.from('get_coin_settings').upsert(row, onConflict: 'id');
    } on PostgrestException catch (e) {
      if (!_isMissingColumn(e)) rethrow;
      try {
        await _db.from('get_coin_settings').upsert(
          {for (final k in getCoinBaseColumns) k: row[k]},
          onConflict: 'id',
        );
      } on PostgrestException catch (e2) {
        if (!_isMissingColumn(e2)) rethrow;
        await _db
            .from('get_coin_settings')
            .upsert({'id': 'master', 'coins_per_currency': row['coins_per_currency']}, onConflict: 'id');
      }
    }
  }

  static bool _isMissingColumn(PostgrestException e) =>
      e.code == '42703' || e.code == 'PGRST204' || e.message.toLowerCase().contains('column');

  // ---- Bulk helpers --------------------------------------------------------

  /// Clears `isDefault` on every other entry (single-default categories).
  Future<void> clearOtherDefaults(String key, List<Entry> all, String? keepId) async {
    final table = commerceCategories[key]!.table;
    for (final e in all) {
      if (e.id == keepId || e.values['isDefault'] != true) continue;
      await _db.from(table).update({'values': {...e.values, 'isDefault': false}, 'updated_at': _now}).eq('id', e.id);
    }
  }

  /// Inserts the id of a new row so callers can reference it (e.g. default).
  Future<String> insertEntry(String key, Map<String, dynamic> values, int position) async {
    final c = commerceCategories[key]!;
    final row = await _db
        .from(c.table)
        .insert({
          if (c.usesCategoryColumn) 'category': c.key,
          'values': values,
          'position': position,
          'active': true,
        })
        .select('id')
        .single();
    return row['id'] as String;
  }

  // ---- EV orders (owner-scoped `ev_orders`) --------------------------------

  Future<List<EvOrderRow>> evOrders() async {
    final rows = await _db.from('ev_orders').select('id, user_id, values, created_at').order('created_at', ascending: false);
    return rows.map(EvOrderRow.fromRow).toList();
  }

  /// Merges [patch] into the freshest stored copy (Expo `patchOrder` reads
  /// the latest entry rather than the stale selection).
  Future<Map<String, dynamic>> patchEvOrder(String id, Map<String, dynamic> patch) async {
    final row = await _db.from('ev_orders').select('values').eq('id', id).single();
    final merged = {...Map<String, dynamic>.from((row['values'] as Map?) ?? const {}), ...patch};
    await _db.from('ev_orders').update({'values': merged, 'updated_at': _now}).eq('id', id);
    return merged;
  }
}

class EvOrderRow {
  EvOrderRow({required this.id, required this.values, this.userId, this.createdAt});

  factory EvOrderRow.fromRow(Map<String, dynamic> r) => EvOrderRow(
        id: r['id'] as String,
        userId: r['user_id'] as String?,
        values: Map<String, dynamic>.from((r['values'] as Map?) ?? const {}),
        createdAt: r['created_at'] as String?,
      );

  final String id;
  final String? userId;
  final Map<String, dynamic> values;
  final String? createdAt;
}

final commerceRepositoryProvider = Provider((ref) => CommerceRepository(ref.watch(supabaseProvider)));

final getCoinProvider = FutureProvider.autoDispose(
  (ref) async {
  ref.watchLive('get_coin_settings');
    final repo = ref.watch(commerceRepositoryProvider);
    final results = await Future.wait([repo.getCoinSettings(), repo.coinMarketStats()]);
    return (settings: results[0] as GetCoinSettings, stats: results[1] as CoinMarketStats);
  },
);

final evOrdersProvider = FutureProvider.autoDispose((ref) => ref.watch(commerceRepositoryProvider).evOrders());
