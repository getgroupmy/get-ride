// City ride cancel rules on the screen (migration 0269): the rider's
// "Free to cancel for m:ss" and the fee on Cancel ride; the driver's waiting
// timer at the pickup, "Rider didn't come", and their own cancel rate.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/city_cancel.dart';
import '../../core/format.dart';
import '../../data/city_ride_repository.dart';
import '../../data/models.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';

/// The time now (overridden in tests).
final cityCancelClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Rebuilds once a second while [active].
mixin _Ticking<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  Timer? _timer;

  void tick(bool active) {
    if (active && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!active) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// The rider's Cancel ride while the driver is on the way, with the terms
/// over it: "Free to cancel for 1:42", then what cancelling costs, and the
/// fee on the button. Without the rules (an older server, a scheduled
/// booking) just the button.
class CityCancelButton extends ConsumerStatefulWidget {
  const CityCancelButton({super.key, required this.ride, required this.onPressed});
  final RideRequest ride;
  final VoidCallback? onPressed;

  @override
  ConsumerState<CityCancelButton> createState() => _CityCancelButtonState();
}

class _CityCancelButtonState extends ConsumerState<CityCancelButton> with _Ticking {
  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    final terms = cityCancelApplies(r) ? ref.watch(cancelTermsProvider(r.id)).value : null;
    final now = ref.watch(cityCancelClockProvider)();
    String money(double v) => formatMoney(v, r.currency);
    double fee = 0;
    String? line;
    if (terms != null && !terms.scheduled) {
      final left = terms.freight
          ? null
          : freeCancelLeft(terms.rules, acceptedAt: r.acceptedAt, arrivedAt: r.arrivedAt, now: now);
      tick(left != null);
      fee = cancelFeeFor(terms, r, now);
      line = cancelTermsLineFor(terms, r, now, money: money);
    } else {
      tick(false);
    }
    final t = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (line != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              line,
              key: const ValueKey('ride-cancel-terms'),
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall?.copyWith(
                color: fee > 0 ? t.colorScheme.error : t.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        BusyButton.outlined(
          key: const ValueKey('ride-cancel'),
          icon: const Icon(Icons.close),
          onPressed: widget.onPressed,
          child: Text(cancelButtonLabel(fee, money: money)),
        ),
      ],
    );
  }
}

/// What the cancel dialog says of the fee, or null when it is free.
String? cancelFeeNote(CancelTerms? terms, RideRequest r, DateTime now) {
  if (terms == null || terms.scheduled || !cityCancelApplies(r)) return null;
  final fee = cancelFeeFor(terms, r, now);
  if (fee <= 0) return null;
  if (terms.freight) {
    return 'Your driver is at the pickup: cancelling now costs ${formatMoney(fee, r.currency)}, added to your next '
        'request.';
  }
  return 'Cancelling now costs ${formatMoney(fee, r.currency)}, paid to your driver from GET.wallet (or added to '
      'your next trip). "Driver isn\'t moving" and "Car doesn\'t match" are always free.';
}

/// The driver at the pickup: how long they have waited, when "Rider didn't
/// come" unlocks, and the button itself.
class NoShowPanel extends ConsumerStatefulWidget {
  const NoShowPanel({super.key, required this.ride});
  final RideRequest ride;

  @override
  ConsumerState<NoShowPanel> createState() => _NoShowPanelState();
}

class _NoShowPanelState extends ConsumerState<NoShowPanel> with _Ticking {
  Future<void> _noShow() async {
    final r = widget.ride;
    final terms = ref.read(cancelTermsProvider(r.id)).value;
    final fee = terms?.rules.noShowFee ?? 0;
    final ok = await showAppDialog<bool>(
      id: 'driver.no-show',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rider didn\'t come?'),
        content: Text(
          'The ride ends as a no-show.${fee > 0 && !(terms?.scheduled ?? false) ? ' The rider pays a no-show fee of '
              '${formatMoney(fee, r.currency)}, paid to you less commission.' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep waiting')),
          FilledButton(
            key: const ValueKey('no-show-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('End as no-show'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(cityRideRepositoryProvider).noShow(r.id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    final arrived = r.arrivedAt;
    final terms = ref.watch(cancelTermsProvider(r.id)).value;
    if (r.status != RideStatus.arrived || arrived == null || terms == null) {
      tick(false);
      return const SizedBox.shrink();
    }
    tick(true);
    final now = ref.watch(cityCancelClockProvider)();
    final waited = now.difference(arrived);
    final left = noShowLeft(terms.rules, arrivedAt: arrived, now: now);
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('no-show-panel'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Waiting for ${r.passengerName}', style: t.textTheme.titleSmall),
            Text(
              minSec(waited.isNegative ? Duration.zero : waited),
              key: const ValueKey('no-show-waited'),
              textAlign: TextAlign.center,
              style: t.textTheme.displaySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            Text(
              left > Duration.zero ? '"Rider didn\'t come" unlocks in ${minSec(left)}' : 'You can end it as a no-show',
              key: const ValueKey('no-show-left'),
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            BusyButton.outlined(
              key: const ValueKey('no-show'),
              icon: const Icon(Icons.person_off_outlined),
              onPressed: left > Duration.zero ? null : _noShow,
              child: const Text('Rider didn\'t come'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The driver's own cancel rate, and the pause when it is over the limit.
class DriverCancelRateNote extends ConsumerWidget {
  const DriverCancelRateNote({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(driverCancelStatsProvider).value;
    if (s == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final now = ref.watch(cityCancelClockProvider)();
    final paused = s.pausedAt(now);
    final warn = paused || s.overLimit;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        key: const ValueKey('driver-cancel-rate'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(warn ? Icons.warning_amber_rounded : Icons.info_outline, size: 18,
              color: warn ? t.colorScheme.error : t.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              paused
                  ? '${s.describe()} Offers are paused until ${formatClock(s.pausedUntil!.toLocal())}.'
                  : s.describe(),
              style: t.textTheme.bodySmall?.copyWith(color: warn ? t.colorScheme.error : t.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// "14:05".
String formatClock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
