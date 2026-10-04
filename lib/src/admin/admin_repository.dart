import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_access.dart';
import 'admin_settings_models.dart';

/// Data access for the admin panel. Every call runs with the signed-in
/// user's session, so the database's `caller_is_admin()` RLS policies are the
/// real gate; this class never needs (or holds) a service-role key.
class AdminRepository {
  AdminRepository(this._db);
  final SupabaseClient _db;

  String? get _uid => _db.auth.currentUser?.id;
  String get _now => DateTime.now().toUtc().toIso8601String();

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
      List<Map<String, dynamic>>.from(await _db.from('admin_access').select().order('created_at'));

  Future<void> grant({required String profileId, required String page, required bool edit, String? notes}) =>
      _db.from('admin_access').insert({
        'profile_id': profileId,
        'page': page,
        'access_level': edit ? 'edit' : 'read',
        'notes': notes,
      });

  Future<void> revoke(String grantId) => _db.from('admin_access').delete().eq('id', grantId);

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

  // ---- Dashboard -----------------------------------------------------------

  Future<int> _count(String table, [PostgrestFilterBuilder<dynamic> Function(PostgrestFilterBuilder<dynamic>)? f]) async {
    try {
      PostgrestFilterBuilder<dynamic> q = _db.from(table).select('id');
      if (f != null) q = f(q);
      final res = await q.count(CountOption.exact);
      return res.count;
    } catch (_) {
      return -1; // table missing or not readable
    }
  }

  Future<Map<String, int>> dashboardCounts() async {
    final results = await Future.wait([
      _count('profiles'),
      _count('partners'),
      _count('partners', (q) => q.eq('status', 'unapproved')),
      _count('vehicle'),
      _count('ride_requests', (q) => q.eq('status', 'open')),
      _count('ride_requests', (q) => q.inFilter('status', ['accepted', 'arrived', 'on_trip'])),
      _count('ride_requests', (q) => q.eq('status', 'completed')),
      _count('provider_documents', (q) => q.eq('status', 'Pending Review')),
      _count('vehicle_documents', (q) => q.eq('status', 'Pending Review')),
      _count('support_tickets', (q) => q.neq('status', 'closed')),
    ]);
    const keys = [
      'users', 'partners', 'partnersPending', 'vehicles', 'ridesOpen', 'ridesActive',
      'ridesCompleted', 'providerDocsPending', 'vehicleDocsPending', 'ticketsOpen',
    ];
    return {for (var i = 0; i < keys.length; i++) keys[i]: results[i]};
  }

  // ---- People & vehicles ---------------------------------------------------

  Future<List<Map<String, dynamic>>> users() async =>
      List<Map<String, dynamic>>.from(await _db.from('profiles').select().order('joined_at', ascending: false));

  /// Mirrors Expo `upsertUser`: `profile_status` carries the admin decision;
  /// `status` mirrors it except for "deleted", which `user_status` lacks.
  Future<void> setUserStatus(String id, String status) => _db.from('profiles').update({
        'profile_status': switch (status) {
          'approved' => 'Approved',
          'blocked' => 'Blocked',
          'rejected' => 'Rejected',
          'deleted' => 'Deleted',
          _ => 'Un-Approved',
        },
        if (status != 'deleted') 'status': status,
        'updated_at': _now,
      }).eq('id', id);

  Future<List<Map<String, dynamic>>> partners() async =>
      List<Map<String, dynamic>>.from(await _db.from('partners').select().order('joined_at', ascending: false));

  Future<void> updatePartner(String id, Map<String, dynamic> patch) =>
      _db.from('partners').update({...patch, 'updated_at': _now}).eq('id', id);

  Future<List<Map<String, dynamic>>> vehicles() async =>
      List<Map<String, dynamic>>.from(await _db.from('vehicle').select().order('joined_at', ascending: false));

  Future<void> updateVehicle(String id, Map<String, dynamic> patch) =>
      _db.from('vehicle').update({...patch, 'updated_at': _now}).eq('id', id);

  // ---- Documents -----------------------------------------------------------

  Future<List<Map<String, dynamic>>> documents(String table) async => List<Map<String, dynamic>>.from(
        await _db.from(table).select().order('uploaded_at', ascending: false).limit(500),
      );

  Future<void> reviewDocument(String table, String id, String status, String? notes) =>
      _db.from(table).update({
        'status': status,
        'reviewer_notes': notes,
        'reviewed_at': _now,
      }).eq('id', id);

  // ---- Rides ---------------------------------------------------------------

  Future<List<Map<String, dynamic>>> rides({List<String>? statuses, int limit = 200}) async {
    var q = _db.from('ride_requests').select();
    if (statuses != null && statuses.isNotEmpty) q = q.inFilter('status', statuses);
    return List<Map<String, dynamic>>.from(await q.order('created_at', ascending: false).limit(limit));
  }

  Future<void> adminCancelRide(String id, String reason) => _db.from('ride_requests').update({
        'status': 'cancelled',
        'cancelled_at': _now,
        'cancel_reason': reason,
      }).eq('id', id);

  // ---- Support -------------------------------------------------------------

  Future<List<Map<String, dynamic>>> tickets() async => List<Map<String, dynamic>>.from(
        await _db.from('support_tickets').select().order('last_message_at', ascending: false, nullsFirst: false),
      );

  Future<void> setTicketStatus(String id, String status) =>
      _db.from('support_tickets').update({'status': status, 'updated_at': _now}).eq('id', id);

  Future<void> assignTicketToMe(String id, String myName) => _db.from('support_tickets').update({
        'assigned_admin_id': _uid,
        'assigned_admin_name': myName,
        'assigned_at': _now,
        'status': 'in_progress',
      }).eq('id', id);

  Future<List<Map<String, dynamic>>> ticketMessages(String ticketId) async => List<Map<String, dynamic>>.from(
        await _db.from('support_messages').select().eq('ticket_id', ticketId).order('created_at'),
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

  Future<Map<String, dynamic>> sendPush(String title, String body, String audience) async {
    final res = await _db.functions.invoke('send-push', body: {'title': title, 'body': body, 'audience': audience});
    final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : <String, dynamic>{};
    if (data['error'] != null) throw Exception(data['error']);
    return data;
  }

  Future<List<Map<String, dynamic>>> pushHistory() async => List<Map<String, dynamic>>.from(
        await _db.from('push_notifications').select().order('created_at', ascending: false).limit(50),
      );

  // ---- Commission ----------------------------------------------------------

  Future<List<Map<String, dynamic>>> commissionRates() async => List<Map<String, dynamic>>.from(
        await _db.from('commission_rates').select().order('updated_at', ascending: false),
      );

  Future<void> saveCommissionRate(Map<String, dynamic> row) {
    final data = {...row, 'updated_at': _now};
    return row['id'] == null
        ? _db.from('commission_rates').insert(data..remove('id'))
        : _db.from('commission_rates').update(data).eq('id', row['id'] as Object);
  }

  Future<void> deleteCommissionRate(String id) => _db.from('commission_rates').delete().eq('id', id);

  // ---- Settings ------------------------------------------------------------

  Future<List<SettingEntry>> settings(SettingsCategory c) async {
    var q = _db.from(c.table).select('id, values, position, active');
    if (c.usesCategoryColumn) q = q.eq('category', c.key);
    final rows = await q.order('position');
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
      return _db.from(c.table).update({'values': values, 'updated_at': _now}).eq('id', id);
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
