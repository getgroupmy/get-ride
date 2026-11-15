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
