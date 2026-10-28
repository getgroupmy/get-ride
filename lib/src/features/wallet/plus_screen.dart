// GET.Plus, the rider membership (migration 0316), under Wallet: what it
// gives where the rider is, join (paid now from GET.wallet), cancel or keep
// it, and the receipts.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/booking_modules.dart' show familyModuleGetPlus;
import '../../core/format.dart' show formatMoney;
import '../../core/premium_plus.dart';
import '../../data/family_repository.dart' show familyPayOptionProvider;
import '../../data/geo_service.dart' show knownPosition;
import '../../data/premium_plus_repository.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../ride/plus_parts.dart' show plusBannerColors;

const plusPath = '/wallet/plus';

/// Where the phone is, never asking; a provider so tests can place it.
final plusPositionProvider = Provider<Future<LatLng?> Function()>((_) => knownPosition);

/// The terms where the rider is now (Default's when the phone can't say).
final plusHereProvider = FutureProvider.autoDispose<(PlusPlaceArgs, PremiumPlusTerms)>((ref) async {
  final at = await ref.watch(plusPositionProvider)();
  final args = (lat: at?.latitude, lng: at?.longitude, country: null, state: null, city: null) as PlusPlaceArgs;
  return (args, await ref.watch(premiumPlusRepositoryProvider).terms(args));
});

String _day(DateTime? d) => d == null ? '' : '${d.day} ${_months[d.month - 1]} ${d.year}';
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

class PlusScreen extends ConsumerStatefulWidget {
  const PlusScreen({super.key});

  @override
  ConsumerState<PlusScreen> createState() => _PlusScreenState();
}

