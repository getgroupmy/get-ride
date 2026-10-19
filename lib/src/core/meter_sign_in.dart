// Meter on or off at sign-in (`meter_at_sign_in`, migration 0243).
//
// The rate card's "Meter at sign-in" says what happens right after a TEKSI
// driver signs in: `off` leaves the launch to `auto_launch` alone, `ask`
// asks the driver, `always` turns the meter on. The driver's answer holds for
// that sign-in (kept on the device, cleared on sign-out), and the driver can
// switch it from the meter or the driver menu. Pure: the launch applies it.

import '../admin/screens/meterapp/meter_logic.dart';
import 'meter_auto_launch.dart';
import 'taxi_meter.dart';

/// What this launch does about the meter, before the ride-in-progress and
/// tablet rules (`resolveLaunchTarget`) are applied.
enum MeterSignInAction {
  /// The launch rules decide as they always did (`auto_launch`).
  autoLaunch,

  /// Ask the driver "Turn the meter on" or "Not now".
  ask,

  /// Turn the meter on for this sign-in and open it.
  meterOn,

  /// The driver turned it off for this sign-in: the meter does not open.
  stayOff,
}

/// The card's choice, read safely: anything unknown is `off`.
String meterAtSignInMode(String? mode) => meterAtSignInModes.contains(mode) ? mode! : 'off';

/// The "Meter at sign-in" choice that applies to this driver: `off` for an
/// account that is not a TEKSI partner cleared to drive, else the choice on
/// the card for [geo] (else the global card).
String resolveMeterAtSignIn({
  required List<MeterProfile> profiles,
  required Object? partnerTypes,
  required bool canDrive,
  MeterGeo? geo,
}) {
  if (!canDrive || !hasTeksiPartnerType(partnerTypes)) return 'off';
  final card = resolveMeterProfile(
    profiles,
    country: geo?.country,
    state: geo?.state,
    city: geo?.city,
    suburb: geo?.suburb,
  );
  return meterAtSignInMode(card.profile.meterAtSignIn);
}

/// What this launch does, from the card's [mode] and the driver's [choice]
/// for this sign-in (null: none yet, so this is the first launch after
/// signing in).
///
/// * `off`: [MeterSignInAction.autoLaunch], whatever was chosen before.
/// * Turned off for this sign-in: [MeterSignInAction.stayOff], so a reopen
///   does not bring the meter back.
/// * Turned on: the launch rules apply for the rest of the sign-in.
/// * Nothing chosen yet: `ask` asks, `always` turns it on.
MeterSignInAction resolveMeterSignIn({required String mode, required bool? choice}) {
  final m = meterAtSignInMode(mode);
  if (m == 'off') return MeterSignInAction.autoLaunch;
  if (choice == false) return MeterSignInAction.stayOff;
  if (choice == true) return MeterSignInAction.autoLaunch;
  return m == 'ask' ? MeterSignInAction.ask : MeterSignInAction.meterOn;
}

/// Whether the driver gets a "Meter on/off" switch (in the meter and the
/// driver menu): only where the card makes the meter a per-sign-in choice.
bool showMeterSessionToggle(String mode) => meterAtSignInMode(mode) != 'off';
