// Admin → Settings → Mock / Simulation (Expo `admin-settings-mock`): the four
// demo / simulation switches in the global display settings blob.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'display_logic.dart';
import 'display_screen.dart' show applyDisplay;
import 'display_store.dart';

const mockPage = 'admin-settings-mock';

const _sections = [
  (
    'Passenger (User) side',
    [
      (
        'userMockEnabled',
        'Mock driver offers & viewers',
        'Demo driver bids, available drivers and “viewing” avatars shown while searching for a ride',
        'Ride Confirm',
        Icons.groups_outlined,
      ),
      (
        'riderTripSimEnabled',
        'Simulated driver movement',
        'Animated car on the map plus automatic phase changes (arriving → arrived → on trip → completed). When off, '
            "the car follows the partner's real live GPS position and the real ride status",
        'Ride Tracking',
        Icons.route_outlined,
      ),
    ],
  ),
  (
    'Partner (Driver) side',
    [
      (
        'partnerMockEnabled',
        'Mock incoming ride requests',
        'Auto-generated demo ride requests that pop up while the partner is online. When off, only real passenger '
            'requests appear',
        'Partner eHailing',
        Icons.radar,
      ),
      (
        'partnerDriveSimEnabled',
        'Simulated driving & auto-arrival',
        'Animated car along the route and automatic arrival at pickup/destination. When off, the car follows the '
            "device's real GPS (shared live with the passenger) and the partner advances the trip manually",
        'Ride Running',
        Icons.directions_car_outlined,
      ),
    ],
  ),
];

class AdminMockSettingsScreen extends ConsumerWidget {
  const AdminMockSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(mockPage)) == AccessLevel.edit;
    return AdminPage(
      title: 'Mock / Simulation',
      page: mockPage,
      body: AsyncView(
        value: ref.watch(displaySettingsProvider),
        onRetry: () => ref.invalidate(displaySettingsProvider),
        data: (s) {
          final any = anyMockEnabled(s);
          return ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
            ResponsiveCenter(
              maxWidth: 760,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Card(
                  child: SwitchListTile(
                    secondary: Icon(Icons.power_settings_new, color: any ? Colors.orange : Colors.green),
                    title: const Text('All mocks & simulations'),
                    subtitle: const Text('Master switch — flips every toggle below at once'),
                    value: any,
                    onChanged: canEdit ? (v) => applyDisplay(context, ref, (x) => setAllMocks(x, v)) : null,
                  ),
                ),
                for (final (title, items) in _sections) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
                    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
                  ),
                  Card(
                    child: Column(children: [
                      for (final (key, label, desc, screen, icon) in items)
                        SwitchListTile(
                          secondary: Icon(icon),
                          title: Text(label),
                          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(desc),
                            const SizedBox(height: 4),
                            Chip(label: Text(screen), visualDensity: VisualDensity.compact),
                          ]),
                          value: displayBool(s, key),
                          onChanged: canEdit
                              ? (v) => applyDisplay(context, ref, (x) => setDisplayValue(x, key, v))
                              : null,
                        ),
                    ]),
                  ),
                ],
                const SizedBox(height: 16),
                const Text('These switches apply globally to every device within a few seconds. Rides already in '
                    'progress pick up the change on their next screen open.'),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}
