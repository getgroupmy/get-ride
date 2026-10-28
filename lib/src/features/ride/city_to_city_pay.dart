// City to City, paying in the app (migration 0309; the approved board 13):
// the sheet the rider sees when accepting an offer on a trip paid In app
// (the fare held now) and when paying a completed trip (pay after the
// trip): the ways to pay, the breakdown (the trip fare, a cancel fee owed
// added, what coins cover, what is held or paid, or how much is short), and
// Top up (the wallet top-up sheet) or Switch this trip to cash when short.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/city_to_city.dart';
import '../../data/city_to_city_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart' show showError, showInfo;
import '../../widgets/page_style_host.dart';
import '../wallet/wallet_topup.dart' show showWalletTopUp;
import 'city_to_city_parts.dart';

/// Opens the wallet top-up; overridden in tests.
final c2cTopUpProvider = Provider<Future<void> Function(BuildContext)>((_) => (c) => showWalletTopUp(c));

/// What the pay sheet ended with.
enum C2cPayOutcome { paid, cash }

/// Accepts [offer] on [booking]: a cash trip, or an In app trip paid after
/// the trip, at once; an In app trip held at booking through the pay sheet,
/// opened without waiting for it (so the Accept button doesn't spin under
/// it). [onBooked] runs once the trip is booked, either way.
Future<void> acceptC2cOffer(
  BuildContext context,
  WidgetRef ref,
  C2cBooking booking,
  C2cOffer offer, {
  required VoidCallback onBooked,
}) async {
  final repo = ref.read(cityToCityRepositoryProvider);
  try {
    if (booking.payment == C2cPayment.cash) {
      await repo.acceptOffer(offer.id);
      onBooked();
      return;
    }
    final info = await repo.payInfo(booking.id);
    if (info.when == C2cPayWhen.after) {
      await repo.acceptOfferPay(offer.id);
      onBooked();
      return;
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (!context.mounted) return;
  unawaited(showC2cPaySheet(context, booking: booking, offer: offer).then((out) {
    if (out != null) onBooked();
  }));
}

/// The pay sheet: accepting [offer] (held), or paying completed [booking]
/// when [offer] is null.
Future<C2cPayOutcome?> showC2cPaySheet(BuildContext context, {required C2cBooking booking, C2cOffer? offer}) =>
    showAppSheet<C2cPayOutcome>(
      id: 'city-to-city.pay',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => C2cPaySheet(booking: booking, offer: offer),
    );

class C2cPaySheet extends ConsumerStatefulWidget {
  const C2cPaySheet({super.key, required this.booking, this.offer});
  final C2cBooking booking;
  final C2cOffer? offer;

  @override
  ConsumerState<C2cPaySheet> createState() => _C2cPaySheetState();
}

class _C2cPaySheetState extends ConsumerState<C2cPaySheet> {
  C2cPayInfo? _info;
  Object? _error;
  C2cPayWay? _way;

  bool get _after => widget.offer == null;
  double get _fare => widget.offer?.price ?? widget.booking.price;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await ref.read(cityToCityRepositoryProvider).payInfo(widget.booking.id);
      if (!mounted) return;
      setState(() {
        _info = info;
        _error = null;
        if (_way == null || !info.ways.contains(_way)) _way = info.ways.firstOrNull;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _primary(C2cPayInfo info, C2cPayWay way, double total) async {
    final split = c2cPaySplit(total, way, info.walletBalance, info.coinBalance, info.coinRate);
    if (split.short > 0) {
      // Top up; the offer stays until it expires.
      await ref.read(c2cTopUpProvider)(context);
      await _load();
      return;
    }
    final repo = ref.read(cityToCityRepositoryProvider);
    final cur = widget.booking.currency;
    try {
      if (_after) {
        await repo.pay(widget.booking.id, way, total);
      } else {
        await repo.acceptOfferPay(widget.offer!.id, way: way, expected: total);
      }
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop(C2cPayOutcome.paid);
      showInfo(
        nav.context,
        _after
            ? 'Paid. Thank you.'
            : 'Booked. ${c2cMoney(way == C2cPayWay.coin ? split.coinValue : split.walletPart, cur)} '
                  '${way == C2cPayWay.coin ? 'in coins' : 'from your GET wallet'} is held until the trip is complete.',
      );
    } catch (e) {
      if (mounted) showError(context, e);
      await _load();
    }
  }

  Future<void> _cash() async {
    final repo = ref.read(cityToCityRepositoryProvider);
    try {
      await repo.switchToCash(widget.booking.id);
      if (!_after) await repo.acceptOffer(widget.offer!.id);
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop(C2cPayOutcome.cash);
      final who = widget.offer?.driverName ?? 'your driver';
      showInfo(nav.context, 'Switched to cash: pay $who ${c2cMoney(_fare, widget.booking.currency)} in the car.'
          '${(_info?.duesTotal ?? 0) > 0 ? ' The ${c2cMoney(_info!.duesTotal, widget.booking.currency)} owed stays on your wallet.' : ''}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final b = widget.booking;
    final info = _info;
    final first = (widget.offer?.driverName ?? '').split(' ').first;
    final title = _after ? 'Pay for your trip' : "Accept ${first.isEmpty ? 'this' : "$first's"} offer";
    final sub = _after
        ? 'Trip complete: ${b.route}. In this region the fare is paid after the trip.'
        : "The fare is held from your wallet now. ${first.isEmpty ? 'The driver' : first} gets it when the trip is "
              "complete; if it's cancelled it comes back to you (cancel rule applies).";
    Widget body;
    if (info == null) {
      body = _error == null
          ? const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                const Text("Couldn't load your balances."),
                TextButton(onPressed: _load, child: const Text('Try again')),
              ]),
            );
    } else {
      final way = _way;
      final total = c2cRound2(_fare + info.duesTotal);
      final dues = c2cDuesLine(info, b.currency);
      final split = way == null ? null : c2cPaySplit(total, way, info.walletBalance, info.coinBalance, info.coinRate);
      final short = split != null && split.short > 0;
      final lines = way == null ? const <(String, String)>[] : c2cPayLines(_fare, way, info, after: _after, currency: b.currency);
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (dues != null)
          C2cBanner(
            key: const ValueKey('c2c-pay-dues'),
            icon: Icons.receipt_long,
            title: 'Cancel fee owed',
            line: dues,
            fill: look.warn,
            ink: look.onWarn,
          ),
        const SizedBox(height: 8),
        if (info.ways.isEmpty)
          const Text("Paying in the app isn't available for this trip.")
        else
          for (final w in info.ways)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Material(
                color: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: w == way ? t.colorScheme.primary : look.line, width: w == way ? 2 : 1),
                ),
                child: RadioListTile<C2cPayWay>(
                  key: ValueKey('c2c-pay-way-${w.key}'),
                  value: w,
                  // ignore: deprecated_member_use
                  groupValue: way,
                  // ignore: deprecated_member_use
                  onChanged: (v) => setState(() => _way = v),
                  title: Text(w.label),
                  subtitle: Text(c2cPayWayNote(w, info, total, b.currency)),
                ),
              ),
            ),
        const SizedBox(height: 6),
        for (var i = 0; i < lines.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text(lines[i].$1, style: t.textTheme.bodyMedium)),
              Text(
                lines[i].$2,
                key: i == lines.length - 1 ? const ValueKey('c2c-pay-last') : null,
                style: t.textTheme.bodyMedium?.copyWith(
                  fontWeight: i == lines.length - 1 ? FontWeight.w700 : null,
                  color: i == lines.length - 1 && short ? t.colorScheme.error : null,
                ),
              ),
            ]),
          ),
        const SizedBox(height: 12),
        if (way != null && (!short || info.offerTopup))
          SizedBox(
            height: 52,
            child: BusyButton.filled(
              key: const ValueKey('c2c-pay-primary'),
              onPressed: () => _primary(info, way, total),
              child: Text(c2cPayButton(total, way, info, after: _after, currency: b.currency)),
            ),
          ),
        if ((short || info.ways.isEmpty) && info.offerCash) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: BusyButton.outlined(
              key: const ValueKey('c2c-pay-cash'),
              onPressed: _cash,
              child: const Text('Switch this trip to cash'),
            ),
          ),
        ],
        if (short && !info.offerTopup && !info.offerCash)
          Text("Your wallet doesn't hold enough for this trip.", style: TextStyle(color: t.colorScheme.error)),
      ]);
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(sub, style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
        const SizedBox(height: 12),
        body,
      ]),
    );
  }
}
