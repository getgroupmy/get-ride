/// GET.coin transfers between accounts — pure port of Expo
/// `utils/transferRequestsStore.ts`. Sending is a two-step handshake: the
/// sender's confirm creates a *pending* `wallet_transfer_requests` row, the
/// recipient accepts or declines, and coins only move on acceptance.
/// Requests expire after 15 minutes (server-side `expires_at`).
library;

enum TransferStatus { pending, accepted, declined, cancelled, expired, failed }

TransferStatus parseTransferStatus(Object? v) =>
    TransferStatus.values.where((s) => s.name == '$v').firstOrNull ?? TransferStatus.pending;

String? _text(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

class CoinTransferRequest {
  const CoinTransferRequest({
    required this.id,
    required this.fromUserId,
    required this.toUserId,
    required this.coins,
    required this.status,
    this.fromName,
    this.toName,
    this.note,
    this.createdAt,
    this.expiresAt,
  });

  factory CoinTransferRequest.fromRow(Map<String, dynamic> r) => CoinTransferRequest(
    id: '${r['id'] ?? ''}',
    fromUserId: '${r['from_user_id'] ?? ''}',
    fromName: _text(r['from_name']),
    toUserId: '${r['to_user_id'] ?? ''}',
    toName: _text(r['to_name']),
    coins: _num(r['coins']),
    note: _text(r['note']),
    status: parseTransferStatus(r['status']),
    createdAt: DateTime.tryParse('${r['created_at'] ?? ''}'),
    expiresAt: DateTime.tryParse('${r['expires_at'] ?? ''}'),
  );

  final String id;
  final String fromUserId;
  final String? fromName;
  final String toUserId;
  final String? toName;
  final double coins;
  final String? note;
  final TransferStatus status;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  bool isExpired(DateTime now) => expiresAt != null && now.isAfter(expiresAt!);

  /// Still waiting on the recipient (and not yet past its expiry).
  bool isOpen(DateTime now) => status == TransferStatus.pending && !isExpired(now);
}

final _uuid = RegExp(r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', caseSensitive: false);

/// Who a send is addressed to: an account id (a pasted wallet id, or a
/// `getpay://` QR payload containing one) or a phone number the server
/// resolves. Null when the input is neither.
typedef TransferRecipient = ({String? userId, String? phone});

TransferRecipient? parseRecipient(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final id = _uuid.firstMatch(text);
  if (id != null) return (userId: id.group(1)!.toLowerCase(), phone: null);
  if (text.replaceAll(RegExp(r'\D'), '').length >= 7) return (userId: null, phone: text);
  return null;
}

/// Why a send cannot go out as entered, or null when it can.
String? coinSendProblem({
  required double coins,
  required double coinBalance,
  required TransferRecipient? recipient,
  required String? selfId,
}) {
  if (recipient == null) return 'Enter a phone number or wallet ID.';
  if (recipient.userId != null && recipient.userId == selfId) return "You can't send coins to yourself.";
  if (!(coins > 0)) return 'Enter an amount greater than 0.';
  if (coins > coinBalance + 0.0001) return 'Not enough GET.coin to send.';
  return null;
}

/// The words for a `wallet_request_coin_transfer` failure.
String coinSendErrorMessage(Object error) {
  final msg = '$error'.toLowerCase();
  if (msg.contains('insufficient_coins')) return 'Not enough GET.coin to send.';
  if (msg.contains('recipient_not_found')) return 'Recipient not found. Check the number and try again.';
  if (msg.contains('self_transfer')) return "You can't send coins to yourself.";
  if (msg.contains('invalid_amount')) return 'Enter an amount greater than 0.';
  if (msg.contains('not_authorized') || msg.contains('42501')) return 'Sign in again to send GET.coin.';
  if (msg.contains('could not find the function') || msg.contains('pgrst202')) {
    return 'Sending GET.coin is not set up on this server yet.';
  }
  return 'Transfer request failed. Please try again.';
}

/// The words for a `wallet_respond_coin_transfer` failure.
String coinRespondErrorMessage(Object error) {
  final msg = '$error'.toLowerCase();
  if (msg.contains('request_not_pending')) return 'This transfer request was already handled.';
  if (msg.contains('request_not_found')) return 'Transfer request not found.';
  if (msg.contains('not_recipient')) return "This transfer request isn't addressed to you.";
  if (msg.contains('not_authorized') || msg.contains('42501')) return 'Sign in again to respond.';
  return 'Something went wrong. Please try again.';
}

/// What the sender is told once the recipient (or the clock) has answered.
/// Null while the request is still pending.
String? senderOutcome(CoinTransferRequest r, {required String formattedCoins}) {
  final who = r.toName ?? 'The recipient';
  return switch (r.status) {
    TransferStatus.pending => null,
    TransferStatus.accepted => '$who accepted. $formattedCoins sent.',
    TransferStatus.declined => '$who declined. No coins were sent.',
    TransferStatus.cancelled => 'Request cancelled. No coins were sent.',
    TransferStatus.expired => '$who did not answer in time. No coins were sent.',
    TransferStatus.failed => 'The transfer failed: not enough GET.coin when it was accepted.',
  };
}

/// What the recipient is told after answering, from the RPC's status.
({bool ok, String? message}) recipientOutcome(
  TransferStatus status, {
  required String formattedCoins,
  required String? fromName,
}) => switch (status) {
  TransferStatus.accepted => (ok: true, message: 'You received $formattedCoins from ${fromName ?? 'the sender'}.'),
  TransferStatus.declined => (ok: true, message: null),
  TransferStatus.expired => (ok: false, message: 'This transfer request has expired.'),
  TransferStatus.failed => (ok: false, message: 'The sender no longer has enough GET.coin for this transfer.'),
  _ => (ok: false, message: 'This transfer request was already handled.'),
};

/// The pending request returned by `wallet_request_coin_transfer`.
class SentTransfer {
  const SentTransfer({required this.requestId, required this.coins, this.recipientName, this.expiresAt});

  factory SentTransfer.fromRpc(Object? data, {required double coins}) {
    final row = data is Map ? data : const {};
    return SentTransfer(
      requestId: '${row['request_id'] ?? ''}',
      recipientName: _text(row['recipient_name']),
      coins: row['coins'] == null ? coins : _num(row['coins']),
      expiresAt: DateTime.tryParse('${row['expires_at'] ?? ''}'),
    );
  }

  final String requestId;
  final String? recipientName;
  final double coins;
  final DateTime? expiresAt;
}
