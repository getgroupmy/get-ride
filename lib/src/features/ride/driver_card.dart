import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/driver_eta.dart';
import '../../core/permits.dart' show PlateColours;
import '../../core/ride_bidding.dart' show driverTripsLabel;
import '../../data/models.dart';
import '../../widgets/net_image.dart';
import 'ride_tracking_screen.dart' show rideStreamProvider;

// The ride screen's driver, read the way a rider looks for their car at
// the kerb: the plate first, the car under it, then who is driving; and
// the screen's title with the minutes until the driver gets there.

/// The status over the ride's sheet. On the way to the pickup it carries
/// the minutes left ("Driver on the way · 4 min"), following the driver's
/// live position on its own: the sheet itself is not rebuilt for a move.
class RideStatusTitle extends ConsumerWidget {
  const RideStatusTitle({super.key, required this.ride});
  final RideRequest ride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = ride.status.label;
    final minutes = ride.status == RideStatus.accepted
        ? ref.watch(
            rideStreamProvider(ride.id).select((v) {
              final r = v.value ?? ride;
              return approachMinutes(
                driverLat: r.partnerLiveLat ?? r.partnerAcceptLat,
                driverLng: r.partnerLiveLng ?? r.partnerAcceptLng,
                pickupLat: r.pickupLat,
                pickupLng: r.pickupLng,
              );
            }),
          )
        : null;
    return Semantics(
      header: true,
      liveRegion: true,
      child: Text(
        withEta(label, minutes),
        key: const ValueKey('ride-status-title'),
        style: Theme.of(context).textTheme.headlineSmall,
      ),
    );
  }
}

/// The plate in a box of its own, as it looks on the car.
class PlateBox extends StatelessWidget {
  const PlateBox({super.key, required this.plate, this.colours});
  final String plate;

  /// The country's colours for this vehicle (core/permits.dart): a taxi's
  /// white plate, an EV's green; null keeps the card's own colours.
  final PlateColours? colours;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ink = colours?.fg ?? t.colorScheme.onSurface;
    return Semantics(
      label: 'Number plate $plate',
      excludeSemantics: true,
      child: Container(
        key: const ValueKey('driver-plate'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: colours?.bg ?? t.colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: colours == null ? Border.all(color: ink, width: 2) : Border.all(color: const Color(0xFF888888)),
        ),
        // A long plate at large text on a small phone shrinks to fit
        // rather than running off the card.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            plate.toUpperCase(),
            maxLines: 1,
            style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 1.2, color: ink),
          ),
        ),
      ),
    );
  }
}

/// The top of the driver's card: plate, car (model and colour as the
/// driver registered them), then name, rating and photo.
class DriverCardHeader extends StatelessWidget {
  const DriverCardHeader({super.key, required this.ride});
  final RideRequest ride;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final plate = ride.partnerPlate?.trim();
    final vehicle = ride.partnerVehicle?.trim();
    final rating = ride.partnerRating;
    final trips = driverTripsLabel(ride.partnerTrips, locale: Localizations.maybeLocaleOf(context)?.toString());
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (plate != null && plate.isNotEmpty) PlateBox(plate: plate, colours: ride.partnerPlateColours),
                if (vehicle != null && vehicle.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    vehicle,
                    key: const ValueKey('driver-vehicle'),
                    style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Text(
                      ride.partnerName ?? 'Your driver',
                      key: const ValueKey('driver-name'),
                      style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (rating != null)
                      Semantics(
                        label: 'Rated ${rating.toStringAsFixed(1)} out of 5',
                        excludeSemantics: true,
                        child: Row(
                          key: const ValueKey('driver-rating'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star, size: 18, color: Colors.amber),
                            const SizedBox(width: 2),
                            Text(rating.toStringAsFixed(1), style: t.textTheme.bodyMedium),
                          ],
                        ),
                      ),
                    // The driver's completed trips beside the rating ("312 trips", "New driver").
                    if (trips != null)
                      Text(
                        trips,
                        key: const ValueKey('driver-trips'),
                        maxLines: 1,
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          NetAvatar(
            key: const ValueKey('driver-photo'),
            url: ride.partnerPhoto,
            radius: 28,
            fallback: const Icon(Icons.person, size: 28),
          ),
        ],
      ),
    );
  }
}
