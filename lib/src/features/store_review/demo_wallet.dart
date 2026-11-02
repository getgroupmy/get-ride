// The store review account's money (migration 0333): a demo GET.wallet,
// GET.coin and GET.credit kept on this phone alone. Top-ups, ride payments
// and a demo driver's earnings move it; no real money moves and nothing is
// written to the server (which refuses the account every wallet write).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config.dart';
import '../../core/format.dart';
import '../../data/models.dart';
import '../../widgets/common.dart' show showInfo;
import '../../widgets/page_style_host.dart';
import '../ride/demo_ride.dart' show DemoChip;

/// The demo balances and their history, newest first.
class DemoWalletState {
  const DemoWalletState({required this.wallet, required this.coin, required this.credit, this.history = const []});

  final double wallet;
  final double coin;
  final double credit;
  final List<WalletTransaction> history;

  List<WalletBalance> get balances => [
    WalletBalance('get_wallet', wallet, AppConfig.currency),
    WalletBalance('get_coin', coin, 'COIN'),
    WalletBalance('get_credit', credit, AppConfig.currency),
  ];
}

/// The starting demo balances: enough to book and tip a few rides.
const demoWalletStart = DemoWalletState(wallet: 150, coin: 20, credit: 50);

final demoWalletProvider = NotifierProvider<DemoWallet, DemoWalletState>(DemoWallet.new);

class DemoWallet extends Notifier<DemoWalletState> {
  int _n = 0;

  @override
  DemoWalletState build() => demoWalletStart;

  WalletTransaction _line(String type, String kind, double amount, double after, String note) => WalletTransaction({
    'id': 'demo-tx-${++_n}',
    'wallet_type': type,
    'kind': kind,
    'amount': amount,
    'balance_after': after,
    'method': 'demo',
    'note': note,
    'status': 'completed',
    'created_at': DateTime.now().toUtc().toIso8601String(),
  });

  /// A demo top-up of GET.wallet: always succeeds, no money moves.
  void topUp(double amount) {
    if (amount <= 0) return;
    final after = state.wallet + amount;
    state = DemoWalletState(
      wallet: after,
      coin: state.coin,
      credit: state.credit,
      history: [_line('get_wallet', 'topup', amount, after, 'Demo top-up'), ...state.history],
    );
  }

  /// Pays [amount] from GET.wallet; false when the demo balance is short.
  bool pay(double amount, String note) {
    if (amount <= 0) return true;
    if (state.wallet < amount) return false;
    final after = state.wallet - amount;
    state = DemoWalletState(
      wallet: after,
      coin: state.coin,
      credit: state.credit,
      history: [_line('get_wallet', 'ride_payment', -amount, after, note), ...state.history],
    );
    return true;
  }

  /// GET.wallet to GET.credit (a driver's recharge); false when the demo
  /// wallet is short.
  bool recharge(double amount) {
    if (amount <= 0) return true;
    if (state.wallet < amount) return false;
    final wallet = state.wallet - amount, credit = state.credit + amount;
    state = DemoWalletState(
      wallet: wallet,
      coin: state.coin,
      credit: credit,
      history: [
        _line('get_credit', 'recharge', amount, credit, 'Demo recharge from GET.wallet'),
        _line('get_wallet', 'recharge', -amount, wallet, 'Demo recharge to GET.credit'),
        ...state.history,
      ],
    );
    return true;
  }

  /// A demo driver's fare, into GET.credit.
  void earn(double amount, String note) {
    if (amount <= 0) return;
    final after = state.credit + amount;
    state = DemoWalletState(
      wallet: state.wallet,
      coin: state.coin,
      credit: after,
      history: [_line('get_credit', 'earning', amount, after, note), ...state.history],
    );
  }
}

/// The demo top-up: pick an amount, done. True when the wallet was credited.
Future<bool> showDemoTopUp(BuildContext context, {required ValueChanged<double> credit}) async {
  final amount = await showAppDialog<double>(
    id: 'review.demo-top-up',
    context: context,
    builder: (c) => AlertDialog(
      key: const ValueKey('demo-top-up'),
      title: const Row(children: [Expanded(child: Text('Top up GET.wallet')), DemoChip()]),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Demo account: the top-up succeeds at once and no real money moves.'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in const [20.0, 50.0, 100.0])
                OutlinedButton(
                  key: ValueKey('demo-top-up-${a.round()}'),
                  onPressed: () => Navigator.pop(c, a),
                  child: Text(formatMoney(a, AppConfig.currency)),
                ),
            ],
          ),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel'))],
    ),
  );
  if (amount == null) return false;
  credit(amount);
  return true;
}

/// The end of the store review account's demo ride: pay from the demo
/// wallet (or cash), rate the driver, and the receipt.
class DemoTripFinish extends ConsumerStatefulWidget {
  const DemoTripFinish({super.key, required this.fare, required this.driver, required this.route});

  final double fare;
  final String driver;
  final String route;

  @override
  ConsumerState<DemoTripFinish> createState() => _DemoTripFinishState();
}

class _DemoTripFinishState extends ConsumerState<DemoTripFinish> {
  String? _paidBy;
  int _stars = 0;
  bool _rated = false;

  void _pay(bool wallet) {
    if (wallet && !ref.read(demoWalletProvider.notifier).pay(widget.fare, 'Demo ride: ${widget.route}')) {
      showInfo(context, 'Not enough in the demo GET.wallet. Top it up in Wallet, or pay cash.');
      return;
    }
    setState(() => _paidBy = wallet ? 'GET.wallet' : 'Cash');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final fare = formatMoney(widget.fare, AppConfig.currency);
    if (_paidBy == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Pay $fare', style: t.textTheme.titleMedium),
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey('demo-pay-wallet'),
          onPressed: () => _pay(true),
          child: Text('Pay with GET.wallet (${formatMoney(ref.watch(demoWalletProvider).wallet, AppConfig.currency)})'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(key: const ValueKey('demo-pay-cash'), onPressed: () => _pay(false), child: const Text('Paid cash')),
      ]);
    }
    if (!_rated) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Rate ${widget.driver}', style: t.textTheme.titleMedium),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (var i = 1; i <= 5; i++)
            IconButton(
              key: ValueKey('demo-star-$i'),
              tooltip: '$i star${i == 1 ? '' : 's'}',
              icon: Icon(i <= _stars ? Icons.star : Icons.star_border, color: Colors.amber.shade700),
              onPressed: () => setState(() => _stars = i),
            ),
        ]),
        FilledButton(
          key: const ValueKey('demo-rate'),
          onPressed: _stars == 0 ? null : () => setState(() => _rated = true),
          child: const Text('Submit rating'),
        ),
      ]);
    }
    return Card(
      key: const ValueKey('demo-receipt'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [Expanded(child: Text('Receipt', style: t.textTheme.titleMedium)), const DemoChip()]),
          const SizedBox(height: 4),
          Text(widget.route),
          Text('Driver: ${widget.driver} · rated $_stars of 5'),
          Text('Fare $fare · paid by $_paidBy'),
          Text('Simulated: no money moved.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
