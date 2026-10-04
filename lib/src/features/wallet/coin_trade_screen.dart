import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin/screens/commerce/get_coin.dart';
import '../../core/coin_trade.dart';
import '../../core/coin_transfer.dart';
import '../../core/format.dart';
import '../../data/coin_trade_repository.dart';
import '../../data/coin_transfer_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import 'wallet_screen.dart';

/// Buy and sell GET.coin against GET.wallet (Expo `app/wallet-trade.tsx`,
/// Buy / Sell tabs). Priced at the admin rate, or the market rate when
/// market pricing is on; the server settles at its own anchored rate.
class CoinTradeScreen extends ConsumerStatefulWidget {
  const CoinTradeScreen({super.key});

  @override
  ConsumerState<CoinTradeScreen> createState() => _CoinTradeScreenState();
}

class _CoinTradeScreenState extends ConsumerState<CoinTradeScreen> {
  final _amount = TextEditingController();
  var _tab = _Tab.buy;
  final _recipient = TextEditingController();
  final _note = TextEditingController();
  var _busy = false;
  String? _error;
  String? _done;

  @override
  void dispose() {
    _amount.dispose();
    _recipient.dispose();
    _note.dispose();
    super.dispose();
  }

  CoinTradeDirection get _direction => _tab == _Tab.sell ? CoinTradeDirection.sell : CoinTradeDirection.buy;

  double get _coins => _round2(parseLooseNumber(_amount.text) ?? 0);

  static double _round2(double v) => (v * 100).roundToDouble() / 100;

  void _setAmount(double v) {
    _amount.text = v > 0 ? formatRate(v) : '';
    setState(() {
      _error = null;
      _done = null;
    });
  }

