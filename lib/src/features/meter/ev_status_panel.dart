import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ev_profile.dart';
import '../../data/obd/obd_session.dart';
import '../../widgets/busy.dart';

/// An electric car read through its EV profile (Admin → EV profiles): the
/// battery, range, odometer and whatever else the profile reads; the
/// search for a profile; or, when several fit, the driver's choice. Empty
/// for a car on standard OBD-II.
class EvStatusPanel extends ConsumerWidget {
  const EvStatusPanel({super.key, required this.obd});

  final ObdSessionState obd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    if (!obd.linked) return const SizedBox.shrink();
    if (obd.evCandidates.isNotEmpty) {
      return Column(
        key: const ValueKey('ev-choose'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Which car is this?', style: t.textTheme.titleSmall),
          const SizedBox(height: 4),
          const Text('This car answers more than one EV profile. Choose yours: the app remembers it for this reader.'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in obd.evCandidates)
                BusyButton.outlined(
                  key: ValueKey('ev-choose-${p.id ?? p.title}'),
                  onPressed: () => ref.read(obdSessionProvider.notifier).chooseEvProfile(p),
                  child: Text(p.title),
                ),
            ],
          ),
        ],
      );
    }
    if (obd.evSearching) {
      return const Row(
        key: ValueKey('ev-searching'),
        children: [
          SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Expanded(child: Text('Checking whether an EV profile fits this car…')),
        ],
      );
    }
    final profile = obd.evProfile;
    if (profile == null) return const SizedBox.shrink();
    final snap = obd.ev;
    final values = [
      for (final k in evSignalKeys)
        if (snap?.values[k] != null) (k, snap!.values[k]!),
    ];
    final unitFor = {for (final s in profile.signals) s.key: s.unitOrDefault};
    return Column(
      key: const ValueKey('ev-snapshot'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              snap?.charging == true ? Icons.battery_charging_full : Icons.electric_car_outlined,
              size: 18,
              color: t.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(profile.title, style: t.textTheme.titleSmall)),
          ],
        ),
        Text(
          profile.verified
              ? 'Read through its EV profile.'
              : 'Read through its EV profile, which is still being checked: treat the values as a guide.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        if (values.isEmpty)
          const Text('Reading the car…')
        else
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              for (final (k, v) in values)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(evSignalLabels[k] ?? k, style: t.textTheme.labelSmall),
                    Text(
                      formatEvValue(k, v, unit: unitFor[k]),
                      key: ValueKey('ev-value-$k'),
                      style: t.textTheme.titleMedium,
                    ),
                  ],
                ),
            ],
          ),
      ],
    );
  }
}
