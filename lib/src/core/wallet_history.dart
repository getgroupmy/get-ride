/// Wallet history vocabulary (Expo `utils/walletDisplay.ts` and
/// `app/wallet-history.tsx`): what a ledger row is called, which category
/// chip it falls under, how its amount reads, and the month windows the
/// history screen pages through.
library;

import 'package:intl/intl.dart';

import '../data/models.dart';

/// Display name of a wallet type.
String walletTypeLabel(String walletType) => switch (walletType) {
  'get_credit' => 'GET.credit',
  'get_coin' => 'GET.coin',
  _ => 'GET.wallet',
};

/// Amount in the wallet's own unit, signed: "-RM12.50", "+1,250 GC",
/// "+12.50 GC" when fractional.
String walletAmountText(String walletType, double amount, {bool signed = true}) {
  final sign = !signed ? '' : (amount < 0 ? '-' : '+');
  final abs = amount.abs();
  if (walletType == 'get_coin') {
    final whole = (abs - abs.roundToDouble()).abs() < 0.005;
    return '$sign${whole ? NumberFormat.decimalPattern().format(abs.round()) : abs.toStringAsFixed(2)} GC';
  }
  return '${sign}RM${abs.toStringAsFixed(2)}';
}

/// The row title for a ledger [kind] (anything unknown shows its note).
String walletTxLabel(String kind, String? note) => switch (kind) {
  'topup' => 'Wallet Reload',
  'recharge_in' => 'Recharge received',
  'recharge_out' => 'Recharge to GET.credit',
  'payment' => 'Payment',
  'commission' => 'Commission',
  'refund' => 'Refund',
  'reward' => 'Ride Reward',
  'redeem' => 'Paid with GET.coin',
  'transfer_out' => 'Transfer Sent',
  'transfer_in' => 'Transfer Received',
  'referral' => 'Referral Bonus',
  _ => (note != null && note.trim().isNotEmpty) ? note.trim() : 'Adjustment',
};

/// How the money moved, for the details sheet (`method` column).
String walletTxMethodLabel(String? method) => switch (method) {
  null || '' => 'Wallet Balance',
  'qr_scan' => 'QR payment',
  'trade_buy' || 'trade_sell' || 'coin_trade' => 'GET.coin trade',
  'ride_fare' => 'Ride fare',
  _ => method,
};

/// The history screen's category chips.
enum WalletTxCategory {
  ride('Ride'),
  reward('Reward'),
  referral('Referral'),
  transfer('Transfer'),
  reload('Reload'),
  refund('Refund'),
  other('Other');

  const WalletTxCategory(this.label);
  final String label;
}

WalletTxCategory walletTxCategory(String kind) => switch (kind) {
  'payment' || 'commission' || 'redeem' => WalletTxCategory.ride,
  'reward' => WalletTxCategory.reward,
  'referral' => WalletTxCategory.referral,
  'transfer_in' || 'transfer_out' || 'recharge_in' || 'recharge_out' => WalletTxCategory.transfer,
  'topup' => WalletTxCategory.reload,
  'refund' => WalletTxCategory.refund,
  _ => WalletTxCategory.other,
};

/// One calendar month in local time: [start] inclusive, [end] exclusive.
class HistoryMonth {
  const HistoryMonth(this.year, this.month, this.label);
  final int year;
  final int month;
  final String label;

  DateTime get start => DateTime(year, month);
  DateTime get end => DateTime(year, month + 1);

  bool contains(DateTime t) {
    final l = t.toLocal();
    return l.year == year && l.month == month;
  }

  @override
  bool operator ==(Object other) => other is HistoryMonth && other.year == year && other.month == month;

  @override
  int get hashCode => Object.hash(year, month);
}

/// This month and the [count] - 1 before it, newest first: "This Month",
/// "Last Month", then "March 2026".
List<HistoryMonth> historyMonths(DateTime now, {int count = 6}) => [
  for (var i = 0; i < count; i++)
    () {
      final d = DateTime(now.year, now.month - i);
      final label = switch (i) {
        0 => 'This Month',
        1 => 'Last Month',
        _ => DateFormat('MMMM yyyy').format(d),
      };
      return HistoryMonth(d.year, d.month, label);
    }(),
];

/// The rows a set of filters leaves, in the order given (null = all).
List<WalletTransaction> filterWalletHistory(
  Iterable<WalletTransaction> txs, {
  String? walletType,
  WalletTxCategory? category,
  HistoryMonth? month,
}) => [
  for (final tx in txs)
    if ((walletType == null || tx.walletType == walletType) &&
        (category == null || walletTxCategory(tx.kind) == category) &&
        (month == null || (tx.createdAt != null && month.contains(tx.createdAt!))))
      tx,
];

/// Rows grouped by local calendar day, keeping the incoming order (the
/// ledger arrives newest first). Rows without a time go in a final group.
List<({DateTime? day, List<WalletTransaction> txs})> groupWalletHistoryByDay(List<WalletTransaction> txs) {
  final groups = <({DateTime? day, List<WalletTransaction> txs})>[];
  for (final tx in txs) {
    final l = tx.createdAt?.toLocal();
    final day = l == null ? null : DateTime(l.year, l.month, l.day);
    if (groups.isNotEmpty && groups.last.day == day) {
      groups.last.txs.add(tx);
    } else {
      groups.add((day: day, txs: [tx]));
    }
  }
  return groups;
}
