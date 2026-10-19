// Settings → Show location to your driver: whether the passenger's live
// position goes to the driver on the way to them (core/ride_cancel.dart
// shareRiderLocation), drawn on the driver's map until pickup.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers.dart';
import '../../widgets/page_style_host.dart';

/// When the position is shared, said the same way on the banner and the
/// switch: from the driver accepting until pickup (shareRiderLocation),
/// sent only while the ride is open in GET.ride.
const showLocationWhen = 'from when a driver accepts until pickup, while GET.ride is open';

const showLocationExplanation =
    'Your driver can see where you are waiting $showLocationWhen. '
    'It helps them find you and pick you up sooner.';

/// "How it's shared", point by point, as the code does it: who sees it,
/// when it starts and stops, and what is kept.
const showLocationHowItsShared = <({String title, String body})>[
  (
    title: 'Who sees it',
    body: 'Only the driver who accepted your ride, on their map on the way to you. '
        'Other drivers and passengers never see it.',
  ),
  (
    title: 'When it starts and stops',
    body: 'It starts when a driver accepts and stops at pickup. It is sent only while GET.ride is open; '
        'a position more than a minute old is not shown.',
  ),
  (
    title: 'During the trip',
    body: 'Your location is still used for safety checks (noticing if you and the car are apart), '
        'but the driver does not see it.',
  ),
  (
    title: 'What is kept',
    body: 'The last position sent stays with the ride, as its pickup and drop-off do. '
        'Turning this off before pickup removes it from the ride straight away.',
  ),
];

/// The "How it's shared" explainer.
Future<void> showHowLocationIsShared(BuildContext context) => showAppSheet<void>(
  id: 'show-location.how-its-shared',
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (c) {
    final t = Theme.of(c);
    return SingleChildScrollView(
      key: const ValueKey('show-location-how-sheet'),
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("How it's shared", style: t.textTheme.titleLarge),
          for (final p in showLocationHowItsShared) ...[
            const SizedBox(height: 16),
            Text(p.title, style: t.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(p.body, style: t.textTheme.bodyMedium),
          ],
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Got it')),
          ),
        ],
      ),
    );
  },
);

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
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('show-location-how'),
              icon: const Icon(Icons.info_outline),
              label: const Text("How it's shared"),
              onPressed: () => showHowLocationIsShared(context),
            ),
          ),
          SwitchListTile(
            key: const ValueKey('show-location-switch'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            secondary: const Icon(Icons.share_location_outlined),
            title: const Text('Show location to your driver'),
            subtitle: Text(
              on
                  ? 'Shared $showLocationWhen.'
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
