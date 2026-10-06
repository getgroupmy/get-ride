import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/referral.dart';
import '../../data/referral_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../admin/screens/commerce/get_coin.dart' show formatCoins;
import '../../data/coin_trade_repository.dart';

final myReferrerProvider = FutureProvider.autoDispose<MyReferrer?>(
  (ref) => ref.watch(referralRepositoryProvider).myReferrer(),
);

final myReferralCountProvider = FutureProvider.autoDispose<int?>(
  (ref) => ref.watch(referralRepositoryProvider).myReferralCount(),
);

/// Invite friends (Expo `app/referral-card.tsx`): this account's code and
/// invite link, how many friends joined with it, and who invited this
/// account.
class ReferralScreen extends ConsumerWidget {
  const ReferralScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Invite friends')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ResponsiveCenter(
            maxWidth: 560,
            child: AsyncView(
              value: ref.watch(profileProvider),
              onRetry: () => ref.invalidate(profileProvider),
              data: (p) {
                if (p == null) return const EmptyState(icon: Icons.card_giftcard, title: 'Sign in to invite friends');
                final code = referralCodeFor(userId: p.id, explicitCode: p.referralCode);
                final link = referralLink(code);
                final count = ref.watch(myReferralCountProvider).value;
                final referrer = ref.watch(myReferrerProvider).value;
                final coin = ref.watch(coinSettingsProvider).value;
                final bonus = coin == null
                    ? null
                    : referralBonusLine(
                        enabled: coin.referralEnabled,
                        referrer: coin.referralReferrerCoins,
                        referred: coin.referralReferredCoins,
                        coins: formatCoins,
                      );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            const Icon(Icons.card_giftcard, size: 40),
                            const SizedBox(height: 8),
                            if (bonus != null)
                              Text(
                                bonus,
                                key: const ValueKey('referral-bonus'),
                                textAlign: TextAlign.center,
                                style: t.textTheme.bodyMedium,
                              ),
                            const SizedBox(height: 16),
                            Text('Your referral code', style: t.textTheme.labelLarge),
                            SelectableText(
                              code,
                              key: const ValueKey('referral-code'),
                              style: t.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                letterSpacing: 4,
                              ),
                            ),
                            if (count != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                count == 1 ? '1 friend joined with your code' : '$count friends joined with your code',
                                key: const ValueKey('referral-count'),
                                style: t.textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          key: const ValueKey('referral-copy-code'),
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy code'),
                          onPressed: () => _copy(context, code, 'Referral code copied'),
                        ),
                        FilledButton.icon(
                          key: const ValueKey('referral-copy-invite'),
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                          icon: const Icon(Icons.send),
                          label: const Text('Copy invite'),
                          onPressed: () =>
                              _copy(context, referralMessage(code, link), 'Invite copied, paste it to a friend'),
                        ),
                      ],
                    ),
                    if (referrer != null) ...[
                      const SizedBox(height: 16),
                      Card(
                        child: ListTile(
                          key: const ValueKey('referral-referrer'),
                          leading: const Icon(Icons.verified_outlined),
                          title: Text(referrer.name == null ? 'Referred' : 'Invited by ${referrer.name}'),
                          subtitle: referrer.code == null ? null : Text('Joined with code ${referrer.code}'),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _copy(BuildContext context, String text, String notice) {
    Clipboard.setData(ClipboardData(text: text));
    showInfo(context, notice);
  }
}
