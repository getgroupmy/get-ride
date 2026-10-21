import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/commission_promotions.dart';
import '../core/promo_codes.dart';
import '../core/commission_settings.dart';
import '../core/fare_tariff.dart' show fareTariffRowWithoutServices;
import 'admin_access.dart';
import 'admin_filters.dart' show RowsPage, adminPeoplePageSize, rowsPage, searchOrFilter, userSearchColumns;
import 'admin_settings_models.dart';
import 'profile_search.dart';
import 'saved_push.dart';
import 'screens/support_agents.dart';
import '../core/notification_delivery.dart';

/// Data access for the admin panel. Every call runs with the signed-in
/// user's session, so the database's `caller_is_admin()` RLS policies are the
/// real gate; this class never needs (or holds) a service-role key.
class AdminRepository {
  AdminRepository(this._db);
  final SupabaseClient _db;

  String? get _uid => _db.auth.currentUser?.id;
  String get _now => DateTime.now().toUtc().toIso8601String();

  /// Updates one row and fails loudly when RLS (or a stale id) lets nothing
  /// change. PostgREST reports a filtered-out UPDATE as success with zero
  /// rows, which would otherwise read as "Saved".
  Future<void> _updateOne(String table, String id, Map<String, dynamic> patch) async {
    final rows = await _db.from(table).update(patch).eq('id', id).select('id');
    if (rows.isEmpty) {
      throw StateError(
        'Nothing was saved: the database did not allow this change to $table. '
        'Your account may lack an admin policy for it, or the record no longer exists.',
      );
    }
  }

  // ---- Access --------------------------------------------------------------

  Future<AdminAccess> myAccess() async {
    final uid = _uid;
    if (uid == null) return AdminAccess.none;
    final rows = await _db.from('admin_access').select().eq('profile_id', uid);
    return AdminAccess(rows.map(AdminGrant.fromRow).toList());
  }

  /// Makes the caller the first full admin when `admin_access` is empty
  /// (server-side `admin_access_bootstrap()`); false when admins exist.
  Future<bool> bootstrap() async => (await _db.rpc('admin_access_bootstrap')) == true;

  Future<List<Map<String, dynamic>>> allGrants() async =>
      List<Map<String, dynamic>>.from(await _db.from('admin_access').select().order('created_at', ascending: false));

  Future<void> grant({required String profileId, required String page, required bool edit, String? notes}) =>
      _db.from('admin_access').insert({
        'profile_id': profileId,
        'page': page,
        'access_level': edit ? 'edit' : 'read',
        'notes': notes,
      });

  Future<void> revoke(String grantId) => _db.from('admin_access').delete().eq('id', grantId);

  /// Writes one person's grants in one go: upserts by (profile, page), so an
  /// existing grant changes level instead of failing on the unique key, then
  /// deletes the pages taken away. Every grant carries the same [notes].
  Future<void> setGrants({
    required String profileId,
    required List<({String page, bool edit})> upserts,
    required List<String> deletes,
    String? notes,
  }) async {
    if (upserts.isNotEmpty) {
      await _db.from('admin_access').upsert([
        for (final u in upserts)
          {'profile_id': profileId, 'page': u.page, 'access_level': u.edit ? 'edit' : 'read', 'notes': notes},
      ], onConflict: 'profile_id,page');
    }
    if (deletes.isNotEmpty) await _db.from('admin_access').delete().inFilter('id', deletes);
  }

