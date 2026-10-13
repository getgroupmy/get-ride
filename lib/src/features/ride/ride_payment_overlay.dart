import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/screens/commerce/get_coin.dart' show formatCoins;
import '../../core/format.dart';
import '../../core/ride_payment.dart';
import '../../data/app_display_repository.dart' show paymentChoicesProvider;
import '../../data/coin_trade_repository.dart' show coinSettingsProvider;
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../wallet/wallet_screen.dart' show walletBalancesProvider, walletTxProvider;

/// What the payment popup is showing, apart from what the ride row says.
enum _Stage { choose, options, paying, failed }

/// The passenger's end-of-trip payment (migration 0142), over the trip
/// screen and not dismissable: the total with the charges the driver added,
/// then "Pay now" (GET.wallet, GET.coin, the other methods) or "Paid in
/// cash". A refused payment says "Transaction not Successful" for
/// [paymentFailedHold] and comes back to the two keys; cash waits for the
/// driver to confirm it; a settled ride ends on the Done page.
class RidePaymentOverlay extends ConsumerStatefulWidget {
  const RidePaymentOverlay({super.key, required this.ride});
  final RideRequest ride;

  @override
  ConsumerState<RidePaymentOverlay> createState() => _RidePaymentOverlayState();
}

class _RidePaymentOverlayState extends ConsumerState<RidePaymentOverlay> {
  _Stage _stage = _Stage.choose;
  String? _failure;
  int _countdown = 0;
  Timer? _timer;

  /// Settled or sent from this phone, ahead of the row saying so.
  bool _paidHere = false;
  bool _cashSent = false;

  /// The Done page's countdown home ([paymentDoneClose]).
  Timer? _closeTimer;
  int _closeIn = paymentDoneClose.inSeconds;

