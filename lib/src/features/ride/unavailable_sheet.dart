import 'package:flutter/material.dart';

import '../../core/ride_bidding.dart';
import 'castaway_illustration.dart';

/// Which point of a trip GET.ride can't serve.
enum UnavailableAt { pickup, stop, drop }

/// The words for a trip GET.ride can't serve (Bolt's "currently
/// unavailable"): the message and the button's label. Pure.
({String message, String action}) unavailableCopy(UnavailableAt at, CoverageGap gap, {String? region}) {
  final place = switch (at) {
    UnavailableAt.pickup => 'pickup',
    UnavailableAt.stop => 'stop',
    UnavailableAt.drop => 'destination',
  };
  final why = switch (gap) {
    CoverageGap.blocked when region != null => 'GET.ride is paused in $region right now.',
    CoverageGap.blocked => 'GET.ride is paused there right now.',
    CoverageGap.outside when region != null => "GET.ride doesn't run in that part of $region yet.",
    CoverageGap.outside => at == UnavailableAt.pickup ? "We don't pick up there yet." : "We don't go there yet.",
  };
  final next = at == UnavailableAt.stop ? 'Try removing or changing the stop.' : 'Try changing your $place.';
  return (
    message: '$why $next',
    action: switch (at) {
      UnavailableAt.pickup => 'Change pickup',
      UnavailableAt.stop => 'Remove stop',
      UnavailableAt.drop => 'Change destination',
    },
  );
}

/// Slides up from the bottom when the pickup, a stop or the destination is
/// outside every region the admin has set up, or in one they have blocked.
/// [onChange] is the button: change the pickup or destination, or drop the
/// stop.
Future<void> showServiceUnavailable(
  BuildContext context, {
  required UnavailableAt at,
  required CoverageGap gap,
  String? region,
  required VoidCallback onChange,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: false,
  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
  builder: (c) => ServiceUnavailableSheet(
    at: at,
    gap: gap,
    region: region,
    onChange: () {
      Navigator.pop(c);
      onChange();
    },
  ),
);

class ServiceUnavailableSheet extends StatelessWidget {
  const ServiceUnavailableSheet({super.key, required this.at, required this.gap, this.region, required this.onChange});

  final UnavailableAt at;
  final CoverageGap gap;
  final String? region;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final copy = unavailableCopy(at, gap, region: region);
    return Padding(
      key: const ValueKey('service-unavailable'),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton.filledTonal(
              key: const ValueKey('service-unavailable-close'),
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          const Center(child: CastawayIllustration()),
          const SizedBox(height: 28),
          Text(
            'Unfortunately, GET.ride is currently unavailable',
            textAlign: TextAlign.center,
            style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          Text(
            copy.message,
            key: const ValueKey('service-unavailable-message'),
            textAlign: TextAlign.center,
            style: t.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
          FilledButton(
            key: const ValueKey('service-unavailable-change'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              shape: const StadiumBorder(),
              textStyle: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            onPressed: onChange,
            child: Text(copy.action),
          ),
        ],
      ),
    );
  }
}
