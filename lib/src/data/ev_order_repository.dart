import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../providers.dart';

typedef EvEntry = ({String id, Map<String, dynamic> values});
typedef EvOrder = ({String id, Map<String, dynamic> values, DateTime createdAt});

/// Everything the wizard picks from, set up by the back office (Admin →
/// Settings → TEKSI EV). Read-only to customers.
class EvCatalog {
  const EvCatalog({
    this.vehicles = const [],
    this.inventory = const [],
    this.advisors = const [],
    this.financeOptions = const [],
    this.fees = const [],
    this.checklist = const [],
  });

  final List<EvEntry> vehicles;
  final List<EvEntry> inventory;
  final List<EvEntry> advisors;
  final List<EvEntry> financeOptions;
  final List<EvEntry> fees;

  /// The delivery checklist's item names, in order.
  final List<String> checklist;
}

/// The customer's TEKSI EV orders (Expo `evOrderStore` + the `ev-orders`
/// category of `adminSync`). Orders live in `ev_orders`, readable and
/// writable only by their owner and admins.
class EvOrderRepository {
  EvOrderRepository(this._db);
  final SupabaseClient _db;

  static const activeOrderKey = 'ev_active_order_v1';

  String? get _uid => _db.auth.currentUser?.id;

  Future<List<EvEntry>> _entries(String table, {String? category}) async {
    try {
      var q = _db.from(table).select('id, values, position');
      if (category != null) q = q.eq('category', category);
      final rows = await q.order('position');
      return [
        for (final r in rows)
          (id: '${r['id']}', values: Map<String, dynamic>.from((r['values'] as Map?) ?? const {})),
      ];
    } catch (_) {
      // A catalogue that is missing or unreadable is an empty one.
      return const [];
    }
  }

  Future<EvCatalog> catalog() async {
    final r = await Future.wait([
      _entries('ev_vehicle_details'),
      _entries('ev_vehicle_inventory'),
      _entries('ev_delivery_advisors'),
      _entries('ev_finance_options'),
      _entries('ev_order_fee'),
      _entries('settings_entries', category: 'ev-delivery-checklist'),
    ]);
    return EvCatalog(
      vehicles: r[0],
      inventory: r[1],
      advisors: r[2],
      financeOptions: r[3],
      fees: r[4],
      checklist: [
        for (final c in r[5]) '${c.values['name'] ?? c.values['title'] ?? 'Item'}',
      ],
    );
  }

  Future<List<EvOrder>> myOrders() async {
    final uid = _uid;
    if (uid == null) return const [];
    final rows = await _db
        .from('ev_orders')
        .select('id, values, created_at')
        .eq('user_id', uid)
        .order('created_at', ascending: false);
    return [
      for (final r in rows)
        (
          id: '${r['id']}',
          values: Map<String, dynamic>.from((r['values'] as Map?) ?? const {}),
          createdAt: DateTime.tryParse('${r['created_at']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
        ),
    ];
  }

  Future<EvOrder?> order(String id) async {
    final row = await _db.from('ev_orders').select('id, values, created_at').eq('id', id).maybeSingle();
    if (row == null) return null;
    return (
      id: '${row['id']}',
      values: Map<String, dynamic>.from((row['values'] as Map?) ?? const {}),
      createdAt: DateTime.tryParse('${row['created_at']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// Creates the order (the user id is stamped by the database).
  Future<String> create(Map<String, dynamic> values) async {
    final id = const Uuid().v4();
    await _db.from('ev_orders').insert({'id': id, 'values': values, 'position': 0});
    await rememberActive(id);
    return id;
  }

  /// Merges [patch] into the stored order and answers the result.
  Future<Map<String, dynamic>> patch(String id, Map<String, dynamic> patch) async {
    final row = await _db.from('ev_orders').select('values').eq('id', id).single();
    final merged = {...Map<String, dynamic>.from((row['values'] as Map?) ?? const {}), ...patch};
    await _db.from('ev_orders').update({'values': merged}).eq('id', id);
    return merged;
  }

  /// Stores a photo of the owner's ID and answers its URL.
  Future<String> uploadIdImage(String orderId, Uint8List bytes, String ext) async {
    final path = 'ev-orders/${_uid ?? 'anon'}/$orderId-${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _db.storage.from('ID_Image').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(upsert: true, contentType: ext == 'png' ? 'image/png' : 'image/jpeg'),
        );
    return _db.storage.from('ID_Image').getPublicUrl(path);
  }

  /// The order this phone was last working on.
  Future<String?> activeOrderId() async {
    final id = (await SharedPreferences.getInstance()).getString(activeOrderKey);
    return id == null || id.isEmpty ? null : id;
  }

  Future<void> rememberActive(String? id) async {
    final p = await SharedPreferences.getInstance();
    id == null ? await p.remove(activeOrderKey) : await p.setString(activeOrderKey, id);
  }
}

final evOrderRepositoryProvider = Provider((ref) => EvOrderRepository(ref.watch(supabaseProvider)));

final evCatalogProvider = FutureProvider.autoDispose((ref) => ref.watch(evOrderRepositoryProvider).catalog());
