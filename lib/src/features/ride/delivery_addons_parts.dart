// The Freight and Courier add-ons on the booking pages (migration 0312, the
// Booking board): round trip for both, stairs and the cold truck on Freight,
// parcel cover and cash on delivery for the item on Courier, each shown only
// where the admin's rule switches it on at the pickup; the breakdown of what
// the sender pays; and the sender's parcel cover claim after the delivery.
// Colours come from the theme, so light and dark both read.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/delivery_addons.dart';
import '../../data/delivery_addons_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';

/// A round outlined − or + button.
class AddonStepButton extends StatelessWidget {
  const AddonStepButton({super.key, required this.add, required this.tooltip, this.onPressed, this.size = 40});
  final bool add;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SizedBox.square(
      dimension: size,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          shape: const CircleBorder(),
          side: BorderSide(color: t.colorScheme.outline),
        ),
        icon: Icon(add ? Icons.add : Icons.remove, size: 20),
        onPressed: onPressed,
      ),
    );
  }
}

/// A row: its title and note, − value +.
class AddonStepperRow extends StatelessWidget {
  const AddonStepperRow({
    super.key,
    required this.keyPrefix,
    required this.title,
    this.note,
    required this.value,
    this.onDown,
    this.onUp,
    this.valueWidth = 28,
    this.downTooltip = 'Fewer',
    this.upTooltip = 'More',
  });

  final String keyPrefix, title, value, downTooltip, upTooltip;
  final String? note;
  final VoidCallback? onDown, onUp;
  final double valueWidth;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.textTheme.titleSmall),
            if (note != null)
              Text(note!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
        AddonStepButton(key: ValueKey('$keyPrefix-down'), add: false, tooltip: downTooltip, onPressed: onDown),
        SizedBox(
          width: valueWidth,
          child: Text(
            value,
            key: ValueKey('$keyPrefix-value'),
            textAlign: TextAlign.center,
            style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        AddonStepButton(key: ValueKey('$keyPrefix-up'), add: true, tooltip: upTooltip, onPressed: onUp),
      ]),
    );
  }
}

