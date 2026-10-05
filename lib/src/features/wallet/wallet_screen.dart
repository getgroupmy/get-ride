import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/wallet_history.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

final walletBalancesProvider = FutureProvider.autoDispose<List<WalletBalance>>(
  (ref) => ref.watch(accountRepositoryProvider).walletBalances(),
);

final walletTxProvider = FutureProvider.autoDispose<List<WalletTransaction>>(
  (ref) => ref.watch(accountRepositoryProvider).walletTransactions(),
);

/// GET.wallet / GET.coin / credit balances and history. Money only moves
/// through the server-side wallet RPCs (GET.coin trades: `CoinTradeScreen`).
class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    Future<void> refresh() async {
      ref.invalidate(walletBalancesProvider);
      ref.invalidate(walletTxProvider);
      await ref.read(walletTxProvider.future);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Wallet')),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(children: [
          ResponsiveCenter(
            maxWidth: 760,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              AsyncView(
                value: ref.watch(walletBalancesProvider),
                onRetry: refresh,
                data: (balances) {
                  if (balances.isEmpty) {
                    return const Card(
                      child: ListTile(
                        leading: Icon(Icons.account_balance_wallet_outlined),
                        title: Text('No wallet yet'),
                        subtitle: Text('Your wallet is created with your first top-up or reward.'),
                      ),
                    );
                  }
                  return Wrap(spacing: 12, runSpacing: 12, children: [
                    for (final b in balances)
                      SizedBox(
                        width: 230,
                        child: Card(
                          color: b.walletType == 'get_wallet' ? Colors.black : null,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(b.label,
                                  style: t.textTheme.labelLarge?.copyWith(
                                      color: b.walletType == 'get_wallet' ? Colors.white70 : null)),
                              const SizedBox(height: 8),
                              Text(
                                b.walletType == 'get_coin'
                                    ? '${b.balance.toStringAsFixed(2)} coins'
                                    : formatMoney(b.balance, b.currency),
                                style: t.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: b.walletType == 'get_wallet' ? const Color(0xFF2DABE2) : null,
                                ),
                              ),
                            ]),
                          ),
                        ),
                      ),
                  ]);
                },
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: _QuickAction(
                    key: const ValueKey('wallet-scan'),
                    icon: Icons.qr_code_scanner,
                    label: 'Scan & Pay',
                    onTap: () => context.push('/wallet/scan'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _QuickAction(
                    key: const ValueKey('wallet-receive'),
                    icon: Icons.qr_code_2,
                    label: 'Receive',
                    onTap: () => context.push('/wallet/receive'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _QuickAction(
                    key: const ValueKey('wallet-coin-qr'),
                    icon: Icons.toll_outlined,
                    label: 'GET.coin QR',
                    onTap: () => context.push('/wallet/receive?coin=1'),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.swap_horiz),
                  title: const Text('GET.coin: buy, sell, send'),
                  subtitle: const Text('Trade with GET.wallet or send coins to another account'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/wallet/trade'),
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: Text('Recent transactions', style: t.textTheme.titleMedium)),
                TextButton(
                  key: const ValueKey('wallet-history'),
                  onPressed: () => context.push('/wallet/history'),
                  child: const Text('See all'),
                ),
              ]),
              const SizedBox(height: 8),
              AsyncView(
                value: ref.watch(walletTxProvider),
                onRetry: refresh,
                data: (txs) => txs.isEmpty
                    ? const EmptyState(icon: Icons.history, title: 'No transactions yet')
                    : Card(
                        child: Column(children: [
                          for (final tx in txs.take(5))
                            ListTile(
                              leading: Icon(tx.amount >= 0 ? Icons.south_west : Icons.north_east,
                                  color: tx.amount >= 0 ? Colors.green : t.colorScheme.error),
                              title: Text(walletTxLabel(tx.kind, tx.note)),
                              subtitle: Text('${walletTypeLabel(tx.walletType)} · ${formatDateTime(tx.createdAt)}'
                                  '${tx.status != null && tx.status != 'completed' ? ' · ${tx.status}' : ''}'),
                              trailing: Text(
                                walletAmountText(tx.walletType, tx.amount),
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: tx.amount >= 0 ? Colors.green : null,
                                ),
                              ),
                            ),
                        ]),
                      ),
              ),
              const SizedBox(height: 24),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
          child: Column(children: [
            Icon(icon, size: 28),
            const SizedBox(height: 6),
            Text(label, textAlign: TextAlign.center, maxLines: 2, style: Theme.of(context).textTheme.labelLarge),
          ]),
        ),
      ),
    );
  }
}
