// Wallet: City to City fees owed (migration 0309): the cancel fees a rider
// owes (a booked trip cancelled late with the GET wallet short) and the
// give-up fees a driver owes, why, how they are collected, and Pay now.
// Hidden when nothing is owed.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/city_to_city.dart';
import '../../data/city_to_city_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart' show showError, showInfo;

class C2cOwedCard extends ConsumerWidget {
  const C2cOwedCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owed = ref.watch(c2cMyOwedProvider).value ?? C2cOwed.none;
    if (!owed.any) return const SizedBox.shrink();
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return Card(
      key: const ValueKey('c2c-owed-card'),
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.receipt_long, color: cs.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text('City to City: you owe ${c2cMoney(owed.total)}',
                  style: t.textTheme.titleMedium?.copyWith(color: cs.onErrorContainer, fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 6),
          for (final d in owed.rider)
            Text('${c2cMoney(d.fee, d.currency)} cancel fee, ${d.ref}${d.route == null ? '' : ' (${d.route})'}: '
                'cancelled late when your GET wallet was short.',
                style: t.textTheme.bodyMedium?.copyWith(color: cs.onErrorContainer)),
          for (final d in owed.driver)
            Text('${c2cMoney(d.owed)} left of the ${c2cMoney(d.fee)} fee for giving up ${d.ref}.',
                style: t.textTheme.bodyMedium?.copyWith(color: cs.onErrorContainer)),
          if (owed.howLine != null && owed.howLine!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(owed.howLine!, style: t.textTheme.bodySmall?.copyWith(color: cs.onErrorContainer)),
          ],
          if (owed.driver.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('A give-up fee comes from your next earnings first.',
                style: t.textTheme.bodySmall?.copyWith(color: cs.onErrorContainer)),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: BusyButton.filled(
              key: const ValueKey('c2c-owed-pay'),
              onPressed: () async {
                try {
                  final paid = await ref.read(cityToCityRepositoryProvider).payOwed();
                  ref.invalidate(c2cMyOwedProvider);
                  if (context.mounted) showInfo(context, 'Paid ${c2cMoney(paid)} from your GET wallet.');
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              child: const Text('Pay now'),
            ),
          ),
        ]),
      ),
    );
  }
}
