// The driver's side of the Freight and Courier add-ons (migration 0312, the
// DriverCod board): the cash on delivery to collect (settled from the
// driver's GET.wallet to the sender, less the fee; or "Recipient won't pay",
// back to the sender at the return rate), a covered parcel's photos, a round
// trip's return leg with the free wait at the drop-off, and the stairs and
// cold truck booked. Colours from the theme, so light and dark both read.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/delivery_addons.dart';
import '../../core/freight.dart' show freightTimerText;
import '../../data/delivery_addons_repository.dart';
import '../../data/models.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';

class DeliveryAddonsDriverPanel extends ConsumerStatefulWidget {
  const DeliveryAddonsDriverPanel({super.key, required this.request, this.clock = DateTime.now});
  final RideRequest request;
  final DateTime Function() clock;

  @override
  ConsumerState<DeliveryAddonsDriverPanel> createState() => _DeliveryAddonsDriverPanelState();
}

class _DeliveryAddonsDriverPanelState extends ConsumerState<DeliveryAddonsDriverPanel> {
  bool _busy = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && RideAddons.fromRow(widget.request.raw).step == ReturnLegStep.waiting) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  RideRequest get r => widget.request;
  String _money(double v) => r.fareText(v);

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _collected(RideAddons a) => _run(() async {
    final res = await ref.read(deliveryAddonsRepositoryProvider).codCollected(r.id);
    if (!mounted) return;
    final amount = (res['amount'] as num?)?.toDouble() ?? a.picks.cod ?? 0;
    final fee = (res['fee'] as num?)?.toDouble() ?? a.codFee ?? 0;
    await showAppNotice(
      context: context,
      id: 'notice.delivery-cod',
      title: 'Delivered, COD settled',
      message: '${_money(amount)} moved from your GET.wallet to the sender, less the ${_money(fee)} COD fee. '
          'Keep the cash; it replaces what left your wallet.',
    );
  });

  Future<void> _refused() async {
    final ok = await showAppDialog<bool>(
      id: 'partner-trip.cod-refused',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("Recipient won't pay?"),
        content: const Text(
          'The trip becomes a return to the sender at the return rate, and the sender is told. Keep the parcel safe '
          'until then.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Back')),
          FilledButton(
            key: const ValueKey('driver-cod-refused-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Bring it back'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(() => ref.read(deliveryAddonsRepositoryProvider).codRefused(r.id));
  }

  Future<void> _arrived() => _run(() => ref.read(deliveryAddonsRepositoryProvider).returnArrived(r.id));

  Future<void> _startBack() => _run(() async {
    final res = await ref.read(deliveryAddonsRepositoryProvider).returnStart(r.id);
    final fee = (res['wait_fee'] as num?)?.toDouble() ?? 0;
    if (mounted && fee > 0) {
      showInfo(context, 'The wait at the drop-off added ${_money(fee)} to the fare.');
    }
  });

  @override
  Widget build(BuildContext context) {
    final a = RideAddons.fromRow(r.raw);
    if (!a.any) return const SizedBox.shrink();
    final t = Theme.of(context);
    final onTrip = r.status == RideStatus.onTrip;
    final rule = a.rule;
    final children = <Widget>[];
    void gap() => children.add(const SizedBox(height: 10));

    // Cash on delivery.
    if (a.picks.cod case final cod?) {
      final c = t.colorScheme;
      children.add(_Card(
        key: const ValueKey('driver-cod'),
        color: c.tertiaryContainer,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.payments_outlined, color: c.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Collect ${_money(cod)} cash for the item',
                style: t.textTheme.titleSmall?.copyWith(color: c.onTertiaryContainer, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            'Hand over the parcel only after you have the cash. Your delivery fee is paid as usual.',
            style: t.textTheme.bodySmall?.copyWith(color: c.onTertiaryContainer),
          ),
        ]),
      ));
      if (a.codCollected || a.codRefused) {
        gap();
        children.add(_Card(
          key: ValueKey(a.codRefused ? 'driver-cod-refused' : 'driver-cod-settled'),
          color: a.codRefused ? c.errorContainer : c.secondaryContainer,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              a.codRefused ? 'Bring the parcel back' : 'Delivered, COD settled',
              style: t.textTheme.titleSmall?.copyWith(
                color: a.codRefused ? c.onErrorContainer : c.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              a.codRefused
                  ? 'The trip becomes a return to the sender at the return rate; the sender is told. Keep the parcel '
                      'safe until then.'
                  : '${_money(cod)} moved from your GET.wallet to the sender, less the ${_money(a.codFee ?? 0)} COD '
                      'fee. Keep the cash; it replaces what left your wallet.',
              style: t.textTheme.bodySmall?.copyWith(color: a.codRefused ? c.onErrorContainer : c.onSecondaryContainer),
            ),
          ]),
        ));
      } else if (onTrip) {
        gap();
        children.add(FilledButton(
          key: const ValueKey('driver-cod-collect'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : () => _collected(a),
          child: Text('I have the ${_money(cod)} cash'),
        ));
        children.add(const SizedBox(height: 8));
        children.add(OutlinedButton(
          key: const ValueKey('driver-cod-refuse'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : _refused,
          child: const Text("Recipient won't pay"),
        ));
      }
      children.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          'Cash you hold for COD is taken from your GET.wallet at hand-over and paid to the sender. You can carry up '
          'to ${_money(rule.codCarry)} of COD at a time.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ));
    }

    // A covered parcel: the photos at pickup and hand-over.
    if (a.picks.cover) {
      if (children.isNotEmpty) gap();
      final declared = (r.raw['declared_value'] as num?)?.toDouble();
      Widget chip(String label, bool done, Key key) => Chip(
        key: key,
        avatar: Icon(
          done ? Icons.check_circle : Icons.add_a_photo_outlined,
          size: 18,
          color: done ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant,
        ),
        label: Text(label),
      );
      children.add(_Card(
        key: const ValueKey('driver-cover'),
        outlined: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            declared == null ? 'Covered parcel' : 'Covered parcel · declared ${_money(declared)}',
            style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Take a photo at pickup and at hand-over; they are kept with the trip for any claim.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            chip('Pickup photo', r.pickupProofPath != null, const ValueKey('driver-cover-pickup')),
            chip('Hand-over photo', r.dropoffProofPath != null, const ValueKey('driver-cover-handover')),
          ]),
        ]),
      ));
    }

    // The return leg.
    final step = a.step;
    if (step != ReturnLegStep.none) {
      if (children.isNotEmpty) gap();
      final now = widget.clock();
      final waited = a.returnArrivedAt == null ? 0 : waitedMinutes(a.returnArrivedAt!, now);
      final text = switch (step) {
        ReturnLegStep.outward =>
          'After the drop-off, come back to the pickup. ${returnWaitLabel(rule)}, ${returnWaitRule(rule, _money)}.',
        ReturnLegStep.waiting =>
          'Waiting at the drop-off: ${freightTimerText(now.difference(a.returnArrivedAt!))}. '
              '${returnWaitLabel(rule)}; so far ${_money(returnWaitFee(waited, rule))}.',
        ReturnLegStep.returning => a.codRefused
            ? 'Return leg: bringing the parcel back to the sender.'
            : 'Return leg: heading back to the pickup'
                '${(a.returnWaitFee ?? 0) > 0 ? '. The wait added ${_money(a.returnWaitFee!)}' : ''}.',
        ReturnLegStep.none => '',
      };
      children.add(_Card(
        key: const ValueKey('driver-return-leg'),
        outlined: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.sync_alt, color: t.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                a.picks.roundTrip ? 'Round trip' : 'Return to the sender',
                style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            if (a.returnLegFare case final f? when f > 0) Text(_money(f), style: t.textTheme.titleSmall),
          ]),
          const SizedBox(height: 4),
          Text(text, key: const ValueKey('driver-return-leg-text'), style: t.textTheme.bodySmall),
          if (onTrip && a.picks.roundTrip && step == ReturnLegStep.outward) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              key: const ValueKey('driver-return-arrived'),
              onPressed: _busy || a.codPending ? null : _arrived,
              child: const Text("I'm at the drop-off"),
            ),
          ],
          if (onTrip && step == ReturnLegStep.waiting) ...[
            const SizedBox(height: 8),
            FilledButton(
              key: const ValueKey('driver-return-start'),
              onPressed: _busy ? null : _startBack,
              child: const Text('Start the return leg'),
            ),
          ],
        ]),
      ));
    }

    // Stairs and the cold truck, to know before going.
    final floors = a.picks.stairsPickup + a.picks.stairsDrop;
    final level = rule.coldLevel(a.picks.coldLevel);
    if (floors > 0 || level != null) {
      if (children.isNotEmpty) gap();
      children.add(Column(
        key: const ValueKey('driver-addon-info'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (floors > 0)
            Text(
              'Stairs without a lift: ${a.picks.stairsPickup} at pickup, ${a.picks.stairsDrop} at drop-off',
              style: t.textTheme.bodyMedium,
            ),
          if (level != null) Text('Cold truck: ${level.name}', style: t.textTheme.bodyMedium),
        ],
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

class _Card extends StatelessWidget {
  const _Card({super.key, required this.child, this.color, this.outlined = false});
  final Widget child;
  final Color? color;
  final bool outlined;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(16),
      border: outlined ? Border.all(color: Theme.of(context).colorScheme.outlineVariant) : null,
    ),
    child: child,
  );
}

/// Why a delivery with add-ons can't end yet, for the driver; null when it can.
String? addonsCompleteProblem(RideAddons a) {
  if (a.codPending) return "Collect the cash for the item, or tap Recipient won't pay, first.";
  if (a.picks.roundTrip && a.returnStartedAt == null) {
    return 'Start the return leg at the drop-off; the trip ends back at the pickup.';
  }
  return null;
}
