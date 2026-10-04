// Whether the app opens on Meter Digital, ported from the Expo app's
// `utils/meterAutoLaunch.ts` and the meter branch of `launchDestination.ts`.
//
// To a taxi driver a meter is not a screen they visit but the screen the
// shift is spent on, so an operator's rate card can make it the landing
// screen (`auto_launch`, migration 0084). The rule is pure; the launch
// decision applies it once per app launch, so leaving the meter for the
// passenger side is never undone.

import '../admin/screens/meterapp/meter_logic.dart';
import 'taxi_meter.dart';

/// The geography the last meter session ran in: the card that decides is
/// the one the meter would bill on there.
typedef MeterGeo = ({String? country, String? state, String? city, String? suburb});

enum MeterAutoLaunchReason {
  /// Not a TEKSI partner, or not cleared to drive: the meter is not theirs.
  notTeksi,

  /// The card for this geography does not ask for it.
  cardOff,

  /// A ride in progress outranks the screen the next hire starts from.
  rideInProgress,
  launch,
}

/// Decides whether this launch opens on the meter. The card is resolved for
/// [geo] (else the global card decides), and an in-progress ride always wins.
({bool launch, MeterAutoLaunchReason reason}) resolveMeterAutoLaunch({
  required List<MeterProfile> profiles,
  required Object? partnerTypes,
  required bool canDrive,
  MeterGeo? geo,
  bool rideInProgress = false,
}) {
  ({bool launch, MeterAutoLaunchReason reason}) no(MeterAutoLaunchReason r) => (launch: false, reason: r);
  if (!canDrive || !hasTeksiPartnerType(partnerTypes)) return no(MeterAutoLaunchReason.notTeksi);
  final card = resolveMeterProfile(
    profiles,
    country: geo?.country,
    state: geo?.state,
    city: geo?.city,
    suburb: geo?.suburb,
  );
  if (!card.profile.autoLaunch) return no(MeterAutoLaunchReason.cardOff);
  if (rideInProgress) return no(MeterAutoLaunchReason.rideInProgress);
  return (launch: true, reason: MeterAutoLaunchReason.launch);
}
