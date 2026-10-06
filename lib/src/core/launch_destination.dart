// Where a launch lands (Expo `utils/launchDestination.ts`): the one rule
// for every sign-in and relaunch, in priority order. Pure.

/// Where this launch goes, beyond the home screen it starts on.
sealed class LaunchTarget {
  const LaunchTarget();
}

/// Stay on home (a rider's ride in progress shows there as a card).
class LaunchHome extends LaunchTarget {
  const LaunchHome();
}

/// Back into the trip a driver was in the middle of.
class LaunchPartnerTrip extends LaunchTarget {
  const LaunchPartnerTrip(this.requestId);
  final String requestId;
}

/// Meter Digital, for a TEKSI driver whose rate card asks for it.
class LaunchMeter extends LaunchTarget {
  const LaunchMeter();
}

/// The priority: a rider's ride in progress (it stays home, where the
/// ongoing-ride card is), then a driver's trip in progress, then the meter
/// auto-launch, then home. A hire someone is in the middle of always
/// outranks the screen they would start the next one from.
LaunchTarget resolveLaunchTarget({
  required bool riderRideInProgress,
  String? partnerTripId,
  required bool meterAutoLaunch,
}) {
  if (riderRideInProgress) return const LaunchHome();
  if (partnerTripId != null && partnerTripId.isNotEmpty) return LaunchPartnerTrip(partnerTripId);
  if (meterAutoLaunch) return const LaunchMeter();
  return const LaunchHome();
}
