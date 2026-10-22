// Admin → Display Settings → Trip card: the trip's progress on the lock
// screen (core/trip_card.dart), on or off per service and for drivers, and
// how long the done card stays. Kept in the display settings blob under
// `tripCard`; its colours are App Page Settings' "Trip card · Preview".
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/trip_card.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/trip_card_preview.dart';

class TripCardSettingsCard extends StatelessWidget {
  const TripCardSettingsCard({super.key, required this.value, required this.onChanged});

  final TripCardSettings value;

  /// Saves a change; null when the admin may only look.
  final FutureOr<void> Function(TripCardSettings)? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final v = value;
    final save = onChanged;
    Widget toggle(String key, String title, String subtitle, bool on, TripCardSettings Function(bool) next) =>
        BusySwitchListTile(
          key: ValueKey('trip-card-$key'),
          title: Text(title),
          subtitle: Text(subtitle),
          value: on,
          onChanged: save == null ? null : (x) => save(next(x)),
        );
    final done = v.doneMinutes;
    return Card(
      key: const ValueKey('trip-card-settings'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              "While a trip is on, the rider sees how it's going without opening the app: on an iPhone's lock "
              'screen and Dynamic Island, and as a pinned notification with a progress bar on Android. It shows '
              'the driver, their car and plate while they come, the arrival time on the trip, and Call, Chat, '
              'Share trip and SOS buttons. A courier delivery code is never on it.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
          toggle('ride', 'Ride', 'Rides booked from the home screen', v.ride, (x) => v.copyWith(ride: x)),
          toggle('courier', 'Courier', 'Parcels: "picks up in", "Delivers at"', v.courier, (x) => v.copyWith(courier: x)),
          toggle('freight', 'Freight', 'Vans and lorries: "loads in", "Arrives at"', v.freight, (x) => v.copyWith(freight: x)),
          toggle(
            'driver',
            'Driver card',
            "The driver's own card: the next pickup with the rider's first name, then the drop-off time. "
                'For the services switched on above.',
            v.driver,
            (x) => v.copyWith(driver: x),
          ),
          const Divider(height: 1),
          ListTile(
            key: const ValueKey('trip-card-done'),
            title: const Text('Done card stays'),
            subtitle: Text(
              done == 0
                  ? 'The card clears as soon as the trip ends.'
                  : 'After the trip ends the card shows "How was your ride?" for this long, then clears. 0 clears it at once.',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                BusyIconButton(
                  tooltip: 'Fewer minutes',
                  icon: const Icon(Icons.remove),
                  onPressed: save == null || done <= 0 ? null : () => save(v.copyWith(doneMinutes: done - 1)),
                ),
                SizedBox(
                  width: 64,
                  child: Text(
                    '$done min',
                    key: const ValueKey('trip-card-done-value'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                BusyIconButton(
                  tooltip: 'More minutes',
                  icon: const Icon(Icons.add),
                  onPressed: save == null || done >= TripCardSettings.maxDoneMinutes
                      ? null
                      : () => save(v.copyWith(doneMinutes: done + 1)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            key: const ValueKey('trip-card-preview'),
            leading: const Icon(Icons.phone_iphone),
            title: const Text('Preview'),
            subtitle: const Text('Colours: App Page Settings, "Trip card · Preview"'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => unawaited(showTripCardPreview(context)),
          ),
        ],
      ),
    );
  }
}
