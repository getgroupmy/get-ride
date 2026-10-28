// City ride extras in the apps (migration 0314): the rider's luggage
// picker and waiting rule when booking, the waiting clock both sides see,
// the rider's tip card, and the driver's tip and cash tip card.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/booking_modules.dart' show familyModuleTips;
import '../../core/city_ride_extras.dart';
import '../../core/family.dart' show familyPayLabel;
import '../../core/format.dart';
import '../../data/city_ride_extras_repository.dart';
import '../../data/family_repository.dart' show familyPayOptionProvider, familyTripStatusProvider;
import '../../data/models.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';

// ---- Booking --------------------------------------------------------------------------------------

/// The confirm footer's first rows: how many bags (with what they add) and
/// the waiting rule at the pickup. Nothing when both are off.
class CityExtrasBookingRows extends StatelessWidget {
  const CityExtrasBookingRows({
    super.key,
    required this.luggage,
    required this.waiting,
    required this.bags,
    required this.onBags,
    required this.money,
  });

  final LuggageRules luggage;
  final WaitingRules waiting;
  final int bags;
  final ValueChanged<int> onBags;
  final String Function(double) money;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final rule = waiting.ruleLine(money);
    if (!luggage.on && rule == null) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (luggage.on)
        ConstrainedBox(
          key: const ValueKey('luggage-row'),
          constraints: const BoxConstraints(minHeight: 52),
          child: Row(children: [
            Icon(Icons.luggage_outlined, color: muted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Luggage', style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
                Text(luggage.note(bags, money),
                    key: const ValueKey('luggage-note'), style: t.textTheme.bodySmall?.copyWith(color: muted)),
              ]),
            ),
            IconButton.outlined(
              key: const ValueKey('luggage-down'),
              tooltip: 'Fewer bags',
              onPressed: bags > 0 ? () => onBags(bags - 1) : null,
              icon: const Icon(Icons.remove, size: 20),
            ),
            SizedBox(
              width: 28,
              child: Text('$bags',
                  key: const ValueKey('luggage-count'),
                  textAlign: TextAlign.center,
                  semanticsLabel: bagsLabel(bags),
                  style: t.textTheme.titleMedium),
            ),
            IconButton.outlined(
              key: const ValueKey('luggage-up'),
              tooltip: 'More bags',
              onPressed: bags < luggage.maxBags ? () => onBags(bags + 1) : null,
              icon: const Icon(Icons.add, size: 20),
            ),
          ]),
        ),
      if (rule != null)
        Container(
          key: const ValueKey('waiting-rule'),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: t.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(rule, style: t.textTheme.bodySmall?.copyWith(color: muted, height: 1.4)),
        ),
    ]);
  }
}

// ---- The waiting clock --------------------------------------------------------------------------------

/// While the driver waits at the pickup: free time left, then the charge
/// running, on the same clock for the rider and the driver (the server's
/// start and terms, 0314). Nothing without a clock.
class WaitingClockCard extends StatefulWidget {
  const WaitingClockCard({super.key, required this.ride, this.now});
  final RideRequest ride;

  /// A fixed time instead of the phone's (tests).
  final DateTime Function()? now;

  /// Whether [r] has a clock to show.
  static bool shows(RideRequest r) =>
      r.status == RideStatus.arrived && r.waitingFrom != null && WaitingTerms.fromJson(r.waitingTermsRaw) != null;

  @override
  State<WaitingClockCard> createState() => _WaitingClockCardState();
}

class _WaitingClockCardState extends State<WaitingClockCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    final terms = WaitingTerms.fromJson(r.waitingTermsRaw);
    final from = r.waitingFrom;
    if (!WaitingClockCard.shows(r) || terms == null || from == null) return const SizedBox.shrink();
    final clock = WaitingClock(terms: terms, from: from, now: (widget.now ?? DateTime.now)().toUtc());
    String money(double v) => formatMoney(v, r.currency);
    final t = Theme.of(context);
    final bg = clock.charging ? t.colorScheme.tertiaryContainer : t.colorScheme.secondaryContainer;
    final fg = clock.charging ? t.colorScheme.onTertiaryContainer : t.colorScheme.onSecondaryContainer;
    return Container(
      key: const ValueKey('waiting-clock'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
      child: Semantics(
        liveRegion: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(clock.label, style: t.textTheme.bodySmall?.copyWith(color: fg)),
          Text(clock.headline(money),
              key: const ValueKey('waiting-clock-headline'),
              style: t.textTheme.headlineSmall?.copyWith(color: fg, fontWeight: FontWeight.w700)),
          Text('${clock.note(money)} You both see the same clock.',
              style: t.textTheme.bodySmall?.copyWith(color: fg)),
        ]),
      ),
    );
  }
}

