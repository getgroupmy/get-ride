import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/wallet_history.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';

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
        // The title has the bar to itself; the month is picked under it,
        // so neither is cut short on a narrow phone or at large text.
        title: const Text('Transaction history', maxLines: 1, overflow: TextOverflow.ellipsis),
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
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: PopupMenuButton<HistoryMonth>(
                      key: const ValueKey('history-month'),
                      tooltip: 'Month',
                      initialValue: _month,
                      onSelected: (m) => setState(() => _month = m),
                      itemBuilder: (_) => [for (final m in _months) PopupMenuItem(value: m, child: Text(m.label))],
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.calendar_month_outlined, size: 20),
                            const SizedBox(width: 8),
                            Text(_month.label, style: t.textTheme.titleSmall),
                            const Icon(Icons.arrow_drop_down),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Two named rows of chips that wrap, so none hides past
                  // the edge and the two "All"s read as two filters.
                  _FilterRow(
                    label: 'Wallet',
                    chips: [
                      for (final w in <String?>[null, ...wallets])
                        ChoiceChip(
                          key: ValueKey('history-wallet-${w ?? 'all'}'),
                          label: Text(w == null ? 'All' : walletTypeLabel(w)),
                          selected: _wallet == w,
                          onSelected: (_) => setState(() => _wallet = w),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _FilterRow(
                    label: 'Type',
                    chips: [
                      for (final c in <WalletTxCategory?>[null, ...WalletTxCategory.values])
                        FilterChip(
                          key: ValueKey('history-type-${c?.name ?? 'all'}'),
                          label: Text(c?.label ?? 'All'),
                          selected: _category == c,
                          onSelected: (_) => setState(() => _category = c),
                        ),
                    ],
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
                          // Said only under a long month, where the end is
                          // worth saying.
                          if (rows.length > walletHistoryPage) ...[
                            const SizedBox(height: 16),
                            Center(
                              child: Text(
                                'End of history',
                                key: const ValueKey('history-end'),
                                style: t.textTheme.labelSmall?.copyWith(color: mutedTextColor(t)),
                              ),
                            ),
                          ],
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
    showAppSheet<void>(id: 'wallet-history.details',
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(child: _HistoryDetails(tx: tx)),
    );
  }
}

/// About a page's worth of rows: below it there is no "End of history".
const walletHistoryPage = 20;

/// A transaction's status as its row says it: nothing for a success
/// (`completed`, `success`), else the word capitalised ("Pending").
String? walletStatusLabel(String? status) {
  final s = (status ?? '').trim().toLowerCase();
  if (s.isEmpty || s == 'completed' || s == 'success' || s == 'succeeded') return null;
  final words = s.replaceAll(RegExp(r'[_-]+'), ' ');
  return '${words[0].toUpperCase()}${words.substring(1)}';
}

/// "Wallet" / "Type" and the chips after it, wrapping.
class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.label, required this.chips});
  final String label;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(label, style: t.textTheme.labelLarge?.copyWith(color: mutedTextColor(t))),
        ...chips,
      ],
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
      // The status only when it isn't a success, in words and its colour.
      subtitle: Text.rich(
        TextSpan(children: [
          TextSpan(text: '${walletTypeLabel(tx.walletType)} · ${formatTime(tx.createdAt)}'),
          if (walletStatusLabel(tx.status) case final s?)
            TextSpan(
              text: ' · $s',
              style: TextStyle(
                color: s == 'Failed' ? t.colorScheme.error : t.colorScheme.tertiary,
                fontWeight: FontWeight.w600,
              ),
            ),
        ]),
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
