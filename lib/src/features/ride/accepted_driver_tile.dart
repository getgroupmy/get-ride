import 'package:flutter/material.dart';

import '../../core/ride_bidding.dart' show driverTripsLabel;
import '../../data/models.dart';
import '../../widgets/net_image.dart';

/// The rider's card for the driver who took the ride: photo, name, car and
/// plate, and on the right the rating with the driver's completed trips
/// under it ("★ 4.9" over "312 trips", or "New driver").
class AcceptedDriverTile extends StatelessWidget {
  const AcceptedDriverTile({super.key, required this.ride});
  final RideRequest ride;

  @override
  Widget build(BuildContext context) {
    final r = ride;
    final t = Theme.of(context);
    final trips = driverTripsLabel(r.partnerTrips, locale: Localizations.maybeLocaleOf(context)?.toString());
    final rating = r.partnerRating;
    return ListTile(
      leading: NetAvatar(
        key: const ValueKey('driver-photo'),
        url: r.partnerPhoto,
        fallback: const Icon(Icons.person),
      ),
      title: Text(r.partnerName ?? 'Your driver'),
      subtitle: Text([r.partnerVehicle, r.partnerPlate].whereType<String>().join(' · ')),
      trailing: rating == null && trips == null
          ? null
          : Column(
              key: const ValueKey('driver-rating'),
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (rating != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star, size: 18, color: Colors.amber),
                      Text(rating.toStringAsFixed(1)),
                    ],
                  ),
                if (trips != null)
                  Text(
                    trips,
                    key: const ValueKey('driver-trips'),
                    maxLines: 1,
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
    );
  }
}