class _PlusScreenState extends ConsumerState<PlusScreen> {
  Future<void> _join(PlusPlaceArgs at, PremiumPlusTerms terms) async {
    final price = terms.plus.price;
    final ok = await showAppDialog<bool>(
      id: 'plus.join',
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.workspace_premium),
        title: const Text('Join GET.Plus?'),
        content: Text(
          '${formatMoney(price)} is taken from GET.wallet now, and again each month until you cancel. '
          'Cancel any time: GET.Plus stays until the end of the month you paid for.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          FilledButton(
            key: const ValueKey('plus-join-confirm'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(c, true),
            child: Text('Pay ${formatMoney(price)}'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final charged = await ref.read(premiumPlusRepositoryProvider).join(at, expected: price);
      if (!mounted) return;
      unawaited(showAppNotice(
        id: 'notice.plus',
        context: context,
        title: 'Welcome to GET.Plus',
        message: charged > 0
            ? '${formatMoney(charged)} paid from GET.wallet. Your member prices show when you book.'
            : 'GET.Plus carries on. It renews by itself each month.',
      ));
    } catch (e) {
      if (!mounted) return;
      final short = '$e'.contains('insufficient_balance');
      unawaited(showAppNotice(
        id: 'notice.plus',
        context: context,
        kind: NoticeKind.error,
        title: short ? 'Top up first' : 'Couldn\'t join',
        message: plusError(e, price: price),
        actionLabel: short ? 'Top up' : null,
        onAction: short ? () => context.go('/wallet') : null,
      ));
    } finally {
      ref.invalidate(plusHereProvider);
      ref.invalidate(plusReceiptsProvider);
    }
  }

  Future<void> _cancel(PlusMembership m) async {
    final ok = await showAppDialog<bool>(
      id: 'plus.cancel',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cancel GET.Plus?'),
        content: Text(m.status == PlusStatus.grace
            ? 'GET.Plus ends now. You can join again any time.'
            : 'You keep GET.Plus until ${_day(m.periodEnd)}. Nothing more is taken from GET.wallet.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
          FilledButton(
            key: const ValueKey('plus-cancel-confirm'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Cancel GET.Plus'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(premiumPlusRepositoryProvider).setAutoRenew(false);
    } catch (e) {
      if (mounted) showError(context, plusError(e));
    }
    ref.invalidate(plusHereProvider);
  }

  Future<void> _keep() async {
    try {
      await ref.read(premiumPlusRepositoryProvider).setAutoRenew(true);
      if (mounted) showInfo(context, 'GET.Plus will renew each month.');
    } catch (e) {
      if (mounted) showError(context, plusError(e));
    }
    ref.invalidate(plusHereProvider);
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(plusHereProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('GET.Plus')),
      body: AsyncView(
        value: value,
        onRetry: () => ref.invalidate(plusHereProvider),
        data: (d) => _body(context, d.$1, d.$2),
      ),
    );
  }

  Widget _body(BuildContext context, PlusPlaceArgs at, PremiumPlusTerms terms) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodyMedium?.copyWith(color: mutedTextColor(t));
    final m = terms.membership;
    final live = m != null && m.live;
    final o = terms.plus;
    // A family host's GET.Plus covering this rider (0323), when they have
    // no live membership of their own.
    final covered = !live && (terms.benefits?.family ?? false) ? terms.benefits : null;
    // Family covers GET.Plus for this member, but the host isn't a member.
    final familyRow = covered == null && !live ? ref.watch(familyPayOptionProvider(familyModuleGetPlus)).value : null;
    final c = plusBannerColors(t);
    final receipts = ref.watch(plusReceiptsProvider);
    return ListView(
      key: const ValueKey('plus-page'),
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        ResponsiveCenter(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: c.background, borderRadius: BorderRadius.circular(16)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.workspace_premium, color: c.icon, size: 28),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      live
                          ? 'You\'re a GET.Plus member'
                          : covered != null
                              ? 'You\'re covered by GET.Plus'
                              : 'GET.Plus',
                      key: const ValueKey('plus-title'),
                      style: t.textTheme.titleLarge?.copyWith(color: c.text),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                if (covered != null)
                  Text(
                    covered.familyLine!,
                    key: const ValueKey('plus-family-covered'),
                    style: t.textTheme.bodyLarge?.copyWith(color: c.text, fontWeight: FontWeight.w600),
                  )
                else if (o.on)
                  Text(
                    '${formatMoney(o.price)} a month, paid from GET.wallet.',
                    key: const ValueKey('plus-price'),
                    style: t.textTheme.bodyLarge?.copyWith(color: c.text),
                  )
                else
                  Text(
                    'GET.Plus isn\'t offered where you are yet.',
                    key: const ValueKey('plus-off'),
                    style: t.textTheme.bodyLarge?.copyWith(color: c.text),
                  ),
              ]),
            ),
            const SizedBox(height: 12),
            if (o.on) ...[
              _Benefit(
                icon: Icons.sell_outlined,
                title: '${_n(o.discountPct)}% off your rides',
                body: o.maxDiscount > 0
                    ? 'Up to ${formatMoney(o.maxDiscount)} off a ride. Your driver still gets the full fare.'
                    : 'Your driver still gets the full fare.',
              ),
              if (o.priority)
                const _Benefit(
                  icon: Icons.bolt_outlined,
                  title: 'Priority matching',
                  body: 'Your requests are shown to drivers first.',
                ),
              if (o.freeCancels > 0)
                _Benefit(
                  icon: Icons.event_busy_outlined,
                  title: '${o.freeCancels} free ${o.freeCancels == 1 ? 'cancel' : 'cancels'} a month',
                  body: 'No late cancel fee while you have one left. A no-show still costs its fee.',
                ),
              const SizedBox(height: 12),
            ],
            if (covered != null)
              _FamilyPlanCard(b: covered)
            else if (m != null)
              _MembershipCard(m: m, freeCancels: o.freeCancels),
            if (familyRow != null && familyRow.available && o.on)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Your family plan covers GET.Plus here while ${familyRow.hostName.split(' ').first} is a member.',
                  key: const ValueKey('plus-family-hint'),
                  style: muted,
                ),
              ),
            const SizedBox(height: 12),
            if (o.on && m?.status == PlusStatus.grace) ...[
              FilledButton(
                key: const ValueKey('plus-join'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => _join(at, terms),
                child: Text('Pay ${formatMoney(o.price)} now'),
              ),
              const SizedBox(height: 8),
            ],
            if (live && m.autoRenew)
              OutlinedButton(
                key: const ValueKey('plus-cancel'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => _cancel(m),
                child: const Text('Cancel GET.Plus'),
              )
            else if (live && m.cancelling)
              BusyButton.filled(
                key: const ValueKey('plus-keep'),
                onPressed: _keep,
                child: const Text('Keep GET.Plus'),
              )
            else if (o.on && !live && covered == null)
              FilledButton(
                key: const ValueKey('plus-join'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => _join(at, terms),
                child: Text('Join for ${formatMoney(o.price)} a month'),
              ),
            if (o.on && covered == null && (!live || m.status == PlusStatus.grace))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('GET.wallet: ${formatMoney(terms.walletBalance)}', key: const ValueKey('plus-wallet'),
                    style: muted),
              ),
            const SizedBox(height: 20),
            Text('Receipts', style: t.textTheme.titleMedium),
            const SizedBox(height: 6),
            AsyncView(
              value: receipts,
              onRetry: () => ref.invalidate(plusReceiptsProvider),
              data: (list) => list.isEmpty
                  ? Text('No GET.Plus payments yet.', style: muted)
                  : Card(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      child: Column(children: [
                        for (final (i, r) in list.indexed) ...[
                          if (i > 0) const Divider(height: 1),
                          ListTile(
                            key: ValueKey('plus-receipt-${r.id}'),
                            leading: Icon(r.paid ? Icons.receipt_long_outlined : Icons.error_outline,
                                color: r.paid ? null : t.colorScheme.error),
                            title: Text('${r.label} · ${r.kind == 'join' ? 'Joined' : 'Renewal'}'),
                            subtitle: Text(r.paid
                                ? '${_day(r.periodStart)} to ${_day(r.periodEnd)} · paid ${_day(r.createdAt)}'
                                : '${r.note ?? 'Not paid'} · ${_day(r.createdAt)}'),
                            trailing: Text(r.paid ? formatMoney(r.amount) : 'Not paid', style: t.textTheme.titleSmall),
                          ),
                        ],
                      ]),
                    ),
            ),
          ]),
        ),
      ],
    );
  }
}