  Future<void> _confirm(CoinTradeQuote q, double rate) async {
    final coins = _coins;
    final value = coinTradeValue(coins, rate);
    final buy = _direction == CoinTradeDirection.buy;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(buy ? 'Buy GET.coin?' : 'Sell GET.coin?'),
        content: Text(
          buy
              ? 'Buy ${formatCoins(coins)} for ${formatMoney(value)} from GET.wallet at '
                    '${formatCoinRate(rate, 'RM')}/GC.'
              : 'Sell ${formatCoins(coins)} for ${formatMoney(value)} into GET.wallet at '
                    '${formatCoinRate(rate, 'RM')}/GC.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(buy ? 'Buy' : 'Sell')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      final r = await ref.read(coinTradeRepositoryProvider).trade(_direction, coins, rate);
      if (!mounted) return;
      _amount.clear();
      setState(
        () => _done = buy
            ? 'Bought ${formatCoins(r.coins)} for ${formatMoney(r.amount)}.'
            : 'Sold ${formatCoins(r.coins)} for ${formatMoney(r.amount)}.',
      );
      ref.invalidate(coinTradeQuoteProvider);
      ref.invalidate(walletBalancesProvider);
      ref.invalidate(walletTxProvider);
    } catch (e) {
      if (mounted) setState(() => _error = coinTradeErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmSend(TransferRecipient to) async {
    final coins = _coins;
    final who = to.phone ?? 'wallet ${to.userId!.substring(0, 8)}…';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Send GET.coin?'),
        content: Text(
          'Ask $who to accept ${formatCoins(coins)}. The coins only leave your wallet when they accept, '
          'and the request expires after 15 minutes.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Send request')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    final repo = ref.read(coinTransferRepositoryProvider);
    SentTransfer sent;
    try {
      sent = await repo.request(to, coins, note: _note.text);
    } catch (e) {
      if (mounted) setState(() => _error = coinSendErrorMessage(e));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final outcome = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TransferWaitingDialog(sent: sent, recipientHint: sent.recipientName ?? to.phone, repo: repo),
    );
    if (!mounted) return;
    _amount.clear();
    _note.clear();
    setState(() => _done = outcome);
    ref.invalidate(coinTradeQuoteProvider);
    ref.invalidate(walletBalancesProvider);
    ref.invalidate(walletTxProvider);
  }

  List<Widget> _sendFields(CoinTradeQuote q) {
    final t = Theme.of(context);
    final selfId = ref.watch(currentUserIdProvider);
    final to = parseRecipient(_recipient.text);
    final coins = _coins;
    final problem = coinSendProblem(coins: coins, coinBalance: q.coinBalance, recipient: to, selfId: selfId);
    void changed(String _) => setState(() {
          _error = null;
          _done = null;
        });
    return [
      const SizedBox(height: 16),
      TextField(
        key: const ValueKey('coin-recipient'),
        controller: _recipient,
        enabled: !_busy,
        keyboardType: TextInputType.text,
        decoration: InputDecoration(
          labelText: 'Send to',
          hintText: 'Phone number or wallet ID',
          prefixIcon: const Icon(Icons.person_search_outlined),
          errorText: _recipient.text.trim().isNotEmpty && to == null ? 'Enter a phone number or wallet ID.' : null,
        ),
        onChanged: changed,
      ),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('coin-amount'),
        controller: _amount,
        enabled: !_busy,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        decoration: InputDecoration(
          labelText: 'GC to send',
          suffixText: 'GC',
          helperText: 'GET.coin ${formatCoins(q.coinBalance)}',
          errorText: coins > 0 && to != null && problem != null ? problem : null,
        ),
        onChanged: changed,
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [
        for (final v in const [10.0, 50.0, 100.0])
          ActionChip(label: Text(formatRate(v)), onPressed: _busy ? null : () => _setAmount(v)),
        ActionChip(
          label: const Text('MAX'),
          onPressed: _busy || q.coinBalance <= 0 ? null : () => _setAmount((q.coinBalance * 100).floorToDouble() / 100),
        ),
      ]),
      const SizedBox(height: 8),
      TextField(
        controller: _note,
        enabled: !_busy,
        maxLength: 80,
        decoration: const InputDecoration(labelText: 'Note (optional)'),
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(_error!, style: TextStyle(color: t.colorScheme.error)),
      ],
      if (_done != null) ...[
        const SizedBox(height: 8),
        Text(_done!, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy || problem != null ? null : () => _confirmSend(to!),
        child: _busy
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Send GET.coin'),
      ),
      const SizedBox(height: 8),
      Text(
        'The recipient is asked to accept first. Nothing leaves your wallet until they do.',
        style: t.textTheme.bodySmall,
        textAlign: TextAlign.center,
      ),
      if (selfId != null) ...[
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.qr_code_2),
            title: const Text('Your wallet ID'),
            subtitle: Text(selfId, style: const TextStyle(fontFamily: 'monospace')),
            trailing: IconButton(
              tooltip: 'Copy wallet ID',
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: selfId));
                if (mounted) setState(() => _done = 'Wallet ID copied.');
              },
            ),
          ),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final quote = ref.watch(coinTradeQuoteProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('GET.coin')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(coinTradeQuoteProvider.future),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ResponsiveCenter(
              maxWidth: 560,
              child: AsyncView(value: quote, onRetry: () => ref.invalidate(coinTradeQuoteProvider), data: _body),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(CoinTradeQuote q) {
    final t = Theme.of(context);
    final market = q.market;
    final rate = market.ratePerGC;
    final buy = _direction == CoinTradeDirection.buy;
    final coins = _coins;
    final value = coinTradeValue(coins, rate);
    final max = maxTradeCoins(
      direction: _direction,
      walletBalance: q.walletBalance,
      coinBalance: q.coinBalance,
      ratePerGC: rate,
      settings: q.settings,
      stats: q.stats,
    );
    final problem = coinTradeProblem(
      direction: _direction,
      coins: coins,
      maxCoins: max,
      ratePerGC: rate,
      settings: q.settings,
      stats: q.stats,
    );
    final showProblem = coins > 0 && problem != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_tab != _Tab.send) ...[_RateCard(quote: q, market: market), const SizedBox(height: 16)],
        SegmentedButton<_Tab>(
          segments: const [
            ButtonSegment(value: _Tab.buy, label: Text('Buy'), icon: Icon(Icons.add_circle_outline)),
            ButtonSegment(value: _Tab.sell, label: Text('Sell'), icon: Icon(Icons.remove_circle_outline)),
            ButtonSegment(value: _Tab.send, label: Text('Send'), icon: Icon(Icons.send_outlined)),
          ],
          selected: {_tab},
          onSelectionChanged: _busy
              ? null
              : (s) => setState(() {
                  _tab = s.first;
                  _error = null;
                  _done = null;
                }),
        ),
        if (_tab == _Tab.send) ..._sendFields(q) else ...[
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('coin-amount'),
          controller: _amount,
          enabled: !_busy,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: InputDecoration(
            labelText: buy ? 'GC to buy' : 'GC to sell',
            suffixText: 'GC',
            helperText: buy
                ? 'GET.wallet ${formatMoney(q.walletBalance)} · up to ${formatCoins(max)}'
                : 'GET.coin ${formatCoins(q.coinBalance)}',
            errorText: showProblem ? problem : null,
          ),
          onChanged: (_) => setState(() {
            _error = null;
            _done = null;
          }),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final v in const [10.0, 50.0, 100.0])
              ActionChip(label: Text(formatRate(v)), onPressed: _busy ? null : () => _setAmount(v)),
            ActionChip(label: const Text('MAX'), onPressed: _busy || max <= 0 ? null : () => _setAmount(max)),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            title: Text(buy ? 'You pay' : 'You receive'),
            subtitle: Text('at ${formatCoinRate(rate, 'RM')}/GC'),
            trailing: Text(formatMoney(value), style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          ),
        ),
        if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: TextStyle(color: t.colorScheme.error))],
        if (_done != null) ...[
          const SizedBox(height: 8),
          Text(
            _done!,
            style: const TextStyle(color: Colors.green, fontWeight: FontWeight.w600),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy || problem != null ? null : () => _confirm(q, rate),
          child: _busy
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(buy ? 'Buy GET.coin' : 'Sell GET.coin'),
        ),
        const SizedBox(height: 8),
        Text(
          'The final rate is checked by the server when the trade settles.',
          style: t.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        ],
      ],
    );
  }
}

