import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'commerce_data.dart';
import 'get_coin.dart';

/// Admin → Settings → Get Coin: GC exchange rate, ride rewards, market
/// pricing, referral rewards and supply cap (`get_coin_settings` row
/// `master`).
class GetCoinScreen extends ConsumerWidget {
  const GetCoinScreen({super.key});
  static const page = 'admin-settings-get-coin';

  @override
  Widget build(BuildContext context, WidgetRef ref) => AdminPage(
        title: 'Get Coin',
        page: page,
        body: AsyncView(
          value: ref.watch(getCoinProvider),
          onRetry: () => ref.invalidate(getCoinProvider),
          data: (d) => _GetCoinForm(
            key: ValueKey(d.settings.updatedAt),
            settings: d.settings,
            stats: d.stats,
            canEdit: ref.watch(pageAccessProvider(page)) == AccessLevel.edit,
          ),
        ),
      );
}

class _GetCoinForm extends ConsumerStatefulWidget {
  const _GetCoinForm({super.key, required this.settings, required this.stats, required this.canEdit});
  final GetCoinSettings settings;
  final CoinMarketStats stats;
  final bool canEdit;

  @override
  ConsumerState<_GetCoinForm> createState() => _GetCoinFormState();
}

class _GetCoinFormState extends ConsumerState<_GetCoinForm> {
  late GetCoinSettings _s = widget.settings;
  late final _rate = TextEditingController(text: formatRate(_s.coinsPerCurrency));
  late final _earn = TextEditingController(text: formatRate(_s.earnCoinsPerCurrency));
  late final _swing = TextEditingController(text: formatRate(_s.maxSwingPct));
  late final _supply = TextEditingController(text: formatRate(_s.maxSupply));
  late final _refReferrer = TextEditingController(text: formatRate(_s.referralReferrerCoins));
  late final _refReferred = TextEditingController(text: formatRate(_s.referralReferredCoins));
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_rate, _earn, _swing, _supply, _refReferrer, _refReferred]) {
      c.dispose();
    }
    super.dispose();
  }

  double _nonNeg(TextEditingController c) {
    final n = parseLooseNumber(c.text);
    return n != null && n >= 0 ? n : 0;
  }

  double get _parsedRate {
    final n = parseLooseNumber(_rate.text);
    return n != null && n > 0 ? n : 0;
  }

  double get _parsedSwing {
    final n = parseLooseNumber(_swing.text);
    return n == null ? defaultMaxSwingPct : n.clamp(0, 95).toDouble();
  }

  GetCoinSettings get _draft => _s.copyWith(
        coinsPerCurrency: _parsedRate,
        earnCoinsPerCurrency: _nonNeg(_earn),
        maxSwingPct: _parsedSwing,
        maxSupply: _nonNeg(_supply),
        referralReferrerCoins: _nonNeg(_refReferrer),
        referralReferredCoins: _nonNeg(_refReferred),
      );

  bool get _dirty {
    final d = _draft, o = widget.settings;
    return _parsedRate > 0 &&
        (d.coinsPerCurrency != o.coinsPerCurrency ||
            d.earnCoinsPerCurrency != o.earnCoinsPerCurrency ||
            d.marketEnabled != o.marketEnabled ||
            d.signalTrading != o.signalTrading ||
            d.signalRevenue != o.signalRevenue ||
            d.signalServices != o.signalServices ||
            d.signalSignups != o.signalSignups ||
            d.signalMinting != o.signalMinting ||
            d.maxSwingPct != o.maxSwingPct ||
            d.maxSupply != o.maxSupply ||
            d.referralEnabled != o.referralEnabled ||
            d.referralReferrerCoins != o.referralReferrerCoins ||
            d.referralReferredCoins != o.referralReferredCoins);
  }

  Future<void> _save() async {
    setState(() => _error = null);
    if (!(_parsedRate > 0)) return setState(() => _error = 'Enter a rate greater than 0.');
    final r = _draft.toSaveRow();
    if (r.error != null) return setState(() => _error = r.error);
    setState(() => _saving = true);
    final ok = await runAdminAction(
      context,
      () => ref.read(commerceRepositoryProvider).saveGetCoin(r.row!),
      success: 'Get Coin settings saved.',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) ref.invalidate(getCoinProvider);
  }

  Widget _numField(TextEditingController c, String label, {String? suffix, String? helper}) => TextField(
        controller: c,
        enabled: widget.canEdit,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, suffixText: suffix, helperText: helper, helperMaxLines: 2),
        onChanged: (_) => setState(() => _error = null),
      );

  Widget _switch(String title, String? subtitle, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        value: value,
        onChanged: widget.canEdit ? (v) => setState(() => onChanged(v)) : null,
      );

  Widget _card(IconData icon, String title, String body, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
            ]),
            const SizedBox(height: 6),
            Text(body, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            ...children,
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final rate = _parsedRate;
    final earn = _nonNeg(_earn);
    final supply = _nonNeg(_supply);
    final refA = _nonNeg(_refReferrer), refB = _nonNeg(_refReferred);
    final market = rate > 0 ? computeMarketRate(_draft, widget.stats) : null;
    final t = Theme.of(context);
    return ResponsiveCenter(
      maxWidth: 720,
      child: ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
        if (!widget.settings.fromDatabase)
          const Card(
            child: ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('No Get Coin settings saved yet — showing defaults.'),
            ),
          ),
        _card(Icons.swap_horiz, 'Exchange rate',
            'How many Get Coins (GC) equal RM1. GET.coin balances everywhere in the app use this rate for their approximate RM value.', [
          _numField(_rate, 'GC per RM1', suffix: 'GC'),
          if (rate > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('1 GC ≈ RM ${_fourDp(coinsToCurrency(1, rate))}'),
            ),
          if (widget.settings.updatedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Last updated ${dateText(widget.settings.updatedAt)}', style: t.textTheme.bodySmall),
            ),
        ]),
        _card(Icons.card_giftcard, 'Ride rewards',
            'Coins riders earn per RM1 of a completed trip fare. Set to 0 to turn ride rewards off.', [
          _numField(_earn, 'GC earned per RM1', suffix: 'GC'),
          const SizedBox(height: 8),
          Text(earn > 0
              ? 'Example: a RM25.00 trip rewards ${formatRate(rideRewardCoins(25, earn))} GC'
              : 'Ride rewards are currently off.'),
        ]),
        _card(Icons.trending_up, 'Market pricing',
            'When on, the coin\'s traded value floats around the pegged rate, driven by live app activity. Spending and ride redemptions always use the pegged rate — only trading uses the market price.', [
          _switch('Market-speculated pricing', null, _s.marketEnabled, (v) => _s = _s.copyWith(marketEnabled: v)),
          if (_s.marketEnabled) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text('PRICE SIGNALS (LAST 30 DAYS)', style: t.textTheme.labelSmall),
            ),
            _switch('Trading', 'Buy vs sell volume between users', _s.signalTrading,
                (v) => _s = _s.copyWith(signalTrading: v)),
            _switch('Commission revenue', 'App revenue charged to partners', _s.signalRevenue,
                (v) => _s = _s.copyWith(signalRevenue: v)),
            _switch('Completed services', 'Trips and orders completed', _s.signalServices,
                (v) => _s = _s.copyWith(signalServices: v)),
            _switch('New sign-ups', 'New active users and partners', _s.signalSignups,
                (v) => _s = _s.copyWith(signalSignups: v)),
            _switch('New coins generated', 'Rewards, admin grants & purchases (pushes price down)', _s.signalMinting,
                (v) => _s = _s.copyWith(signalMinting: v)),
            const SizedBox(height: 8),
            _numField(_swing, 'Max price swing', suffix: '%',
                helper: 'The market rate never moves more than ±${formatRate(_parsedSwing)}% from the peg.'),
            if (market != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Live market now: 1 GC ≈ RM ${market.ratePerGC.toStringAsFixed(4)} '
                  '(${market.changePct >= 0 ? '+' : ''}${market.changePct.toStringAsFixed(2)}% vs peg)',
                  style: t.textTheme.titleSmall,
                ),
              ),
            if (market != null)
              for (final c in market.contributions)
                Text('${c.label}: ${c.pct >= 0 ? '+' : ''}${c.pct.toStringAsFixed(2)}%', style: t.textTheme.bodySmall),
          ],
        ]),
        _card(Icons.group_add_outlined, 'Referral rewards',
            'Bonus GET.coin when a new user signs up with a shared referral link. Both sides are credited automatically the moment the new account is created.', [
          _switch('Referral program', null, _s.referralEnabled, (v) => _s = _s.copyWith(referralEnabled: v)),
          if (_s.referralEnabled) ...[
            _numField(_refReferrer, 'Inviter earns', suffix: 'GC'),
            const SizedBox(height: 8),
            _numField(_refReferred, 'New user earns', suffix: 'GC'),
            const SizedBox(height: 8),
            Text(refA > 0 || refB > 0
                ? 'Each sign-up mints ${formatRate(refA + refB)} GC in total'
                    '${rate > 0 ? ' (≈ RM ${coinsToCurrency(refA + refB, rate).toStringAsFixed(2)})' : ''}.'
                : 'Both amounts are 0 — referrals are tracked but no coins are paid.'),
          ],
        ]),
        _card(Icons.storage_outlined, 'Coin supply',
            'Maximum GC that can ever exist — like Bitcoin\'s 21 million cap. New coins can\'t be minted past this limit. Set to 0 for unlimited supply.', [
          _numField(_supply, 'Max supply', suffix: 'GC'),
          const SizedBox(height: 8),
          Text('${formatCoins(widget.stats.circulatingSupply)} in circulation'
              '${supply > 0 ? ' · ${formatCoins((supply - widget.stats.circulatingSupply).clamp(0, double.infinity).toDouble())} left to mint' : ' · supply is unlimited'}'),
        ]),
        if (rate > 0)
          _card(Icons.toll_outlined, 'Preview', 'Conversions at the pegged rate.', [
            for (final row in [
              ('RM 1.00', '${formatRate(currencyToCoins(1, rate))} GC'),
              ('RM 10.00', '${formatRate(currencyToCoins(10, rate))} GC'),
              ('100 GC', 'RM ${coinsToCurrency(100, rate).toStringAsFixed(2)}'),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [Expanded(child: Text(row.$1)), Text(row.$2)]),
              ),
          ]),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_error!, style: TextStyle(color: t.colorScheme.error)),
          ),
        if (widget.canEdit)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: BusyButton.filled(
              onPressed: _saving || !_dirty ? null : _save,
              icon: const Icon(Icons.check),
              child: const Text('Save'),

            ),
          ),
      ]),
    );
  }

  /// `1 GC ≈ RM 0.1` with trailing zeros trimmed (Expo formatting).
  static String _fourDp(double v) {
    final s = v.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');
    return s.endsWith('.') ? '${s}00' : s;
  }
}