  Future<Map<String, dynamic>?> profileByPhone(String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    final rows = await _db
        .from('profiles')
        .select('id, name, phone, display_id')
        // Stored with or without the leading +; `in` quotes both safely.
        .inFilter('phone', ['+$digits', digits])
        .limit(1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, Map<String, dynamic>>> profilesByIds(Iterable<String> ids) async {
    final list = ids.toSet().toList();
    if (list.isEmpty) return {};
    final rows = await _db.from('profiles').select('id, name, phone, display_id').inFilter('id', list);
    return {for (final r in rows) r['id'] as String: r};
  }

  // ---- People & vehicles ---------------------------------------------------

  /// The newest [limit] users, or those matching [query] in any of the
  /// [userSearchColumns] (PERF-55: never the whole table). One row past
  /// [limit] is asked for only to know whether there are more.
  Future<RowsPage> users({int limit = adminPeoplePageSize, String query = ''}) async {
    var q = _db.from('profiles').select();
    final or = searchOrFilter(query, userSearchColumns);
    if (or != null) q = q.or(or);
    final rows = await q.order('joined_at', ascending: false).order('id', ascending: false).range(0, limit);
    return rowsPage(List<Map<String, dynamic>>.from(rows), limit);
  }

  /// Mirrors Expo `upsertUser`: `profile_status` carries the admin decision;
  /// `status` mirrors it except for "deleted", which `user_status` lacks.
  Future<void> setUserStatus(String id, String status) => _updateOne('profiles', id, {
        'profile_status': switch (status) {
          'approved' => 'Approved',
          'blocked' => 'Blocked',
          'rejected' => 'Rejected',
          'deleted' => 'Deleted',
          _ => 'Un-Approved',
        },
        if (status != 'deleted') 'status': status,
        'updated_at': _now,
      });

  Future<List<Map<String, dynamic>>> partners() async =>
      List<Map<String, dynamic>>.from(await _db.from('partners').select().order('joined_at', ascending: false));

  Future<void> updatePartner(String id, Map<String, dynamic> patch) =>
      _updateOne('partners', id, {...patch, 'updated_at': _now});

  Future<List<Map<String, dynamic>>> vehicles() async =>
      List<Map<String, dynamic>>.from(await _db.from('vehicle').select().order('joined_at', ascending: false));

  Future<void> updateVehicle(String id, Map<String, dynamic> patch) =>
      _updateOne('vehicle', id, {...patch, 'updated_at': _now});

  // ---- Documents -----------------------------------------------------------

  Future<List<Map<String, dynamic>>> documents(String table) async => List<Map<String, dynamic>>.from(
        await _db.from(table).select().order('uploaded_at', ascending: false).limit(500),
      );

  /// Whose documents these are: partner names (by partner id) and, for
  /// vehicle documents, plates (by vehicle id). One query per kind.
  Future<({Map<String, Map<String, dynamic>> partners, Map<String, Map<String, dynamic>> vehicles})> documentOwners(
    Iterable<String> partnerIds,
    Iterable<String> vehicleIds,
  ) async {
    final p = partnerIds.toSet().toList(), v = vehicleIds.toSet().toList();
    final partners = p.isEmpty ? const [] : await _db.from('partners').select('id, name, phone').inFilter('id', p);
    final vehicles = v.isEmpty ? const [] : await _db.from('vehicle').select('id, plate').inFilter('id', v);
    return (
      partners: {for (final r in partners) '${r['id']}': Map<String, dynamic>.from(r as Map)},
      vehicles: {for (final r in vehicles) '${r['id']}': Map<String, dynamic>.from(r as Map)},
    );
  }

  /// Corrects a document's details (Expo `DocumentMetadataEditModal`).
  Future<void> updateDocument(String table, String id, Map<String, dynamic> patch) => _updateOne(table, id, patch);

  /// Removes a document row; the partner is asked for it again.
  Future<void> deleteDocument(String table, String id) async {
    final rows = await _db.from(table).delete().eq('id', id).select('id');
    if (rows.isEmpty) throw StateError('Nothing was deleted: the database did not allow it, or it is already gone.');
  }

  Future<void> reviewDocument(String table, String id, String status, String? notes) =>
      _updateOne(table, id, {
        'status': status,
        'reviewer_notes': notes,
        'reviewed_at': _now,
      });

  // ---- Rides ---------------------------------------------------------------

  Future<List<Map<String, dynamic>>> rides({List<String>? statuses, int limit = 200}) async {
    var q = _db.from('ride_requests').select();
    if (statuses != null && statuses.isNotEmpty) q = q.inFilter('status', statuses);
    final rows = List<Map<String, dynamic>>.from(await q.order('created_at', ascending: false).limit(limit));
    // While a request is open its passenger details wait aside (0195).
    final open = [
      for (final r in rows)
        if (r['status'] == 'open') r['id'],
    ];
    if (open.isEmpty) return rows;
    try {
      final aside = {
        for (final p in await _db.from('ride_request_private').select().inFilter('request_id', open))
          p['request_id']: p,
      };
      return [
        for (final r in rows)
          {
            ...r,
            for (final e in (aside[r['id']] ?? const {}).entries)
              if (e.value != null && e.key != 'request_id' && e.key != 'updated_at') e.key: e.value,
          },
      ];
    } catch (_) {
      return rows;
    }
  }

  Future<void> adminCancelRide(String id, String reason) => _updateOne('ride_requests', id, {
        'status': 'cancelled',
        'cancelled_at': _now,
        'cancel_reason': reason,
      });

  // ---- Support -------------------------------------------------------------

  Future<List<Map<String, dynamic>>> tickets() async => List<Map<String, dynamic>>.from(
        await _db.from('support_tickets').select().order('last_message_at', ascending: false, nullsFirst: false),
      );

  Future<void> setTicketStatus(String id, String status) =>
      _updateOne('support_tickets', id, {'status': status, 'updated_at': _now});

  /// Admins who can handle support (`support_agents()` RPC, 0069).
  Future<List<SupportAgent>> supportAgents() async =>
      supportAgentsFromRows(List<dynamic>.from(await _db.rpc('support_agents') as List));

  /// Hands a ticket to [agentId] (Expo `assignTicket`); the status is left
  /// as it is.
  Future<void> assignTicket(String id, String agentId, String agentName) => _updateOne('support_tickets', id, {
        'assigned_admin_id': agentId,
        'assigned_admin_name': agentName,
        'assigned_at': _now,
      });

  Future<void> assignTicketToMe(String id, String myName) => _updateOne('support_tickets', id, {
        'assigned_admin_id': _uid,
        'assigned_admin_name': myName,
        'assigned_at': _now,
        'status': 'in_progress',
      });

  Future<List<Map<String, dynamic>>> ticketMessages(String ticketId) async => List<Map<String, dynamic>>.from(
        await _db.from('support_messages').select().eq('ticket_id', ticketId).order('created_at', ascending: true),
      );

  Future<void> replyToTicket(String ticketId, String body, String myName) async {
    final text = body.trim();
    if (text.isEmpty) return;
    await _db.from('support_messages').insert({
      'ticket_id': ticketId,
      'sender_role': 'admin',
      'sender_id': _uid,
      'sender_name': myName,
      'type': 'text',
      'body': text,
      'status': 'sent',
    });
    final t = await _db.from('support_tickets').select('unread_user').eq('id', ticketId).maybeSingle();
    await _db.from('support_tickets').update({
      'last_message': text,
      'last_message_at': _now,
      'last_sender_role': 'admin',
      'unread_user': ((t?['unread_user'] as num?)?.toInt() ?? 0) + 1,
      'unread_admin': 0,
    }).eq('id', ticketId);
  }

  // ---- Push ----------------------------------------------------------------

  /// Sends a broadcast, or with [dryRun] only counts who it would reach.
  /// [area] (PushArea.toJson) narrows it to the phones last seen there.
  Future<Map<String, dynamic>> sendPush(
    String title,
    String body,
    String audience, {
    Map<String, dynamic>? area,
    bool dryRun = false,
  }) async {
    final res = await _db.functions.invoke('send-push', body: {
      'title': title,
      'body': body,
      'audience': audience,
      'area': ?area,
      if (dryRun) 'dryRun': true,
    });
    final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : <String, dynamic>{};
    if (data['error'] != null) throw Exception(data['error']);
    return data;
  }

  Future<List<Map<String, dynamic>>> pushHistory() async => List<Map<String, dynamic>>.from(
        await _db.from('push_notifications').select().order('created_at', ascending: false).limit(50),
      );

  /// Saved, re-sendable notifications: `settings_entries` rows under
  /// `push-notification`, where Expo kept them (see `saved_push.dart`).
  Future<List<SavedPush>> savedPushes() async => savedPushesFrom(await settings(savedPushCategory));

  Future<void> savePushTemplate({String? id, required Map<String, dynamic> values}) =>
      saveSetting(savedPushCategory, id: id, values: values);

  Future<void> deleteSavedPush(String id) => deleteSetting(savedPushCategory, id);

  /// How trip pushes were delivered over the last [hours] (migration 0144).
  /// Empty on a database without it.
  Future<List<NotificationDelivery>> notificationDelivery({int hours = 24}) async {
    try {
      final rows = await _db.rpc('notification_delivery_stats', params: {'p_hours': hours});
      return [
        for (final r in (rows as List? ?? const []))
          if (r is Map) NotificationDelivery.fromRow(Map<String, dynamic>.from(r)),
      ];
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202' || e.code == '42883') return const [];
      rethrow;
    }
  }

  // ---- Commission ----------------------------------------------------------

  Future<List<Map<String, dynamic>>> commissionRates() async => List<Map<String, dynamic>>.from(
        await _db.from('commission_rates').select().order('updated_at', ascending: false),
      );

  Future<void> saveCommissionRate(Map<String, dynamic> row) {
    final data = {...row, 'updated_at': _now};
    return row['id'] == null
        ? _db.from('commission_rates').insert(data..remove('id'))
        : _updateOne('commission_rates', row['id'] as String, data);
  }

  Future<void> deleteCommissionRate(String id) => _db.from('commission_rates').delete().eq('id', id);

  /// Turns one rule on or off without touching the rest of it.
  Future<void> setCommissionRateActive(String id, bool active) =>
      _updateOne('commission_rates', id, {'active': active, 'updated_at': _now});

  /// Every change to the rates, newest first (0216): who, when, before and
  /// after.
  Future<List<Map<String, dynamic>>> commissionHistory({int limit = 100}) async => List<Map<String, dynamic>>.from(
        await _db.from('commission_rate_history').select().order('changed_at', ascending: false).limit(limit),
      );

  /// Completed trips whose commission was never charged (0216).
  Future<List<Map<String, dynamic>>> unchargedCommissions() async =>
      List<Map<String, dynamic>>.from(await _db.rpc('admin_uncharged_commissions') as List);

  /// Charges every completed trip still uncharged; answers how many were
  /// charged and how many failed again.
  Future<({int charged, int failed})> chargeUnchargedCommissions() async {
    final r = Map<String, dynamic>.from(await _db.rpc('admin_charge_uncharged_commissions') as Map);
    return (charged: (r['charged'] as num?)?.toInt() ?? 0, failed: (r['failed'] as num?)?.toInt() ?? 0);
  }

  // ---- Commission settings and tiers (0218) ----
  Future<CommissionConfig> commissionConfig() async => CommissionConfig.fromJson(await _db.rpc('commission_config'));

  Future<CommissionConfig> saveCommissionConfig(CommissionConfig c) async =>
      CommissionConfig.fromJson(await _db.rpc('set_commission_config', params: {'p_config': c.toJson()}));

  Future<List<CommissionTier>> commissionTiers() async => [
        for (final r in await _db.from('commission_tiers').select().order('position', ascending: true).order('created_at', ascending: true) as List)
          CommissionTier.fromRow(Map<String, dynamic>.from(r as Map)),
      ];

  Future<void> saveCommissionTier(CommissionTier t) {
    final row = t.toRow();
    return t.id == null
        ? _db.from('commission_tiers').insert(row..remove('id'))
        : _db.from('commission_tiers').update(row..remove('id')).eq('id', t.id!);
  }

  Future<void> deleteCommissionTier(String id) => _db.from('commission_tiers').delete().eq('id', id);

  /// Surcharge names seen on trips over the last year (0201), to tick for the base.
  Future<List<({String name, int trips})>> surchargeNamesSeen() async => [
        for (final r in await _db.rpc('statement_surcharge_names') as List)
          (name: '${(r as Map)['name']}', trips: (r['trips'] as num?)?.toInt() ?? 0),
      ];

  // ---- Rider promo codes (0242) ----
  Future<List<PromoCode>> promoCodes() async => [
        for (final r in await _db.from('promo_codes').select().order('created_at', ascending: false) as List)
          PromoCode.fromRow(Map<String, dynamic>.from(r as Map)),
      ];

  Future<void> savePromoCode(PromoCode p) {
    final row = p.toRow();
    return p.id == null
        ? _db.from('promo_codes').insert(row)
        : _db.from('promo_codes').update(row).eq('id', p.id!);
  }

  Future<void> deletePromoCode(String id) => _db.from('promo_codes').delete().eq('id', id);

  /// Per code: how many trips it settled, the discount given, the last one.
  Future<Map<String, ({int uses, double discount, DateTime? lastAt})>> promoRedemptionStats() async => {
        for (final r in await _db.rpc('admin_promo_redemption_stats') as List)
          '${(r as Map)['code_id']}': (
            uses: (r['uses'] as num?)?.toInt() ?? 0,
            discount: (r['discount'] as num?)?.toDouble() ?? 0,
            lastAt: DateTime.tryParse('${r['last_at']}'),
          ),
      };

  /// A code's latest settled trips.
  Future<List<Map<String, dynamic>>> promoRedemptions(String codeId, {int limit = 30}) async =>
      List<Map<String, dynamic>>.from(await _db
          .from('promo_redemptions')
          .select('ride_id, rider_id, driver_id, fare, discount, payable, driver_credit, created_at')
          .eq('code_id', codeId)
          .order('created_at', ascending: false)
          .limit(limit));

  // ---- Commission promotions and reports (0224) ----
  Future<List<CommissionPromotion>> commissionPromotions() async => [
        for (final r in await _db.from('commission_promotions').select().order('starts_at', ascending: false) as List)
          CommissionPromotion.fromRow(Map<String, dynamic>.from(r as Map)),
      ];

  Future<void> saveCommissionPromotion(CommissionPromotion p) {
    final row = p.toRow()..remove('id');
    return p.id == null
        ? _db.from('commission_promotions').insert(row)
        : _db.from('commission_promotions').update(row).eq('id', p.id!);
  }

  Future<void> deleteCommissionPromotion(String id) => _db.from('commission_promotions').delete().eq('id', id);

  /// Service names seen on trips over the last year, for a promotion's service filter.
  Future<List<({String name, int trips})>> commissionServiceNames() async => [
        for (final r in await _db.rpc('commission_service_names') as List)
          (name: '${(r as Map)['name']}', trips: (r['trips'] as num?)?.toInt() ?? 0),
      ];

  /// Commission charged in [from, to), grouped.
  Future<List<CommissionReportRow>> commissionReport(DateTime from, DateTime to, CommissionReportGroup group) async => [
        for (final r in await _db.rpc('admin_commission_report', params: {
          'p_from': from.toUtc().toIso8601String(),
          'p_to': to.toUtc().toIso8601String(),
          'p_group': group.name,
        }) as List)
          CommissionReportRow.fromRow(Map<String, dynamic>.from(r as Map)),
      ];

  /// Drivers whose GET.credit is under the floor, lowest first.
  Future<List<BelowCreditDriver>> driversBelowCredit() async => [
        for (final r in await _db.rpc('admin_drivers_below_credit') as List)
          BelowCreditDriver.fromRow(Map<String, dynamic>.from(r as Map)),
      ];

  /// People a per-user rule can be about: matched by name, phone, email or
  /// account id, or exactly by profile id. The term is sanitised before it
  /// reaches the `.or()` filter (see `profile_search.dart`).
  Future<List<Map<String, dynamic>>> searchPeople(String query, {int limit = 20}) async {
    const cols = 'id, name, phone, email, display_id';
    final q = query.trim();
    if (isProfileUuid(q)) return List<Map<String, dynamic>>.from(await _db.from('profiles').select(cols).eq('id', q));
    final term = peopleSearchTerm(q);
    if (term == null) return const [];
    return List<Map<String, dynamic>>.from(
      await _db.from('profiles').select(cols).or(peopleOrFilter(term)).order('name', ascending: true).limit(limit),
    );
  }

  /// The people with these profile ids, keyed by id (missing ones left out).
  Future<Map<String, Map<String, dynamic>>> peopleByIds(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final rows = await _db.from('profiles').select('id, name, phone, email, display_id').inFilter('id', ids);
    return {for (final r in rows) '${r['id']}': Map<String, dynamic>.from(r)};
  }

  // ---- Fare tariffs (0109) --------------------------------------------------

  Future<List<Map<String, dynamic>>> fareTariffs() async => List<Map<String, dynamic>>.from(
        await _db.from('fare_tariffs').select().order('updated_at', ascending: false),
      );

  /// Saves a card. A database before migration 0123 has no service
  /// columns: a card for every service is saved without them, and one for
  /// a single service is refused with the reason.
  Future<void> saveFareTariff(Map<String, dynamic> row) async {
    Future<void> write(Map<String, dynamic> r) {
      final data = {...r}..remove('updated_at');
      return r['id'] == null
          ? _db.from('fare_tariffs').insert(data..remove('id'))
          : _updateOne('fare_tariffs', r['id'] as String, data);
    }

    try {
      await write(row);
    } on PostgrestException catch (e) {
      final missing = e.code == '42703' || e.code == 'PGRST204';
      if (!missing || !e.message.contains('service')) rethrow;
      final legacy = fareTariffRowWithoutServices(row);
      if (legacy == null) {
        throw StateError('Fares per service need migration 0123 on the database. Cards for every service still save.');
      }
      await write(legacy);
    }
  }

  Future<void> deleteFareTariff(String id) => _db.from('fare_tariffs').delete().eq('id', id);

  // ---- Settings ------------------------------------------------------------

  Future<List<SettingEntry>> settings(SettingsCategory c) async {
    var q = _db.from(c.table).select('id, values, position, active');
    if (c.usesCategoryColumn) q = q.eq('category', c.key);
    final rows = await q.order('position', ascending: true).order('created_at', ascending: true);
    return rows.map(SettingEntry.fromRow).toList();
  }

  /// Category names present in `settings_entries` (to surface ones that have
  /// no dedicated editor yet).
  Future<List<String>> settingCategoryNames() async {
    final rows = await _db.from('settings_entries').select('category');
    return rows.map((r) => r['category'] as String).toSet().toList()..sort();
  }

  Future<void> saveSetting(SettingsCategory c, {String? id, required Map<String, dynamic> values, int? position}) {
    if (id != null) {
      return _updateOne(c.table, id, {'values': values, 'updated_at': _now});
    }
    return _db.from(c.table).insert({
      if (c.usesCategoryColumn) 'category': c.key,
      'values': values,
      'position': position ?? 0,
      'active': true,
    });
  }

  Future<void> deleteSetting(SettingsCategory c, String id) => _db.from(c.table).delete().eq('id', id);
}
