// The pickers the ride "booking row" chips (Admin → Display → Booking Row)
// open when tapped. Each chip replaces an older inline control on the confirm
// sheet; the shared gate `bookingChipShown` hides that control when its chip is
// on. This file holds the chip sheets; the taps are wired in home_screen.
import 'package:flutter/material.dart';

import '../../core/city_ride_extras.dart' show LuggageRules;
import '../../widgets/page_style_host.dart' show showAppSheet;

/// The Luggage chip's picker: a bag stepper (0 … [LuggageRules.maxBags]) with
/// the luggage note ("N free, then RMx a bag"). Returns the chosen bag count,
/// or null when dismissed without changing it.
Future<int?> showLuggageSheet(
  BuildContext context, {
  required LuggageRules luggage,
  required int bags,
  required String Function(double) money,
}) =>
    showAppSheet<int>(
      id: 'ride.luggage',
      context: context,
      fitContent: true,
      builder: (context) => _LuggageSheet(luggage: luggage, bags: bags, money: money),
    );

class _LuggageSheet extends StatefulWidget {
  const _LuggageSheet({required this.luggage, required this.bags, required this.money});
  final LuggageRules luggage;
  final int bags;
  final String Function(double) money;

  @override
  State<_LuggageSheet> createState() => _LuggageSheetState();
}

class _LuggageSheetState extends State<_LuggageSheet> {
  late int _bags = widget.luggage.clamp(widget.bags);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Luggage', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(widget.luggage.note(_bags, widget.money),
              key: const ValueKey('luggage-sheet-note'), style: t.textTheme.bodyMedium?.copyWith(color: muted)),
          const SizedBox(height: 16),
          Row(children: [
            Icon(Icons.luggage_outlined, color: muted),
            const SizedBox(width: 12),
            Expanded(child: Text('Bags', style: t.textTheme.titleMedium)),
            IconButton.outlined(
              key: const ValueKey('luggage-sheet-down'),
              tooltip: 'Fewer bags',
              onPressed: _bags > 0 ? () => setState(() => _bags -= 1) : null,
              icon: const Icon(Icons.remove, size: 20),
            ),
            SizedBox(
              width: 36,
              child: Text('$_bags',
                  key: const ValueKey('luggage-sheet-count'), textAlign: TextAlign.center, style: t.textTheme.titleLarge),
            ),
            IconButton.outlined(
              key: const ValueKey('luggage-sheet-up'),
              tooltip: 'More bags',
              onPressed: _bags < widget.luggage.maxBags ? () => setState(() => _bags += 1) : null,
              icon: const Icon(Icons.add, size: 20),
            ),
          ]),
          const SizedBox(height: 18),
          FilledButton(
            key: const ValueKey('luggage-sheet-done'),
            onPressed: () => Navigator.of(context).pop(_bags),
            child: const Text('Done'),
          ),
        ]),
      ),
    );
  }
}

/// The Passengers chip's group-size picker ("What's your group size?"): a
/// stepper 1 … [maxSeats] (the biggest vehicle that can take this trip), with
/// the "can't fit more" notice at the cap and a link to the guidelines.
/// Returns the chosen count, or null when dismissed.
Future<int?> showPassengersSheet(
  BuildContext context, {
  required int count,
  required int maxSeats,
}) =>
    showAppSheet<int>(
      id: 'ride.passengers',
      context: context,
      fitContent: true,
      builder: (context) => _PassengersSheet(count: count, maxSeats: maxSeats),
    );

class _PassengersSheet extends StatefulWidget {
  const _PassengersSheet({required this.count, required this.maxSeats});
  final int count;
  final int maxSeats;

  @override
  State<_PassengersSheet> createState() => _PassengersSheetState();
}

class _PassengersSheetState extends State<_PassengersSheet> {
  int get _max => widget.maxSeats < 1 ? 1 : widget.maxSeats;
  late int _n = widget.count.clamp(1, _max).toInt();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final atCap = _n >= _max;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (atCap)
            Container(
              key: const ValueKey('passengers-cap-note'),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: t.colorScheme.errorContainer, borderRadius: BorderRadius.circular(12)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.info_outline, size: 18, color: t.colorScheme.onErrorContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onErrorContainer),
                      children: [
                        const TextSpan(text: "We can't fit more than this in a car! Book 2 cars instead. "),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: InkWell(
                            key: const ValueKey('passengers-cap-learn-more'),
                            onTap: () => showGroupGuidelinesSheet(context, maxSeats: _max),
                            child: Text('Learn more',
                                style: t.textTheme.bodySmall?.copyWith(
                                  color: t.colorScheme.onErrorContainer,
                                  fontWeight: FontWeight.w700,
                                  decoration: TextDecoration.underline,
                                )),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ]),
            ),
          Text("What's your group size?", style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text("Let's find you a ride that fits. ", style: t.textTheme.bodyMedium?.copyWith(color: muted)),
            InkWell(
              key: const ValueKey('passengers-guidelines'),
              onTap: () => showGroupGuidelinesSheet(context, maxSeats: _max),
              child: Text('See guidelines',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.primary, fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 18),
          Row(children: [
            Icon(Icons.person_outline, color: muted),
            const SizedBox(width: 12),
            Expanded(child: Text('Passengers', style: t.textTheme.titleMedium)),
            IconButton.outlined(
              key: const ValueKey('passengers-down'),
              tooltip: 'Fewer',
              onPressed: _n > 1 ? () => setState(() => _n -= 1) : null,
              icon: const Icon(Icons.remove, size: 20),
            ),
            SizedBox(
              width: 36,
              child: Text('$_n',
                  key: const ValueKey('passengers-count'), textAlign: TextAlign.center, style: t.textTheme.titleLarge),
            ),
            IconButton.outlined(
              key: const ValueKey('passengers-up'),
              tooltip: 'More',
              onPressed: _n < _max ? () => setState(() => _n += 1) : null,
              icon: const Icon(Icons.add, size: 20),
            ),
          ]),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                key: const ValueKey('passengers-reset'),
                onPressed: () => setState(() => _n = 1),
                child: const Text('Reset'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                key: const ValueKey('passengers-confirm'),
                onPressed: () => Navigator.of(context).pop(_n),
                child: const Text('Confirm'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// The group-size guidelines (reached from the Passengers picker and its cap
/// note): how many a car seats and what to do with a bigger group. Read-only.
Future<void> showGroupGuidelinesSheet(BuildContext context, {required int maxSeats}) =>
    showAppSheet<void>(
      id: 'ride.group-guidelines',
      context: context,
      fitContent: true,
      builder: (context) => _GroupGuidelinesSheet(maxSeats: maxSeats),
    );

class _GroupGuidelinesSheet extends StatelessWidget {
  const _GroupGuidelinesSheet({required this.maxSeats});
  final int maxSeats;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    Widget point(String s) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.check_circle_outline, size: 18, color: t.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(s, style: t.textTheme.bodyMedium)),
          ]),
        );
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Group size guidelines', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('Pick a ride that fits everyone in your group — safely and comfortably.',
              style: t.textTheme.bodyMedium?.copyWith(color: muted)),
          const SizedBox(height: 10),
          point('Count everyone riding — adults, children and infants each take a seat.'),
          point('Every passenger must wear a seatbelt; a car can only carry as many people as it has seats '
              '(up to $maxSeats here).'),
          point('Large luggage takes up space — a bigger car may be more comfortable.'),
          point('Bigger group? Book two cars so everyone rides safely.'),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('group-guidelines-done'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ]),
      ),
    );
  }
}