enum _Tab { buy, sell, send }

/// Waits on the recipient's answer to a sent request (realtime, with the
/// row re-read when the expiry passes) and lets the sender withdraw it.
/// Pops with the outcome sentence.
class TransferWaitingDialog extends StatefulWidget {
  const TransferWaitingDialog({super.key, required this.sent, required this.repo, this.recipientHint});

  final SentTransfer sent;
  final CoinTransferRepository repo;
  final String? recipientHint;

  @override
  State<TransferWaitingDialog> createState() => _TransferWaitingDialogState();
}

class _TransferWaitingDialogState extends State<TransferWaitingDialog> {
  StreamSubscription<CoinTransferRequest>? _sub;
  Timer? _expiry;
  String? _outcome;
  var _cancelling = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sub = widget.repo.watchRequest(widget.sent.requestId).listen(_update, onError: (Object _) {});
    final at = widget.sent.expiresAt;
    if (at != null) {
      final wait = at.difference(DateTime.now()) + const Duration(seconds: 2);
      _expiry = Timer(wait.isNegative ? Duration.zero : wait, _expired);
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _expiry?.cancel();
    super.dispose();
  }

  void _update(CoinTransferRequest r) {
    final text = senderOutcome(r, formattedCoins: formatCoins(r.coins));
    if (text != null && mounted && _outcome == null) setState(() => _outcome = text);
  }

  Future<void> _expired() async {
    if (_outcome != null) return;
    final r = await widget.repo.fetch(widget.sent.requestId).catchError((Object _) => null);
    if (!mounted || _outcome != null) return;
    if (r != null && r.status != TransferStatus.pending) return _update(r);
    setState(() => _outcome = '${widget.recipientHint ?? 'The recipient'} did not answer in time. No coins were sent.');
  }

  Future<void> _cancel() async {
    setState(() {
      _cancelling = true;
      _error = null;
    });
    try {
      await widget.repo.cancel(widget.sent.requestId);
      if (mounted && _outcome == null) setState(() => _outcome = 'Request cancelled. No coins were sent.');
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't cancel the request.");
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    final who = widget.recipientHint ?? 'The recipient';
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(outcome == null ? 'Waiting for $who' : 'Transfer request'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (outcome == null) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text('$who got a notification to accept ${formatCoins(widget.sent.coins)}. '
                'Coins move only when they accept.'),
          ] else
            Text(outcome),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ]),
        actions: [
          if (outcome == null)
            TextButton(
              onPressed: _cancelling ? null : _cancel,
              child: Text(_cancelling ? 'Cancelling…' : 'Cancel request'),
            )
          else
            FilledButton(onPressed: () => Navigator.pop(context, outcome), child: const Text('OK')),
        ],
      ),
    );
  }
}

class _RateCard extends StatelessWidget {
  const _RateCard({required this.quote, required this.market});

  final CoinTradeQuote quote;
  final CoinMarketRate market;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = quote.settings;
    final change = market.changePct;
    final left = remainingSupply(s, quote.stats);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('1 GC', style: t.textTheme.labelLarge),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatCoinRate(market.ratePerGC, 'RM'),
                  style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(width: 8),
                if (s.marketEnabled)
                  Text(
                    '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}%',
                    style: TextStyle(
                      color: change > 0 ? Colors.green : (change < 0 ? t.colorScheme.error : null),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (!s.marketEnabled)
              const Text('Fixed rate — set by admin, market pricing is off.')
            else ...[
              Text(
                'Market rate · base ${formatCoinRate(market.baseRatePerGC, 'RM')}, '
                'moves at most ±${formatRate(s.maxSwingPct)}%',
              ),
              if (market.contributions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text("What's moving the price", style: t.textTheme.labelLarge),
                for (final c in market.contributions)
                  Row(
                    children: [
                      Expanded(child: Text(c.label)),
                      Text('${c.pct >= 0 ? '+' : ''}${c.pct.toStringAsFixed(2)}%'),
                    ],
                  ),
              ],
            ],
            if (left != null) ...[
              const SizedBox(height: 8),
              Text(
                'Coin supply: ${formatCoins(quote.stats.circulatingSupply)} of ${formatCoins(s.maxSupply)} '
                '(${formatCoins(left)} left)',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
