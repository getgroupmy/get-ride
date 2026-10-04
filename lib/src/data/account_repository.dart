import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';

/// Profile, partner record, wallet, emergency contacts and support — the
/// per-user tables, all protected by "own row" RLS policies.
class AccountRepository {
  AccountRepository(this._db);
  final SupabaseClient _db;

  String get _uid {
    final id = _db.auth.currentUser?.id;
    if (id == null) throw StateError('Not signed in');
    return id;
  }

  // ---- Profile -----------------------------------------------------------

  Future<Profile?> profile() async {
    final row = await _db.from('profiles').select().eq('id', _uid).maybeSingle();
    return row == null ? null : Profile(row);
  }

  Future<void> updateProfile({String? name, String? email}) async {
    await _db.from('profiles').update({
      'name': ?name,
      'email': ?email,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', _uid);
  }

  /// The partner (driver) record linked to this login, if any.
  Future<Partner?> partner() async {
    final row = await _db
        .from('partners')
        .select()
        .eq('auth_user_id', _uid)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    return row == null ? null : Partner(row);
  }

  // ---- Wallet ------------------------------------------------------------

  Future<List<WalletBalance>> walletBalances() async {
    final rows = await _db
        .from('wallets')
        .select('wallet_type, balance, currency')
        .eq('user_id', _uid);
    return rows.map(WalletBalance.fromRow).toList();
  }

  Future<List<WalletTransaction>> walletTransactions({String? walletType, int limit = 100}) async {
    var q = _db
        .from('wallet_transactions')
        .select('id, wallet_type, kind, amount, balance_after, method, note, status, created_at')
        .eq('user_id', _uid);
    if (walletType != null) q = q.eq('wallet_type', walletType);
    final rows = await q.order('created_at', ascending: false).limit(limit);
    return rows.map(WalletTransaction.new).toList();
  }

  // ---- Emergency contacts ------------------------------------------------

  Future<List<EmergencyContact>> emergencyContacts() async {
    final rows = await _db
        .from('emergency_contacts')
        .select()
        .eq('profile_id', _uid)
        .order('created_at');
    return rows.map(EmergencyContact.fromRow).toList();
  }

  Future<void> saveEmergencyContact({String? id, required String name, required String phone}) async {
    if (id == null) {
      await _db.from('emergency_contacts').insert({'profile_id': _uid, 'name': name, 'phone': phone});
    } else {
      await _db.from('emergency_contacts').update({
        'name': name,
        'phone': phone,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', id);
    }
  }

  Future<void> deleteEmergencyContact(String id) =>
      _db.from('emergency_contacts').delete().eq('id', id);

  // ---- Support -----------------------------------------------------------

  Future<List<SupportTicket>> tickets() async {
    final rows = await _db
        .from('support_tickets')
        .select()
        .eq('profile_id', _uid)
        .order('last_message_at', ascending: false, nullsFirst: false);
    return rows.map(SupportTicket.new).toList();
  }

  /// Reuses the newest non-closed ticket, or opens a new one (Expo
  /// `getOrCreateTicket`).
  Future<SupportTicket> openTicket(String subject) async {
    final existing = await _db
        .from('support_tickets')
        .select()
        .eq('profile_id', _uid)
        .neq('status', 'closed')
        .order('last_message_at', ascending: false, nullsFirst: false)
        .limit(1)
        .maybeSingle();
    if (existing != null) return SupportTicket(existing);
    final row = await _db
        .from('support_tickets')
        .insert({'profile_id': _uid, 'subject': subject})
        .select()
        .single();
    return SupportTicket(row);
  }

  Future<List<SupportMessage>> messages(String ticketId) async {
    final rows = await _db
        .from('support_messages')
        .select()
        .eq('ticket_id', ticketId)
        .order('created_at');
    return rows.map(SupportMessage.new).toList();
  }

  Future<void> sendMessage(String ticketId, String body, {String? senderName}) async {
    final text = body.trim();
    if (text.isEmpty) return;
    await _db.from('support_messages').insert({
      'ticket_id': ticketId,
      'sender_role': 'user',
      'sender_id': _uid,
      'sender_name': senderName,
      'type': 'text',
      'body': text,
      'status': 'sent',
    });
    // Bump the ticket summary; the admin-side unread counter goes up.
    final t = await _db.from('support_tickets').select('unread_admin').eq('id', ticketId).maybeSingle();
    await _db.from('support_tickets').update({
      'last_message': text,
      'last_message_at': DateTime.now().toUtc().toIso8601String(),
      'last_sender_role': 'user',
      'unread_admin': ((t?['unread_admin'] as num?)?.toInt() ?? 0) + 1,
    }).eq('id', ticketId);
  }

  Future<void> markTicketRead(String ticketId) =>
      _db.from('support_tickets').update({'unread_user': 0}).eq('id', ticketId);

  /// Live message thread for one ticket.
  Stream<List<SupportMessage>> watchMessages(String ticketId) {
    final controller = StreamController<List<SupportMessage>>();
    RealtimeChannel? channel;
    Future<void> refresh() async {
      try {
        final list = await messages(ticketId);
        if (!controller.isClosed) controller.add(list);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      }
    }

    controller.onListen = () {
      refresh();
      channel = _db
          .channel('support_${ticketId}_${DateTime.now().microsecondsSinceEpoch}')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'support_messages',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'ticket_id',
              value: ticketId,
            ),
            callback: (_) => refresh(),
          )
          .subscribe();
    };
    controller.onCancel = () async {
      if (channel != null) await _db.removeChannel(channel!);
      await controller.close();
    };
    return controller.stream;
  }
}
