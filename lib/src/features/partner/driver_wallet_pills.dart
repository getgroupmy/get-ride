import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/commission_settings.dart';
import '../../core/format.dart';
import '../../data/live_tables.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../wallet/wallet_screen.dart' show walletBalancesProvider;

/// The two balances a driver works from (Expo `partner-ehailing` wallet
/// pills): GET.credit, which pays commission and may run negative, and
/// GET.wallet. A wallet not opened yet reads as zero. Pure.
({double credit, double wallet, String currency}) driverWallets(List<WalletBalance> balances) {
  double of(String type) => balances.where((b) => b.walletType == type).fold(0.0, (s, b) => s + b.balance);
  return (
    credit: of('get_credit'),
    wallet: of('get_wallet'),
    currency: balances.isEmpty ? 'MYR' : balances.first.currency,
  );
}

/// The lowest GET.credit a driver may take work at (Admin → Commission →
/// Settings, 0218); null when there is none or it can't be read.
final creditFloorProvider = FutureProvider.autoDispose<double?>((ref) async {
  ref.watchLive('app_settings');
  try {
    return CommissionConfig.fromJson(await ref.watch(supabaseProvider).rpc('commission_config')).creditFloor;
  } catch (_) {
    return null;
  }
});

/// Whether [credit] is under [floor], so the driver can't take work. Pure.
bool creditBlocked(double credit, double? floor) => floor != null && credit < floor;

/// GET.credit and GET.wallet on the Drive screen; either opens the wallet.
/// Owed commission (a negative GET.credit) shows in the error colour.
class DriverWalletPills extends ConsumerWidget {
  const DriverWalletPills({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balances = ref.watch(walletBalancesProvider).value;
    if (balances == null) return const SizedBox.shrink();
    final w = driverWallets(balances);
    final t = Theme.of(context);
    Widget pill(String key, IconData icon, String label, double amount, {bool owed = false}) => Expanded(
      child: Card(
        key: ValueKey(key),
        color: owed ? t.colorScheme.errorContainer : null,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => context.go('/wallet'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 20, color: owed ? t.colorScheme.onErrorContainer : t.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: t.textTheme.labelSmall, maxLines: 1),
                      Text(
                        formatMoney(amount, w.currency),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: owed ? t.colorScheme.onErrorContainer : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final floor = ref.watch(creditFloorProvider).value;
    final row = Row(
      children: [
        pill('wallet-pill-credit', Icons.credit_card, 'GET.credit', w.credit, owed: w.credit < 0),
        pill('wallet-pill-wallet', Icons.account_balance_wallet_outlined, 'GET.wallet', w.wallet),
      ],
    );
    if (!creditBlocked(w.credit, floor)) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        Card(
          key: const ValueKey('wallet-credit-blocked'),
          color: t.colorScheme.errorContainer,
          child: ListTile(
            leading: Icon(Icons.block, color: t.colorScheme.onErrorContainer),
            title: Text(
              floor == 0
                  ? 'GET.credit is below zero'
                  : 'GET.credit is below ${formatMoney(floor!, w.currency)}',
              style: TextStyle(color: t.colorScheme.onErrorContainer, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Top up GET.credit to go online and take trips again.',
              style: TextStyle(color: t.colorScheme.onErrorContainer),
            ),
            trailing: TextButton(onPressed: () => context.go('/wallet'), child: const Text('Top up')),
          ),
        ),
      ],
    );
  }
}
