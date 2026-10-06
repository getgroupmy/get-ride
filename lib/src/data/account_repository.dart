import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/avatar.dart';
import '../core/profile_identity.dart';
import '../core/support_media.dart';
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

  /// [identity] is written as given (see `identityPatch`), so a blank field
  /// clears its column.
  Future<void> updateProfile({String? name, String? email, Map<String, String?>? identity}) async {
    await _db.from('profiles').update({
      'name': ?name,
      'email': ?email,
      ...?identity,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', _uid);
  }

  /// Uploads a profile photo to this account's folder in `avatars` and
  /// saves its public URL on the profile. Returns the URL.
  Future<String> uploadAvatar(Uint8List bytes, {required String ext, required String contentType}) async {
    final path = avatarStoragePath(_uid, ext, DateTime.now());
    final bucket = _db.storage.from('avatars');
    await bucket.uploadBinary(path, bytes, fileOptions: FileOptions(upsert: true, contentType: contentType));
    final url = bucket.getPublicUrl(path);
    await _db.from('profiles').update({
      'avatar_url': url,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', _uid);
    return url;
  }

  /// Uploads a photo of the rider's passport or ID to their folder in
  /// `ID_Image` and saves its public URL on `profiles.id_image`.
  Future<String> uploadIdImage(Uint8List bytes, {required String ext, required String contentType}) async {
    final path = idImageStoragePath(_uid, ext, DateTime.now());
    final bucket = _db.storage.from('ID_Image');
    await bucket.uploadBinary(path, bytes, fileOptions: FileOptions(upsert: true, contentType: contentType));
    final url = bucket.getPublicUrl(path);
    await _db.from('profiles').update({
      'id_image': url,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', _uid);
    return url;
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

  /// Newest first. [from] (inclusive) and [to] (exclusive) bound the
  /// creation time, for the history screen's month pages.
  Future<List<WalletTransaction>> walletTransactions({
    String? walletType,
    int limit = 100,
    DateTime? from,
    DateTime? to,
  }) async {
    var q = _db
        .from('wallet_transactions')
        .select('id, wallet_type, kind, amount, balance_after, method, note, status, created_at')
        .eq('user_id', _uid);
    if (walletType != null) q = q.eq('wallet_type', walletType);
    if (from != null) q = q.gte('created_at', from.toUtc().toIso8601String());
    if (to != null) q = q.lt('created_at', to.toUtc().toIso8601String());
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
    await _bumpTicket(ticketId, text);
  }

  /// Sends a photo or video: uploads it to the ticket's folder in
  /// `support-media`, then posts it as an `image` / `video` message.
  Future<void> sendAttachment(
    String ticketId,
    Uint8List bytes, {
    required String name,
    String? senderName,
  }) async {
    final ext = fileExt(name);
    final kind = supportMediaKind(ext);
    if (kind == null) throw StateError('Send a photo or a video.');
    final path = supportMediaPath(ticketId, kind, ext, DateTime.now(), const Uuid().v4().substring(0, 8));
    final bucket = _db.storage.from('support-media');
    await bucket.uploadBinary(
      path,
      bytes,
      fileOptions: FileOptions(upsert: true, contentType: supportContentType(kind, ext)),
    );
    await _db.from('support_messages').insert({
      'ticket_id': ticketId,
      'sender_role': 'user',
      'sender_id': _uid,
      'sender_name': senderName,
      'type': kind,
      'media_url': bucket.getPublicUrl(path),
      'status': 'sent',
    });
    await _bumpTicket(ticketId, supportSummary(kind, null));
  }

  /// Bumps the ticket summary; the admin-side unread counter goes up.
  Future<void> _bumpTicket(String ticketId, String preview) async {
    final t = await _db.from('support_tickets').select('unread_admin').eq('id', ticketId).maybeSingle();
    await _db.from('support_tickets').update({
      'last_message': preview,
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
