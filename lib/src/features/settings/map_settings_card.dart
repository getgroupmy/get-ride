// Settings › Map (rider live map, migration 0322): whether the free cars
// near the rider show on the home map (where the region shows them and lets
// riders hide them), and whether the map overlays stay on as they were left.
// Kept on the phone for each signed-in user.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/rider_live_map_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart' show mutedTextColor;

/// The owner's words under the cars switch.
const showCarsHint = 'Your region shows free cars around you. Turn off to hide them.';
const rememberOverlaysHint = 'Busy areas, My people and Team stay on as you left them.';

class MapSettingsCard extends ConsumerWidget {
  const MapSettingsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final prefs = ref.watch(liveMapPrefsProvider);
    final notifier = ref.read(liveMapPrefsProvider.notifier);
    return Card(
      key: const ValueKey('settings-map'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Map', style: t.textTheme.titleSmall?.copyWith(color: mutedTextColor(t))),
          BusySwitchListTile(
            key: const ValueKey('settings-show-cars'),
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.directions_car_outlined),
            title: const Text('Show cars near me on the map'),
            subtitle: const Text(showCarsHint),
            value: !prefs.hideCars,
            onChanged: (v) => notifier.setHideCars(!v),
          ),
          BusySwitchListTile(
            key: const ValueKey('settings-remember-overlays'),
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.hive_outlined),
            title: const Text('Map overlays remember my last choice'),
            subtitle: const Text(rememberOverlaysHint),
            value: prefs.remember,
            onChanged: notifier.setRemember,
          ),
        ]),
      ),
    );
  }
}
