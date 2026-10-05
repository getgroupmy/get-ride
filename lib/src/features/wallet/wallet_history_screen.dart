import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/wallet_history.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

/// One month of this account's ledger, newest first.
final walletHistoryProvider = FutureProvider.autoDispose.family<List<WalletTransaction>, HistoryMonth>(
  (ref, m) => ref.watch(accountRepositoryProvider).walletTransactions(from: m.start, to: m.end, limit: 1000),
);

/// Full wallet history (Expo `app/wallet-history.tsx`): wallet tabs, category
/// chips and a month picker over the last six months, grouped by day, with a
/// details sheet per row.
class WalletHistoryScreen extends ConsumerStatefulWidget {
  const WalletHistoryScreen({super.key, this.now});

  /// Clock override for tests.
  final DateTime? now;

  @override
  ConsumerState<WalletHistoryScreen> createState() => _WalletHistoryScreenState();
}

class _WalletHistoryScreenState extends ConsumerState<WalletHistoryScreen> {
  late final _months = historyMonths(widget.now ?? DateTime.now());
  late var _month = _months.first;
  String? _wallet;
  WalletTxCategory? _category;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final partner = ref.watch(partnerProvider).value != null;
    final wallets = ['get_wallet', 'get_coin', if (partner) 'get_credit'];
    final history = ref.watch(walletHistoryProvider(_month));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transaction history'),
        actions: [
          PopupMenuButton<HistoryMonth>(
            key: const ValueKey('history-month'),
            tooltip: 'Month',
            initialValue: _month,
            onSelected: (m) => setState(() => _month = m),
            itemBuilder: (_) => [for (final m in _months) PopupMenuItem(value: m, child: Text(m.label))],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_month.label, style: t.textTheme.labelLarge),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(walletHistoryProvider(_month).future),
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            ResponsiveCenter(
              maxWidth: 760,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final w in <String?>[null, ...wallets])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(w == null ? 'All' : walletTypeLabel(w)),
                              selected: _wallet == w,
                              onSelected: (_) => setState(() => _wallet = w),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final c in <WalletTxCategory?>[null, ...WalletTxCategory.values])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: FilterChip(
                              label: Text(c?.label ?? 'All'),
                              selected: _category == c,
                              onSelected: (_) => setState(() => _category = c),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  AsyncView(
                    value: history,
                    onRetry: () => ref.invalidate(walletHistoryProvider(_month)),
                    data: (txs) {
                      final rows = filterWalletHistory(txs, walletType: _wallet, category: _category);
                      if (rows.isEmpty) {
                        return EmptyState(
                          icon: Icons.receipt_long_outlined,
                          title: 'No transactions',
                          message: _category == null
                              ? 'Nothing recorded for ${_month.label.toLowerCase()}.'
                              : 'No ${_category!.label.toLowerCase()} transactions for ${_month.label.toLowerCase()}.',
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final g in groupWalletHistoryByDay(rows)) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                              child: Text(
                                g.day == null ? 'Undated' : DateFormat('EEE, d MMM yyyy').format(g.day!),
                                style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant),
                              ),
                            ),
                            Card(
                              child: Column(
                                children: [for (final tx in g.txs) _HistoryRow(tx: tx, onTap: () => _details(tx))],
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          Center(child: Text('END OF HISTORY', style: t.textTheme.labelSmall)),
                          const SizedBox(height: 24),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _details(WalletTransaction tx) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(child: _HistoryDetails(tx: tx)),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.tx, required this.onTap});
  final WalletTransaction tx;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cat = walletTxCategory(tx.kind);
    final referral = tx.kind == 'referral';
    return ListTile(
      onTap: onTap,
      tileColor: referral ? const Color(0xFFF6C445).withValues(alpha: 0.14) : null,
      leading: CircleAvatar(
        backgroundColor: _categoryColor(cat).withValues(alpha: 0.15),
        child: Icon(_categoryIcon(cat), color: _categoryColor(cat), size: 20),
      ),
      title: Row(
        children: [
          Flexible(child: Text(walletTxLabel(tx.kind, tx.note), overflow: TextOverflow.ellipsis)),
          if (referral) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: const Color(0xFFF6C445), borderRadius: BorderRadius.circular(8)),
              child: const Text(
                'BONUS',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF6B4E00)),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        '${walletTypeLabel(tx.walletType)} · ${formatTime(tx.createdAt)}'
        '${tx.status != null && tx.status != 'completed' ? ' · ${tx.status}' : ''}',
      ),
      trailing: Text(
        walletAmountText(tx.walletType, tx.amount),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: tx.amount >= 0 ? Colors.green.shade600 : t.colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _HistoryDetails extends StatelessWidget {
  const _HistoryDetails({required this.tx});
  final WalletTransaction tx;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final rows = <(String, String)>[
      ('Category', walletTxCategory(tx.kind).label),
      ('Type', walletTxLabel(tx.kind, tx.note)),
      ('Date', tx.createdAt == null ? '—' : DateFormat('dd/MM/yyyy, h.mma').format(tx.createdAt!.toLocal())),
      ('Amount', walletAmountText(tx.walletType, tx.amount)),
      ('Payment method', walletTxMethodLabel(tx.method)),
      ('Wallet', walletTypeLabel(tx.walletType)),
      if (tx.balanceAfter != null) ('Balance after', walletAmountText(tx.walletType, tx.balanceAfter!, signed: false)),
      ('Status', tx.status == null ? 'Completed' : '${tx.status![0].toUpperCase()}${tx.status!.substring(1)}'),
      if (tx.note != null && tx.note!.trim().isNotEmpty) ('Reference', tx.note!.trim()),
    ];
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Text('Transaction details', style: t.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 130,
                  child: Text(k, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ),
                Expanded(child: Text(v, style: t.textTheme.bodyMedium)),
              ],
            ),
          ),
        const Divider(),
        Row(
          children: [
            Expanded(child: Text('Transaction ID\n${tx.id}', style: t.textTheme.bodySmall)),
            IconButton(
              tooltip: 'Copy ID',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => Clipboard.setData(ClipboardData(text: tx.id)),
            ),
          ],
        ),
      ],
    );
  }
}

Color _categoryColor(WalletTxCategory c) => switch (c) {
  WalletTxCategory.ride => const Color(0xFF2DABE2),
  WalletTxCategory.reward => const Color(0xFFD97706),
  WalletTxCategory.referral => const Color(0xFFB8860B),
  WalletTxCategory.transfer => const Color(0xFF0D9488),
  WalletTxCategory.reload => const Color(0xFF16A34A),
  WalletTxCategory.refund => const Color(0xFF0891B2),
  WalletTxCategory.other => const Color(0xFF6B7280),
};

IconData _categoryIcon(WalletTxCategory c) => switch (c) {
  WalletTxCategory.ride => Icons.directions_car_outlined,
  WalletTxCategory.reward || WalletTxCategory.referral => Icons.card_giftcard,
  WalletTxCategory.transfer => Icons.swap_horiz,
  WalletTxCategory.reload => Icons.add,
  WalletTxCategory.refund => Icons.replay,
  WalletTxCategory.other => Icons.payments_outlined,
};