  void _startClose() {
    if (_closeTimer != null) return;
    _closeTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _closeIn--);
      if (_closeIn <= 0) {
        t.cancel();
        _close();
      }
    });
  }

  void _close() {
    _closeTimer?.cancel();
    context.go('/');
  }

  @override
  void dispose() {
    _timer?.cancel();
    _closeTimer?.cancel();
    super.dispose();
  }

  RideRequest get _r => widget.ride;
  String _money(num? v) => formatMoney(v, _r.currency);

  void _refreshWallet() {
    ref.invalidate(walletBalancesProvider);
    ref.invalidate(walletTxProvider);
  }

  Future<void> _pay(RidePayMethod method) async {
    setState(() => _stage = _Stage.paying);
    try {
      await ref.read(rideRepositoryProvider).payRide(_r.id, method, expected: _r.cashDue);
      if (!mounted) return;
      _refreshWallet();
      setState(() => _paidHere = true);
    } catch (e) {
      if (mounted) _fail(e);
    }
  }

  Future<void> _payCash() async {
    try {
      await ref.read(rideRepositoryProvider).payRideCash(_r.id);
      if (mounted) setState(() => _cashSent = true);
    } catch (e) {
      if (mounted) _fail(e);
    }
  }

  /// "Transaction not Successful", then back to Pay now / Paid in cash.
  void _fail(Object e) {
    _timer?.cancel();
    setState(() {
      _stage = _Stage.failed;
      _failure = ridePaymentFailure(e);
      _countdown = paymentFailedHold.inSeconds;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() {
        _countdown--;
        if (_countdown <= 0) {
          t.cancel();
          _stage = _Stage.choose;
          _failure = null;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final status = _r.paymentStatus;
    final Widget body;
    if (status == RidePaymentStatus.paid || _paidHere) {
      body = _done(t);
      if (_closeTimer == null) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _startClose() : null);
    } else if (_stage == _Stage.paying) {
      body = _paying(t);
    } else if (_stage == _Stage.failed) {
      body = _failed(t);
    } else if (status == RidePaymentStatus.cashPending || _cashSent) {
      body = _pending(t);
    } else if (_stage == _Stage.options) {
      body = _options(t);
    } else {
      body = _choose(t);
    }
    return PopScope(
      canPop: false,
      child: ColoredBox(
        key: const ValueKey('ride-payment'),
        color: Colors.black54,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Material(
                  color: t.colorScheme.surface,
                  surfaceTintColor: t.colorScheme.surfaceTint,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                    child: AnimatedSize(duration: const Duration(milliseconds: 200), child: body),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _title(ThemeData t, IconData icon, String text, {Color? color}) => Column(
    children: [
      Icon(icon, size: 48, color: color ?? t.colorScheme.primary),
      const SizedBox(height: 8),
      Text(
        text,
        textAlign: TextAlign.center,
        style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
    ],
  );

  Widget _line(String label, String value, {String? sub, bool bold = false, Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null),
              if (sub != null) Text(sub, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        Text(value, style: bold ? const TextStyle(fontWeight: FontWeight.w700, fontSize: 18) : null),
      ],
    ),
  );

  double? _balance(List<WalletBalance>? all, String type) {
    if (all == null) return null;
    for (final b in all) {
      if (b.walletType == type) return b.balance;
    }
    return 0;
  }

  Widget _choose(ThemeData t) {
    final r = _r;
    final due = r.cashDue ?? 0;
    final added = (r.tollCharges ?? 0) > 0 || (r.otherCharges ?? 0) > 0;
    final balances = ref.watch(walletBalancesProvider).value;
    final rate = ref.watch(coinSettingsProvider).value?.coinsPerCurrency;
    final wallet = _balance(balances, 'get_wallet');
    final coins = _balance(balances, 'get_coin');
    final walletOk = wallet != null && wallet + 0.005 >= due;
    final coinNeed = rate == null || rate <= 0 ? null : coinsForAmount(due, rate);
    final coinOk = coins != null && coinNeed != null && coins + 0.005 >= coinNeed;
    final cashFirst = bookedWithCash(r.paymentMode) || !(walletOk || coinOk);
    final payNow = FilledButton.icon(
      key: const ValueKey('payment-pay-now'),
      onPressed: () => setState(() => _stage = _Stage.options),
      icon: const Icon(Icons.account_balance_wallet_outlined),
      label: const Text('Pay now'),
    );
    final cash = BusyButton.outlined(
      key: const ValueKey('payment-cash'),
      icon: const Icon(Icons.payments_outlined),
      onPressed: _payCash,
      child: const Text('Paid in cash'),
    );
    return Column(
      key: const ValueKey('payment-choose'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(t, Icons.check_circle_outline, 'Trip complete'),
        const SizedBox(height: 12),
        if (added)
          Container(
            key: const ValueKey('payment-added-charges'),
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: t.colorScheme.tertiaryContainer, borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: t.colorScheme.onTertiaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your driver added tolls or other charges.',
                    style: TextStyle(color: t.colorScheme.onTertiaryContainer),
                  ),
                ),
              ],
            ),
          ),
        _line('Trip fare', r.fareText(r.effectiveFare)),
        for (final l in r.chargeLines) _line(l.label, _money(l.amount)),
        if ((r.tollCharges ?? 0) > 0) _line('Tolls', _money(r.tollCharges), key: const ValueKey('payment-tolls')),
        if ((r.otherCharges ?? 0) > 0)
          _line('Other charges', _money(r.otherCharges), sub: r.otherChargesNote, key: const ValueKey('payment-other')),
        if (r.fareCoinsValue > 0) _line('Paid with GET.coin', '−${_money(r.fareCoinsValue)}'),
        const Divider(height: 20),
        _line('Total to pay', _money(due), bold: true, key: const ValueKey('payment-total')),
        const SizedBox(height: 8),
        Text('Booked with ${r.paymentMode}', style: t.textTheme.bodySmall),
        if (wallet != null)
          _BalanceLine(
            key: const ValueKey('payment-wallet-balance'),
            label: 'GET.wallet ${_money(wallet)}',
            enough: walletOk,
          ),
        if (coins != null && coinNeed != null)
          _BalanceLine(
            key: const ValueKey('payment-coin-balance'),
            label: 'GET.coin ${formatCoins(coins)}',
            enough: coinOk,
          ),
        const SizedBox(height: 16),
        if (cashFirst) ...[cash, const SizedBox(height: 8), payNow] else ...[payNow, const SizedBox(height: 8), cash],
      ],
    );
  }

  Widget _options(ThemeData t) {
    final r = _r;
    final due = r.cashDue ?? 0;
    final balances = ref.watch(walletBalancesProvider).value;
    final rate = ref.watch(coinSettingsProvider).value?.coinsPerCurrency;
    final others = ref.watch(paymentChoicesProvider).value ?? const [];
    final options = ridePayOptions(
      due: due,
      walletBalance: _balance(balances, 'get_wallet'),
      coinBalance: _balance(balances, 'get_coin'),
      coinsPerCurrency: rate,
      money: _money,
      coins: (v) => formatCoins(v.toDouble()),
      others: others,
    );
    return Column(
      key: const ValueKey('payment-options'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              key: const ValueKey('payment-back'),
              tooltip: 'Back',
              onPressed: () => setState(() => _stage = _Stage.choose),
              icon: const Icon(Icons.arrow_back),
            ),
            Expanded(child: Text('Pay ${_money(due)} with', style: t.textTheme.titleMedium)),
          ],
        ),
        const SizedBox(height: 8),
        for (final o in options)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              key: ValueKey('payment-option-${o.id}'),
              enabled: o.available,
              leading: Icon(switch (o.method) {
                RidePayMethod.getWallet => Icons.account_balance_wallet_outlined,
                RidePayMethod.getCoin => Icons.toll_outlined,
                _ => Icons.credit_card,
              }),
              title: Text(o.label),
              subtitle: Text([?o.detail, ?o.note].join(' · ')),
              trailing: o.available ? const Icon(Icons.chevron_right) : null,
              onTap: o.available && o.method != null ? () => _pay(o.method!) : null,
            ),
          ),
      ],
    );
  }

  Widget _paying(ThemeData t) => Column(
    key: const ValueKey('payment-paying'),
    children: [
      const SizedBox(height: 12),
      const CircularProgressIndicator(),
      const SizedBox(height: 16),
      Text('Processing payment…', style: t.textTheme.titleMedium),
      const SizedBox(height: 12),
    ],
  );

  Widget _failed(ThemeData t) => Column(
    key: const ValueKey('payment-failed'),
    children: [
      _title(t, Icons.error_outline, 'Transaction not Successful', color: t.colorScheme.error),
      const SizedBox(height: 8),
      if (_failure != null) Text(_failure!, textAlign: TextAlign.center),
      const SizedBox(height: 16),
      Text('Back in $_countdown s', key: const ValueKey('payment-failed-timer'), style: t.textTheme.bodySmall),
    ],
  );

  Widget _pending(ThemeData t) => Column(
    key: const ValueKey('payment-cash-pending'),
    children: [
      _title(t, Icons.hourglass_top, 'Pending confirmation'),
      const SizedBox(height: 8),
      Text(
        'Waiting for your driver to confirm they received ${_money(_r.cashDue)} in cash.',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 16),
      const LinearProgressIndicator(),
    ],
  );

  Widget _done(ThemeData t) {
    final r = _r;
    final amount = _money(r.paidAmount ?? r.cashDue);
    return Column(
      key: const ValueKey('payment-done'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(t, Icons.check_circle, 'Done', color: Colors.green),
        const SizedBox(height: 8),
        Text(
          r.paymentStatus == RidePaymentStatus.paid ? ridePaidSummary(r.paidMethod, amount) : 'Payment complete',
          textAlign: TextAlign.center,
          style: t.textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text('Thanks for riding!', textAlign: TextAlign.center, style: t.textTheme.bodySmall),
        const SizedBox(height: 20),
        FilledButton(key: const ValueKey('payment-close'), onPressed: _close, child: Text('Close ($_closeIn)')),
      ],
    );
  }
}

class _BalanceLine extends StatelessWidget {
  const _BalanceLine({super.key, required this.label, required this.enough});
  final String label;
  final bool enough;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = enough ? Colors.green : t.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(enough ? Icons.check_circle_outline : Icons.remove_circle_outline, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text(label)),
          Text(enough ? 'Enough' : 'Not enough', style: TextStyle(color: color)),
        ],
      ),
    );
  }
}