/// A tick box with a title and a note, the board's add-on tile.
class AddonTickTile extends StatelessWidget {
  const AddonTickTile({super.key, required this.title, required this.note, required this.on, required this.onTap});
  final String title, note;
  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      checked: on,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(children: [
            Icon(
              on ? Icons.check_box : Icons.check_box_outline_blank,
              size: 26,
              color: on ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: t.textTheme.titleSmall),
                Text(note, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: child,
  );
}

/// The add-ons switched on at the pickup for a Freight ([freight]) or
/// Courier booking. Nothing shows when none is.
class DeliveryAddonsSection extends StatelessWidget {
  const DeliveryAddonsSection({
    super.key,
    required this.freight,
    required this.addons,
    required this.picks,
    required this.onChanged,
    required this.money,
    this.declared,
    this.onDeclared,
  });

  final bool freight;
  final DeliveryAddons addons;
  final AddonPicks picks;
  final ValueChanged<AddonPicks> onChanged;
  final String Function(double) money;

  /// The declared value (the cover's), and a change to it from the cover's stepper.
  final double? declared;
  final ValueChanged<double>? onDeclared;

  @override
  Widget build(BuildContext context) {
    final a = addons;
    final offered = a.offered(freight: freight).toSet();
    if (offered.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final rows = <Widget>[];
    void gap() => rows.add(const SizedBox(height: 8));

    if (offered.contains(DeliveryAddon.roundTrip)) {
      rows.add(_Box(
        child: AddonTickTile(
          key: const ValueKey('addon-round-trip'),
          title: 'Round trip',
          note: roundTripNote(a),
          on: picks.roundTrip,
          onTap: () => onChanged(picks.copyWith(roundTrip: !picks.roundTrip)),
        ),
      ));
    }
    if (offered.contains(DeliveryAddon.stairs)) {
      if (rows.isNotEmpty) gap();
      rows.add(AddonStepperRow(
        keyPrefix: 'addon-stairs-pickup',
        title: 'Stairs at pickup',
        note: 'Floors without a lift, ${money(a.perFloor)} a floor',
        value: '${picks.stairsPickup}',
        downTooltip: 'Fewer floors',
        upTooltip: 'More floors',
        onDown: picks.stairsPickup > 0 ? () => onChanged(picks.copyWith(stairsPickup: picks.stairsPickup - 1)) : null,
        onUp: picks.stairsPickup < a.maxFloors ? () => onChanged(picks.copyWith(stairsPickup: picks.stairsPickup + 1)) : null,
      ));
      rows.add(AddonStepperRow(
        keyPrefix: 'addon-stairs-drop',
        title: 'Stairs at drop-off',
        note: 'Floors without a lift',
        value: '${picks.stairsDrop}',
        downTooltip: 'Fewer floors',
        upTooltip: 'More floors',
        onDown: picks.stairsDrop > 0 ? () => onChanged(picks.copyWith(stairsDrop: picks.stairsDrop - 1)) : null,
        onUp: picks.stairsDrop < a.maxFloors ? () => onChanged(picks.copyWith(stairsDrop: picks.stairsDrop + 1)) : null,
      ));
      if (a.helperFrom > 0) {
        rows.add(Text(
          'From ${a.helperFrom} floors at either end, add a helper.',
          key: const ValueKey('addon-stairs-helper-note'),
          style: t.textTheme.bodySmall?.copyWith(color: muted),
        ));
      }
    }
    if (offered.contains(DeliveryAddon.cold) && a.coldLevels.isNotEmpty) {
      if (rows.isNotEmpty) gap();
      final levels = a.coldLevels;
      rows.add(_Box(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AddonTickTile(
            key: const ValueKey('addon-cold'),
            title: 'Cold truck',
            note: '${levels.map((l) => l.name).join(' or ')}; only refrigerated vehicles see it',
            on: picks.coldLevel != null,
            onTap: () => onChanged(picks.copyWith(coldLevel: () => picks.coldLevel == null ? levels.first.id : null)),
          ),
          if (picks.coldLevel != null && levels.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final l in levels)
                  ChoiceChip(
                    key: ValueKey('addon-cold-level-${l.id}'),
                    label: Text('${l.name} · ${money(l.charge)}'),
                    selected: picks.coldLevel == l.id,
                    onSelected: (_) => onChanged(picks.copyWith(coldLevel: () => l.id)),
                  ),
              ]),
            ),
        ]),
      ));
    }
    if (offered.contains(DeliveryAddon.cover)) {
      if (rows.isNotEmpty) gap();
      final v = declared ?? 0;
      final step = 100.0;
      rows.add(_Box(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AddonTickTile(
            key: const ValueKey('addon-cover'),
            title: 'Parcel cover',
            note: coverNote(a, money),
            on: picks.cover,
            onTap: () => onChanged(picks.copyWith(cover: !picks.cover)),
          ),
          if (picks.cover && onDeclared != null) ...[
            AddonStepperRow(
              keyPrefix: 'addon-cover-value',
              title: 'Declared value',
              value: money(v),
              valueWidth: 88,
              downTooltip: 'Lower',
              upTooltip: 'Raise',
              onDown: v - step >= step ? () => onDeclared!(v - step) : null,
              onUp: v + step <= a.coverMax ? () => onDeclared!(v + step) : null,
            ),
            if (a.excluded.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'Not covered: ${a.excluded.join(', ')}. Claims within ${a.claimDays} days.',
                  key: const ValueKey('addon-cover-excluded'),
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
          ],
        ]),
      ));
    }
    if (offered.contains(DeliveryAddon.cod)) {
      if (rows.isNotEmpty) gap();
      final c = picks.cod ?? 0;
      const step = 10.0;
      rows.add(_Box(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AddonTickTile(
            key: const ValueKey('addon-cod'),
            title: 'Cash on delivery for the item',
            note: codNote(a, money),
            on: picks.cod != null,
            onTap: () => onChanged(picks.copyWith(
              cod: () => picks.cod == null ? (a.codMax >= 100 ? 100.0 : a.codMax) : null,
            )),
          ),
          if (picks.cod != null)
            AddonStepperRow(
              keyPrefix: 'addon-cod-amount',
              title: 'Collect from recipient',
              value: money(c),
              valueWidth: 88,
              downTooltip: 'Lower',
              upTooltip: 'Raise',
              onDown: c - step >= step ? () => onChanged(picks.copyWith(cod: () => c - step)) : null,
              onUp: c + step <= a.codMax ? () => onChanged(picks.copyWith(cod: () => c + step)) : null,
            ),
        ]),
      ));
    }
    return Column(
      key: const ValueKey('delivery-addons'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

/// What the sender pays, line by line (the Booking board's grey box).
class DeliveryBreakdown extends StatelessWidget {
  const DeliveryBreakdown({super.key, required this.lines, required this.total, required this.money});
  final List<BreakdownLine> lines;
  final double total;
  final String Function(double) money;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Container(
      key: const ValueKey('delivery-breakdown'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(l.label, style: t.textTheme.bodyMedium?.copyWith(color: muted))),
              const SizedBox(width: 8),
              Text(l.value, style: t.textTheme.bodyMedium),
            ]),
          ),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: Text('You pay', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
          Text(
            money(total),
            key: const ValueKey('delivery-breakdown-total'),
            style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ]),
      ]),
    );
  }
}

