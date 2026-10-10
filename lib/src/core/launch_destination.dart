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

/// The partner console (the Drive tab), for a partner on a tablet: a tablet
/// in a car is a driver's console, not a phone to book rides from (Expo
/// lands tablets on `/partner-teksi`).
class LaunchPartnerConsole extends LaunchTarget {
  const LaunchPartnerConsole();
}

/// A tablet, as Expo's `useResponsive` decides it: the shortest side at
/// least 600 logical pixels on a device, 768 in a browser.
bool isTabletSize(double width, double height, {required bool web}) {
  final shortest = width < height ? width : height;
  return shortest >= (web ? 768 : 600);
}

/// The priority: a rider's ride in progress (it stays home, where the
/// ongoing-ride card is), then a driver's trip in progress, then the meter
/// auto-launch, then the partner console on a partner's tablet, then home.
/// A hire someone is in the middle of always outranks the screen they would
/// start the next one from.
LaunchTarget resolveLaunchTarget({
  required bool riderRideInProgress,
  String? partnerTripId,
  required bool meterAutoLaunch,
  bool partnerTablet = false,
}) {
  if (riderRideInProgress) return const LaunchHome();
  if (partnerTripId != null && partnerTripId.isNotEmpty) return LaunchPartnerTrip(partnerTripId);
  if (meterAutoLaunch) return const LaunchMeter();
  if (partnerTablet) return const LaunchPartnerConsole();
  return const LaunchHome();
}
