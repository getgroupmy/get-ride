// Settings → Show location to your driver: whether the passenger's live
// position goes to the driver on the way to them (core/ride_cancel.dart
// shareRiderLocation), drawn on the driver's map until pickup.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers.dart';

const showLocationExplanation =
    'Your driver can see where you are waiting until the ride starts, while GET.ride is open. '
    'It helps them find you and pick you up sooner.';

/// The Settings row: on or off, opening the page.
class ShowLocationTile extends ConsumerWidget {
  const ShowLocationTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(showLocationToDriverProvider);
    return Card(
      child: ListTile(
        key: const ValueKey('settings-show-location'),
        leading: const Icon(Icons.share_location_outlined),
        title: const Text('Show location to your driver'),
        subtitle: Text(on ? 'On' : 'Off'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/account/settings/show-location'),
      ),
    );
  }
}

class ShowLocationScreen extends ConsumerWidget {
  const ShowLocationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final on = ref.watch(showLocationToDriverProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Show location')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            key: const ValueKey('show-location-explanation'),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: t.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(showLocationExplanation, style: t.textTheme.bodyLarge),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            key: const ValueKey('show-location-switch'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            secondary: const Icon(Icons.share_location_outlined),
            title: const Text('Show location to your driver'),
            subtitle: Text(
              on
                  ? 'Shared from when a driver accepts until pickup.'
                  : 'Your driver goes to the pickup point only. '
                        'During the trip your location is still used for safety checks, not shown to the driver.',
            ),
            value: on,
            onChanged: (v) => ref.read(showLocationToDriverProvider.notifier).set(v),
          ),
        ],
      ),
    );
  }
}