/// The add-ons on a booked request, as the sender reads them on its card.
String bookedAddonsText(RideAddons r, String Function(double) money) {
  final p = r.picks;
  return [
    if (p.roundTrip) 'Round trip',
    if (p.stairsPickup + p.stairsDrop > 0) 'Stairs ${p.stairsPickup} up, ${p.stairsDrop} down',
    if (r.rule.coldLevel(p.coldLevel) case final l?) 'Cold truck, ${l.name}',
    if (p.cover) 'Covered',
    if (p.cod case final c?) 'COD ${money(c)}${r.codRefused ? ', not paid' : (r.codCollected ? ', paid to you' : '')}',
  ].join(' · ');
}

/// On a covered delivery's card: its claim, or the button to file one while
/// the claim days last.
class CoverClaimTile extends ConsumerWidget {
  const CoverClaimTile({
    super.key,
    required this.rideId,
    required this.declared,
    required this.claimDays,
    required this.ended,
    required this.money,
  });

  final String rideId;
  final double declared;
  final int claimDays;
  final DateTime? ended;
  final String Function(double) money;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final claim = ref.watch(rideCoverClaimProvider(rideId)).value;
    if (claim != null) {
      return Text(
        'Parcel cover claim for ${money(claim.amount)}: ${claim.statusLabel}'
        '${claim.paidAmount != null ? ', ${money(claim.paidAmount!)} paid to your GET.wallet' : ''}'
        '${claim.adminNote != null && !claim.open ? '. ${claim.adminNote}' : ''}',
        key: const ValueKey('cover-claim-status'),
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      );
    }
    if (!claimOpen(covered: true, ended: ended, claimDays: claimDays, now: DateTime.now())) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const ValueKey('cover-claim-open'),
        icon: const Icon(Icons.verified_user_outlined, size: 18),
        label: const Text('Report a problem with the parcel'),
        onPressed: () => showAppSheet<void>(
          id: 'ride.cover-claim',
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => CoverClaimSheet(rideId: rideId, declared: declared, money: money),
        ),
      ),
    );
  }
}

/// The sender's claim: how much, up to the declared value, and what happened.
class CoverClaimSheet extends ConsumerStatefulWidget {
  const CoverClaimSheet({super.key, required this.rideId, required this.declared, required this.money});
  final String rideId;
  final double declared;
  final String Function(double) money;

  @override
  ConsumerState<CoverClaimSheet> createState() => _CoverClaimSheetState();
}

class _CoverClaimSheetState extends ConsumerState<CoverClaimSheet> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final amount = double.tryParse(_amount.text.trim());
    final problem = claimProblem(amount, _reason.text, widget.declared, widget.money);
    if (problem != null) return showInfo(context, problem);
    setState(() => _busy = true);
    try {
      await ref.read(deliveryAddonsRepositoryProvider).fileClaim(widget.rideId, amount!, _reason.text);
      ref.invalidate(rideCoverClaimProvider(widget.rideId));
      if (!mounted) return;
      Navigator.of(context).pop();
      showInfo(context, 'Claim sent. We will let you know the decision.');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Report a problem with the parcel', style: t.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Your parcel was covered up to ${widget.money(widget.declared)}. The photos at pickup and hand-over are '
          'kept with the trip.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('cover-claim-amount'),
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'Amount to claim', helperText: 'Up to ${widget.money(widget.declared)}'),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('cover-claim-reason'),
          controller: _reason,
          minLines: 2,
          maxLines: 5,
          maxLength: 1000,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'What happened'),
        ),
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey('cover-claim-send'),
          onPressed: _busy ? null : _send,
          child: Text(_busy ? 'Sending...' : 'Send the claim'),
        ),
      ]),
    );
  }
}
