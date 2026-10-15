// The passenger's location sharing on their trip map: a round button over
// map type and recenter while the driver is on the way, filled when the
// driver can see where they are waiting. Tapping it explains the sharing;
// turning it off asks whether for this ride only or for all rides (Settings
// → Show location to your driver).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../providers.dart';
import 'confirm_parts.dart' show confirmAccent;

/// What the passenger chose on the first sheet.
enum LocationShareChoice { keep, turnOff }

/// What turning it off applies to.
enum LocationOffScope { thisRide, allRides }

class LocationShareButton extends ConsumerWidget {
  const LocationShareButton({super.key, required this.ride});

  final RideRequest ride;

  /// Only while the driver is on the way to the passenger.
  static bool showsFor(RideRequest r) =>
      (r.status == RideStatus.accepted || r.status == RideStatus.arrived) && !r.id.startsWith('demo');

  Future<void> _tap(BuildContext context, WidgetRef ref, bool on) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    void say(String text) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text(text)));
    }

    final choice = await showLocationShareSheet(context, on: on);
    if (choice == null || !context.mounted) return;
    if (choice == LocationShareChoice.keep) {
      if (on) return;
      if (!ref.read(showLocationToDriverProvider)) await ref.read(showLocationToDriverProvider.notifier).set(true);
      await ref.read(rideLocationOffProvider.notifier).turnOn(ride.id);
      say('Your driver can see your location now.');
      return;
    }
    if (!on) return;
    final scope = await showLocationOffScopeSheet(context);
    if (scope == null || !context.mounted) return;
    if (scope == LocationOffScope.thisRide) {
      await ref.read(rideLocationOffProvider.notifier).turnOff(ride.id);
      say('Your driver can no longer see your location on this ride.');
    } else {
      await ref.read(showLocationToDriverProvider.notifier).set(false);
      say('Drivers can no longer see your location on any ride. Turn it back on here or in Settings.');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!showsFor(ride)) return const SizedBox.shrink();
    final on = locationSharedFor(ref, ride.id, watch: true);
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        toggled: on,
        label: on ? 'Location shared with your driver' : 'Location not shared with your driver',
        child: Container(
          key: ValueKey(on ? 'location-share-on' : 'location-share-off'),
          // The ring round it while the driver can see the passenger.
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: on ? Border.all(color: confirmAccent.withValues(alpha: 0.45), width: 2) : null,
          ),
          child: Material(
            color: on ? confirmAccent : t.colorScheme.surface,
            shape: const CircleBorder(),
            elevation: 3,
            child: InkWell(
              key: const ValueKey('location-share-button'),
              customBorder: const CircleBorder(),
              onTap: () => _tap(context, ref, on),
              child: SizedBox.square(
                dimension: 44,
                child: Icon(
                  on ? Icons.share_location : Icons.location_disabled_outlined,
                  color: on ? Colors.white : t.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Smoother pickups with location sharing": keep (or start) sharing, or
/// turn it off. Null when closed.
Future<LocationShareChoice?> showLocationShareSheet(BuildContext context, {required bool on}) =>
    showModalBottomSheet<LocationShareChoice>(
      context: context,
      isScrollControlled: true,
      builder: (c) {
        final t = Theme.of(c);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              key: const ValueKey('location-share-sheet'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 112,
                    height: 112,
                    decoration: BoxDecoration(color: confirmAccent.withValues(alpha: 0.14), shape: BoxShape.circle),
                    child: const Icon(Icons.share_location, size: 56, color: confirmAccent),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Smoother pickups with location sharing',
                  style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your driver can see where you are waiting until the ride starts, while GET.ride is open.',
                  style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('location-share-learn'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      foregroundColor: t.brightness == Brightness.dark
                          ? Colors.lightBlueAccent
                          : const Color(0xFF1B7FAD),
                    ),
                    onPressed: () {
                      Navigator.pop(c);
                      GoRouter.maybeOf(context)?.push('/account/settings/show-location');
                    },
                    child: const Text('Learn more'),
                  ),
                ),
                const SizedBox(height: 12),
                _SheetButton(
                  key: const ValueKey('location-share-keep'),
                  label: on ? 'Keep sharing' : 'Share my location',
                  primary: true,
                  onPressed: () => Navigator.pop(c, LocationShareChoice.keep),
                ),
                const SizedBox(height: 10),
                _SheetButton(
                  key: const ValueKey('location-share-turn-off'),
                  label: on ? 'Turn off' : 'Not now',
                  onPressed: () => Navigator.pop(c, on ? LocationShareChoice.turnOff : null),
                ),
              ],
            ),
          ),
        );
      },
    );

/// "Turn off location sharing for this ride only?": this ride, or every
/// ride (the setting). Null when closed.
Future<LocationOffScope?> showLocationOffScopeSheet(BuildContext context) => showModalBottomSheet<LocationOffScope>(
  context: context,
  builder: (c) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        key: const ValueKey('location-off-scope-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Turn off location sharing for this ride only?',
            style: Theme.of(c).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 20),
          _SheetButton(
            key: const ValueKey('location-off-this-ride'),
            label: 'Only this ride',
            primary: true,
            onPressed: () => Navigator.pop(c, LocationOffScope.thisRide),
          ),
          const SizedBox(height: 10),
          _SheetButton(
            key: const ValueKey('location-off-all-rides'),
            label: 'All rides',
            onPressed: () => Navigator.pop(c, LocationOffScope.allRides),
          ),
        ],
      ),
    ),
  ),
);

class _SheetButton extends StatelessWidget {
  const _SheetButton({super.key, required this.label, required this.onPressed, this.primary = false});

  final String label;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(28));
    const text = TextStyle(fontSize: 17, fontWeight: FontWeight.w600);
    return SizedBox(
      height: 54,
      child: primary
          ? FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: confirmAccent,
                foregroundColor: Colors.white,
                shape: shape,
                textStyle: text,
              ),
              onPressed: onPressed,
              child: Text(label),
            )
          : FilledButton.tonal(
              style: FilledButton.styleFrom(
                backgroundColor: confirmAccent.withValues(alpha: t.brightness == Brightness.dark ? 0.22 : 0.10),
                foregroundColor: t.colorScheme.onSurface,
                shape: shape,
                textStyle: text,
              ),
              onPressed: onPressed,
              child: Text(label),
            ),
    );
  }
}