// ---- Tips ---------------------------------------------------------------------------------------------

/// "Fri 30 Oct".
String tipUntilLabel(DateTime? until) => until == null ? '' : DateFormat('EEE d MMM').format(until.toLocal());

/// The rider's tip card after a trip (the payment's Done page, the
/// receipt): the presets and another amount, GET.wallet or GET.coin, once
/// per ride. Nothing when tips are off, the time has passed, or the terms
/// can't be read.
class TipCard extends ConsumerStatefulWidget {
  const TipCard({super.key, required this.ride, this.onInteract});
  final RideRequest ride;

  /// The rider touched the card (the Done page stops its countdown).
  final VoidCallback? onInteract;

  @override
  ConsumerState<TipCard> createState() => _TipCardState();
}

class _TipCardState extends ConsumerState<TipCard> {
  /// The amount picked: a preset, or null for "Other".
  double? _preset;
  bool _other = false;
  final _amount = TextEditingController();
  TipMethod _method = TipMethod.wallet;
  String? _done;
  bool _later = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  double? get _picked => _other ? double.tryParse(_amount.text.trim().replaceAll(',', '.')) : _preset;

  void _touch() => widget.onInteract?.call();

  Future<void> _send(TipTerms terms) async {
    _touch();
    final amount = _picked;
    String money(double v) => formatMoney(v, terms.currency);
    if (amount == null || !terms.allows(amount)) {
      return showInfo(context, 'Type any amount from ${money(terms.min)} to ${money(terms.max)}.');
    }
    try {
      await ref.read(cityRideExtrasRepositoryProvider).tip(widget.ride.id, amount, _method);
    } catch (e) {
      if (mounted) showInfo(context, tipErrorMessage(e));
      return;
    }
    if (!mounted) return;
    setState(() => _done = 'Thanks! ${money(amount)} sent to ${terms.driverFirstName}.');
    ref.invalidate(tipTermsProvider(widget.ride.id));
  }

  @override
  Widget build(BuildContext context) {
    final terms = ref.watch(tipTermsProvider(widget.ride.id)).value;
    if (terms == null || !terms.on) return const SizedBox.shrink();
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    String money(double v) => formatMoney(v, terms.currency, v == v.roundToDouble() ? 0 : 2);
    final given = terms.tip;
    if (_done != null || given != null) {
      return Padding(
        key: const ValueKey('tip-done'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(Icons.volunteer_activism_outlined, color: t.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _done ?? 'You tipped ${money(given!.amount)} with ${given.methodLabel}. Thank you!',
              style: t.textTheme.bodyMedium,
            ),
          ),
        ]),
      );
    }
    if (!terms.canTip) return const SizedBox.shrink();
    if (_later) {
      return Padding(
        key: const ValueKey('tip-later'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('You can tip from the receipt until ${tipUntilLabel(terms.until)}.',
            style: t.textTheme.bodySmall?.copyWith(color: muted)),
      );
    }
    final picked = _picked;
    // Family (0317): a GET.wallet tip on a trip the family pays comes from
    // the host's GET.wallet, where the admin lets the family pay tips.
    final familyTrip = ref.watch(familyTripStatusProvider(widget.ride.id)).value;
    final familyTips = ref.watch(familyPayOptionProvider(familyModuleTips)).value;
    final familyPayer = familyTrip != null && familyTrip.familyPays && (familyTips?.available ?? false)
        ? familyTrip.payer
        : null;
    return Listener(
      onPointerDown: (_) => _touch(),
      child: Column(
        key: const ValueKey('tip-card'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Text('Tip ${terms.driverFirstName}?', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text('${terms.shareLine} ${terms.laterLine}', style: t.textTheme.bodySmall?.copyWith(color: muted)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in terms.presets)
              ChoiceChip(
                key: ValueKey('tip-preset-${p.toStringAsFixed(2)}'),
                label: Text(money(p)),
                selected: !_other && _preset == p,
                onSelected: (_) => setState(() {
                  _other = false;
                  _preset = p;
                }),
              ),
            ChoiceChip(
              key: const ValueKey('tip-other'),
              label: const Text('Other'),
              selected: _other,
              onSelected: (_) => setState(() => _other = true),
            ),
          ]),
          if (_other) ...[
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('tip-amount'),
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              decoration: InputDecoration(
                labelText: 'Amount',
                helperText: 'From ${money(terms.min)} to ${money(terms.max)}',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
          const SizedBox(height: 10),
          SegmentedButton<TipMethod>(
            key: const ValueKey('tip-method'),
            segments: [for (final m in TipMethod.values) ButtonSegment(value: m, label: Text(m.label))],
            selected: {_method},
            onSelectionChanged: (s) => setState(() => _method = s.first),
          ),
          if (familyPayer != null && _method == TipMethod.wallet) ...[
            const SizedBox(height: 6),
            Text('From ${familyPayLabel(familyPayer)}, as the trip was.',
                key: const ValueKey('tip-family'), style: t.textTheme.bodySmall?.copyWith(color: muted)),
          ],
          const SizedBox(height: 10),
          BusyButton.filled(
            key: const ValueKey('tip-send'),
            onPressed: picked == null || picked <= 0 ? null : () => _send(terms),
            child: Text(picked == null || picked <= 0 ? 'Enter an amount' : 'Tip ${money(picked)}'),
          ),
          TextButton(
            key: const ValueKey('tip-not-now'),
            onPressed: () => setState(() => _later = true),
            child: const Text('Not now'),
          ),
        ],
      ),
    );
  }
}

