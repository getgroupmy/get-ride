// The rider's badge on a driver's request card (migration 0269): "New rider"
// under the admin's number of ratings, "Low" below their average.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/rider_rating.dart';
import '../data/city_ride_repository.dart';
import '../data/models.dart';

class RiderBadgeChip extends ConsumerWidget {
  const RiderBadgeChip({super.key, required this.ride, this.compact = false});
  final RideRequest ride;

  /// "New" rather than "New rider", for the narrow column of the request sheet.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(cityRideConfigProvider).value?.riderRating ?? RiderRatingSettings.standard;
    final badge = riderBadge(rating: ride.riderRating, ratings: ride.riderRatingsCount, s: s);
    if (badge == RiderBadge.none) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (fg, bg, label) = switch (badge) {
      RiderBadge.newRider => (
        dark ? const Color(0xFF4CBCFF) : const Color(0xFF0B6E9F),
        dark ? const Color(0xFF163049) : const Color(0xFFDCEFFF),
        compact ? 'New' : 'New rider',
      ),
      _ => (
        dark ? const Color(0xFFFFB648) : const Color(0xFF8A5200),
        dark ? const Color(0xFF33250C) : const Color(0xFFFFF1D6),
        'Low',
      ),
    };
    return Container(
      key: ValueKey('rider-badge-${badge.name}-${ride.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(label, maxLines: 1, style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }
}

/// Whether the card should show the rider's stars: not for a new rider (their
/// few ratings say little), and not on a ride from before the server stamped it.
bool showRiderStars(RideRequest r, RiderRatingSettings s) =>
    r.riderRating != null && riderBadge(rating: r.riderRating, ratings: r.riderRatingsCount, s: s) != RiderBadge.newRider;
