// A driver's admin page: the ride extras they turned off (Settings → Ride
// extras I take, migration 0253). Read only: the driver chooses them.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ride_extras.dart';
import '../../../data/driver_extras_repository.dart';
import '../../../data/ride_option_providers.dart';
import '../../../data/ride_pet_repository.dart' show petConfigProvider;
import '../../../widgets/common.dart';

class DriverExtrasOffCard extends ConsumerWidget {
  const DriverExtrasOffCard({super.key, required this.driverId});

  /// The driver's account id.
  final String driverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t, background: cardSurfaceColor(t));
    final off = ref.watch(driverExtrasOffProvider(driverId));
    final names = describeExtrasOff(
      off.value ?? const {},
      ref.watch(rideOptionsConfigProvider),
      ref.watch(petConfigProvider),
      ref.watch(assistanceCatalogueProvider),
    );
    return Card(
      key: const ValueKey('driver-extras-off'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Ride extras turned off', style: t.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Requests with these are not offered to this driver. The driver changes them in Settings > Ride extras I take.',
            style: t.textTheme.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 8),
          if (off.isLoading && !off.hasValue)
            const LinearProgressIndicator()
          else if (names.isEmpty)
            Text('None: takes every extra', key: const ValueKey('driver-extras-off-none'))
          else
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final n in names) Chip(key: ValueKey('driver-extra-off-$n'), label: Text(n)),
            ]),
        ]),
      ),
    );
  }
}
