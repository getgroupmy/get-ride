import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin/screens/commerce/get_coin.dart';
import '../../core/coin_transfer.dart';
import '../../data/coin_trade_repository.dart';
import '../../data/coin_transfer_repository.dart';
import '../../providers.dart';
import 'wallet_screen.dart';

/// Global listener over the whole app (Expo `IncomingTransferPopup`): watches
/// GET.coin transfer requests addressed to the signed-in account and raises
/// an approval card naming the sender and the amount. Coins only move when
/// the recipient accepts. Drawn as an overlay above the router so it shows
/// on any screen, the meter console included.
class IncomingTransferListener extends ConsumerStatefulWidget {
  const IncomingTransferListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IncomingTransferListener> createState() => _IncomingTransferListenerState();
}

class _IncomingTransferListenerState extends ConsumerState<IncomingTransferListener> {
  StreamSubscription<CoinTransferRequest>? _sub;
  String? _uid;
  final _queue = <CoinTransferRequest>[];
  Timer? _expiry;
  String? _respondingId;
  ({bool ok, String message})? _result;

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _expiry?.cancel();
    super.dispose();
  }

  void _watch(String? uid) {
    if (uid == _uid) return;
    _uid = uid;
    unawaited(_sub?.cancel());
    _sub = null;
    _queue.clear();
    _result = null;
    _armExpiry();
    if (uid == null) return;
    _sub = ref.read(coinTransferRepositoryProvider).watchIncoming(uid).listen(_onRow, onError: (Object _) {});
  }

  void _onRow(CoinTransferRequest r) {
    if (!mounted) return;
    setState(() {
      final i = _queue.indexWhere((q) => q.id == r.id);
      if (r.isOpen(DateTime.now())) {
        if (i < 0) _queue.add(r);
      } else if (i >= 0 && r.id != _respondingId) {
        // Withdrawn by the sender or expired server-side.
        _queue.removeAt(i);
      }
    });
    _armExpiry();
  }

  /// Quietly drops the card on screen when its request expires.
  void _armExpiry() {
    _expiry?.cancel();
    final current = _queue.firstOrNull;
    final at = current?.expiresAt;
    if (current == null || at == null) return;
    final wait = at.difference(DateTime.now());
    _expiry = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (!mounted || _respondingId == current.id) return;
      setState(() => _queue.removeWhere((q) => q.id == current.id));
      _armExpiry();
    });
  }

  Future<void> _respond(CoinTransferRequest r, bool accept) async {
    if (_respondingId != null) return;
    if (r.isExpired(DateTime.now())) {
      setState(() => _queue.remove(r));
      return _armExpiry();
    }
    setState(() => _respondingId = r.id);
    ({bool ok, String? message}) outcome;
    try {
      final res = await ref.read(coinTransferRepositoryProvider).respond(r.id, accept: accept);
      outcome = recipientOutcome(
        res.status,
        formattedCoins: formatCoins(res.coins > 0 ? res.coins : r.coins),
        fromName: res.fromName ?? r.fromName,
      );
      if (res.status == TransferStatus.accepted) {
        ref.invalidate(walletBalancesProvider);
        ref.invalidate(walletTxProvider);
        ref.invalidate(coinTradeQuoteProvider);
      }
    } catch (e) {
      outcome = (ok: false, message: coinRespondErrorMessage(e));
    }
    if (!mounted) return;
    setState(() {
      _respondingId = null;
      _queue.removeWhere((q) => q.id == r.id);
      final message = outcome.message;
      _result = message == null ? null : (ok: outcome.ok, message: message);
    });
    _armExpiry();
  }

  @override
  Widget build(BuildContext context) {
    _watch(ref.watch(currentUserIdProvider));
    final current = _queue.firstOrNull;
    final result = _result;
    final Widget? card = current != null
        ? _RequestCard(
            request: current,
            responding: _respondingId == current.id,
            onAccept: () => _respond(current, true),
            onDecline: () => _respond(current, false),
          )
        : result != null
        ? _ResultCard(result: result, onClose: () => setState(() => _result = null))
        : null;
    return Stack(
      children: [
        widget.child,
        if (card != null) ...[
          const ModalBarrier(color: Colors.black54, dismissible: false),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 380), child: card),
            ),
          ),
        ],
      ],
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.request,
    required this.responding,
    required this.onAccept,
    required this.onDecline,
  });

  final CoinTransferRequest request;
  final bool responding;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      key: const ValueKey('incoming-transfer'),
      elevation: 8,
      borderRadius: BorderRadius.circular(20),
      color: t.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.toll, size: 40, color: Color(0xFFEAB308)),
            const SizedBox(height: 12),
            Text('Incoming GET.coin', style: t.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('${request.fromName ?? 'Someone'} wants to send you', textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(formatCoins(request.coins), style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
            if (request.note != null) ...[
              const SizedBox(height: 8),
              Text('"${request.note}"', textAlign: TextAlign.center, style: t.textTheme.bodyMedium),
            ],
            const SizedBox(height: 8),
            Text('Coins arrive only if you accept.', style: t.textTheme.bodySmall),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: responding ? null : onDecline,
                    icon: const Icon(Icons.close),
                    label: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: responding ? null : onAccept,
                    icon: responding
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.check),
                    label: const Text('Accept'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result, required this.onClose});

  final ({bool ok, String message}) result;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(20),
      color: t.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              result.ok ? Icons.check_circle : Icons.error_outline,
              size: 40,
              color: result.ok ? Colors.green : t.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(result.message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onClose, child: const Text('OK')),
          ],
        ),
      ),
    );
  }
}