/// The driver's card on a finished trip: the rider's tip, if any, and
/// "Got a cash tip" for their own earnings view.
class DriverTipCard extends ConsumerStatefulWidget {
  const DriverTipCard({super.key, required this.ride});
  final RideRequest ride;

  @override
  ConsumerState<DriverTipCard> createState() => _DriverTipCardState();
}

class _DriverTipCardState extends ConsumerState<DriverTipCard> {
  final _amount = TextEditingController();
  bool? _marked;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save({required bool on}) async {
    final amount = double.tryParse(_amount.text.trim().replaceAll(',', '.'));
    setState(() => _marked = on);
    try {
      await ref.read(cityRideExtrasRepositoryProvider).cashTip(widget.ride.id, on: on, amount: on ? amount : null);
      ref.invalidate(tipTermsProvider(widget.ride.id));
    } catch (e) {
      if (!mounted) return;
      setState(() => _marked = !on);
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final terms = ref.watch(tipTermsProvider(widget.ride.id)).value;
    if (terms == null || widget.ride.status != RideStatus.completed) return const SizedBox.shrink();
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    String money(double v) => formatMoney(v, terms.currency);
    final given = terms.tip;
    final marked = _marked ?? terms.cashTip != null;
    if (_marked == null && terms.cashTip?.amount != null && _amount.text.isEmpty) {
      _amount.text = terms.cashTip!.amount!.toStringAsFixed(2);
    }
    final rider = widget.ride.riderName?.trim().split(RegExp(r'\s+')).first;
    return Card(
      key: const ValueKey('driver-tip-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (given != null)
            Text(
              '${rider == null || rider.isEmpty ? 'Your rider' : rider} tipped ${money(given.amount)}'
              '${given.driverAmount == null || given.driverAmount! >= given.amount ? ' (all yours)' : ' (${money(given.driverAmount!)} after commission)'}.',
              key: const ValueKey('driver-tip-given'),
              style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
          CheckboxListTile(
            key: const ValueKey('driver-cash-tip'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: marked,
            onChanged: (v) => _save(on: v ?? false),
            title: const Text('Got a cash tip (for your earnings only)'),
          ),
          if (marked)
            Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('driver-cash-tip-amount'),
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                  decoration: InputDecoration(labelText: 'How much (optional)', helperText: 'Only you see this', helperStyle: TextStyle(color: muted)),
                ),
              ),
              const SizedBox(width: 8),
              BusyButton.text(
                key: const ValueKey('driver-cash-tip-save'),
                onPressed: () => _save(on: true),
                child: const Text('Save'),
              ),
            ]),
        ]),
      ),
    );
  }
}