String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

class _Benefit extends StatelessWidget {
  const _Benefit({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title, body;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, color: t.colorScheme.primary),
      title: Text(title),
      subtitle: Text(body),
    );
  }
}

/// A member covered by their family host's GET.Plus (0323): whose plan,
/// and the family's free cancels this month.
class _FamilyPlanCard extends StatelessWidget {
  const _FamilyPlanCard({required this.b});
  final PlusBenefits b;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final left = b.freeCancelsLeft;
    return Card(
      key: const ValueKey('plus-family-plan'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Family plan', style: t.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '${b.familyLine}. You don\'t pay for GET.Plus while you are in the family.',
            key: const ValueKey('plus-family-line'),
          ),
          if (b.freeCancels > 0) ...[
            const SizedBox(height: 4),
            Text(
              left <= 0
                  ? 'No free cancels left for the family this month.'
                  : '$left free ${left == 1 ? 'cancel' : 'cancels'} left for the family this month.',
              key: const ValueKey('plus-family-cancels'),
              style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
            ),
          ],
        ]),
      ),
    );
  }
}

class _MembershipCard extends StatelessWidget {
  const _MembershipCard({required this.m, required this.freeCancels});
  final PlusMembership m;
  final int freeCancels;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final line = switch (m.status) {
      PlusStatus.active when !m.autoRenew => 'Cancelled: GET.Plus stays until ${_day(m.periodEnd)}.',
      PlusStatus.active => 'Renews on ${_day(m.periodEnd)} for ${formatMoney(m.price)}.',
      PlusStatus.grace =>
        'We couldn\'t take this month\'s ${formatMoney(m.price)}. Top up GET.wallet by ${_day(m.graceUntil)} to keep GET.Plus.',
      PlusStatus.ended => 'Your GET.Plus ended. Join again any time.',
      PlusStatus.expired => 'GET.Plus ended because GET.wallet was short. Join again any time.',
    };
    final left = freeCancels - m.freeCancelsUsed;
    return Card(
      key: const ValueKey('plus-membership'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(m.status.label, style: t.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(line, key: const ValueKey('plus-status-line')),
          if (m.live && freeCancels > 0) ...[
            const SizedBox(height: 4),
            Text(
              left <= 0 ? 'No free cancels left this month.' : '$left free ${left == 1 ? 'cancel' : 'cancels'} left this month.',
              style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
            ),
          ],
        ]),
      ),
    );
  }
}
