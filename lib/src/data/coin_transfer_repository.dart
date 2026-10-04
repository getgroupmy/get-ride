import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/coin_transfer.dart';
import '../providers.dart';

/// GET.coin transfers between accounts (Expo `transferRequestsStore`). The
/// three writes are owner-scoped SECURITY DEFINER RPCs; the table itself is
/// only ever read.
class CoinTransferRepository {
  CoinTransferRepository(this._db);
  final SupabaseClient _db;

  static const _table = 'wallet_transfer_requests';

  String get _uid {
    final id = _db.auth.currentUser?.id;
    if (id == null) throw StateError('Not signed in');
    return id;
  }

  /// Step 1: ask the recipient to approve. Throws with the RPC error on
  /// refusal (map it with [coinSendErrorMessage]).
  Future<SentTransfer> request(TransferRecipient to, double coins, {String? note}) async {
    final data = await _db.rpc(
      'wallet_request_coin_transfer',
      params: {
        'p_from': _uid,
        'p_coins': coins,
        'p_to': to.userId,
        'p_to_phone': to.phone,
        'p_note': (note?.trim().isEmpty ?? true) ? null : note!.trim(),
      },
    );
    return SentTransfer.fromRpc(data, coins: coins);
  }

  /// Step 2: the recipient answers. Answers the resulting status, coins and
  /// sender name (the server reports expiry/failure as a status, not an error).
  Future<({TransferStatus status, double coins, String? fromName})> respond(
    String requestId, {
    required bool accept,
  }) async {
    final data = await _db.rpc(
      'wallet_respond_coin_transfer',
      params: {'p_request': requestId, 'p_user': _uid, 'p_accept': accept},
    );
    final row = data is Map ? data : const {};
    final coins = row['coins'];
    return (
      status: parseTransferStatus(row['status']),
      coins: coins is num ? coins.toDouble() : double.tryParse('${coins ?? ''}') ?? 0,
      fromName: row['from_name'] is String ? row['from_name'] as String : null,
    );
  }

  /// The sender withdraws their own pending request.
  Future<void> cancel(String requestId) =>
      _db.rpc('wallet_cancel_transfer_request', params: {'p_request': requestId, 'p_user': _uid});

  Future<CoinTransferRequest?> fetch(String requestId) async {
    final row = await _db.from(_table).select().eq('id', requestId).maybeSingle();
    return row == null ? null : CoinTransferRequest.fromRow(row);
  }

  /// Pending, unexpired requests addressed to [userId], oldest first.
  Future<List<CoinTransferRequest>> pendingIncoming(String userId) async {
    final rows = await _db
        .from(_table)
        .select()
        .eq('to_user_id', userId)
        .eq('status', 'pending')
        .gt('expires_at', DateTime.now().toUtc().toIso8601String())
        .order('created_at')
        .limit(10);
    return rows.map(CoinTransferRequest.fromRow).toList();
  }

  /// Every insert or update on a request addressed to [userId], starting
  /// with the ones already pending.
  Stream<CoinTransferRequest> watchIncoming(String userId) =>
      _watch('to_user_id', userId, initial: () => pendingIncoming(userId));

  /// Updates to one request (the sender waiting on an answer), starting with
  /// its current row.
  Stream<CoinTransferRequest> watchRequest(String requestId) => _watch(
    'id',
    requestId,
    initial: () async {
      final r = await fetch(requestId);
      return r == null ? const [] : [r];
    },
  );

  Stream<CoinTransferRequest> _watch(
    String column,
    String value, {
    required Future<List<CoinTransferRequest>> Function() initial,
  }) {
    final controller = StreamController<CoinTransferRequest>();
    RealtimeChannel? channel;
    controller.onListen = () {
      void emit(Map<String, dynamic> row) {
        if (!controller.isClosed && row.isNotEmpty) controller.add(CoinTransferRequest.fromRow(row));
      }

      channel = _db
          .channel('coin_transfer_${column}_${value}_${DateTime.now().microsecondsSinceEpoch}')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: _table,
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: column, value: value),
            callback: (p) => emit(p.newRecord),
          )
          .subscribe();
      initial().then((list) {
        for (final r in list) {
          if (!controller.isClosed) controller.add(r);
        }
      }, onError: (Object _) {});
    };
    controller.onCancel = () async {
      if (channel != null) await _db.removeChannel(channel!);
      await controller.close();
    };
    return controller.stream;
  }
}

final coinTransferRepositoryProvider = Provider((ref) => CoinTransferRepository(ref.watch(supabaseProvider)));
