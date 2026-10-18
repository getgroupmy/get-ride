// What a statement's QR code opens (`getride.my/verify/<token>`), for anyone,
// signed in or not: whether GET.ride issued that statement, to whose
// initials, for which period and with what net, and whether it was final
// or since revised (migration 0201). Nothing else about the driver.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/partner_statement.dart';
import '../../data/partner_statement_repository.dart';
import '../../widgets/common.dart';

final statementVerificationProvider = FutureProvider.autoDispose.family<StatementVerification?, String>(
  (ref, token) async =>
      isStatementToken(token) ? ref.watch(partnerStatementRepositoryProvider).verify(token.trim()) : null,
);

class StatementVerifyScreen extends ConsumerWidget {
  const StatementVerifyScreen({super.key, required this.token});
  final String token;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Verify a statement'), automaticallyImplyLeading: false),
      body: AsyncView(
        value: ref.watch(statementVerificationProvider(token)),
        onRetry: () => ref.invalidate(statementVerificationProvider(token)),
        data: (v) {
          if (v == null) {
            return const EmptyState(
              key: ValueKey('verify-unknown'),
              icon: Icons.gpp_bad_outlined,
              title: 'Not a GET.ride statement',
              message:
                  'This code doesn\'t match any statement GET.ride issued. Check the link or ask the driver for '
                  'the original.',
            );
          }
          final p = v.period;
          Widget row(String label, String value, {Key? key}) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 120,
                  child: Text(label, style: TextStyle(color: c.onSurfaceVariant)),
                ),
                Expanded(child: Text(value, key: key)),
              ],
            ),
          );
          // The app's usual "13 Oct 2026", as the period reads.
          String date(DateTime? d) => d == null ? '—' : DateFormat('d MMM yyyy').format(d.toLocal());

          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            children: [
              ResponsiveCenter(
                child: Card(
                  key: const ValueKey('verify-card'),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.verified_outlined, color: c.primary),
                            const SizedBox(width: 8),
                            Expanded(child: Text('Issued by GET.ride', style: t.textTheme.titleMedium)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        row('Statement no.', v.statementNo, key: const ValueKey('verify-no')),
                        row('Driver', v.initials.isEmpty ? '—' : v.initials.split('').join('.')),
                        row('Period', '${p.type.label} · ${p.label}'),
                        row('Net earnings', formatMoney(v.net), key: const ValueKey('verify-net')),
                        row('Status', p.status.label, key: const ValueKey('verify-status')),
                        if (v.revisedAt != null) row('Revised on', date(v.revisedAt)),
                        row('Issued', date(v.issuedAt)),
                        const SizedBox(height: 8),
                        Text(
                          p.status == StatementStatus.provisional
                              ? 'A provisional statement covers a period that was still open: its numbers may have '
                                    'changed since.'
                              : 'Compare these with the statement you were given. If they differ, the statement was '
                                    'altered.',
                          style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
