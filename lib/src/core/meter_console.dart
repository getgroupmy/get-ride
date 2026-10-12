// What the Meter Digital console decides before a hire opens: which car it
// is billing for, who is driving it, and whether START may open a fare now
// (Expo `meterVehicleLaunch`, `meterDriverIdentity`, `evaluateMeterStart`).
// Pure, so the console only gathers the inputs.
import 'vehicle_assignment.dart';

// ---- Which car --------------------------------------------------------------

enum MeterVehicleAction {
  /// A vehicle this driver already holds: the console binds to it silently,
  /// so a shift interrupted by a relaunch resumes in the same car.
  bind,

  /// Nothing held, but there is a car to take: ask. Claiming one takes it
  /// away from every other driver assigned to it, so the meter never picks
  /// for them, not even when there is only one.
  ask,

  /// Nothing to bind and nothing to ask about (no car on the account yet).
  none,

  /// The fleet could not be read (no session, a failed query): "not known"
  /// rather than "no vehicles", so nothing is claimed and nothing is asked.
  unknown,
}

class MeterVehicleLaunch {
  const MeterVehicleLaunch(this.action, {this.vehicle});
  final MeterVehicleAction action;

  /// The car bound to, for [MeterVehicleAction.bind].
  final AssignableVehicle? vehicle;
}

/// The rule the console opens on. A held car that has since been locked is
/// no longer [AssignableVehicle.inUseByMe] (its status says why), so it does
/// not bind and the picker comes up instead.
MeterVehicleLaunch resolveMeterVehicleLaunch(List<AssignableVehicle>? fleet) {
  if (fleet == null) return const MeterVehicleLaunch(MeterVehicleAction.unknown);
  final mine = fleet.where((v) => v.inUseByMe).firstOrNull;
  if (mine != null) return MeterVehicleLaunch(MeterVehicleAction.bind, vehicle: mine);
  if (fleet.any((v) => v.selectable)) return const MeterVehicleLaunch(MeterVehicleAction.ask);
  // Cars that can't be taken yet still get the picker: its rows say why.
  return MeterVehicleLaunch(fleet.isEmpty ? MeterVehicleAction.none : MeterVehicleAction.ask);
}

String? _value(String? v) {
  final t = v?.trim() ?? '';
  return t.isEmpty || t == '—' || t == '-' ? null : t;
}

/// The plate on the console, every record and every receipt: the car the
/// meter is bound to wins over the permit's, which wins over the partner
/// row's (Expo `resolveMeterPlate`).
String? resolveMeterPlate({String? bound, String? permit, String? partner}) =>
    _value(bound) ?? _value(permit) ?? _value(partner);

// ---- Who is driving -----------------------------------------------------------

class MeterDriverIdentity {
  const MeterDriverIdentity({this.name, this.licence, this.photoUrl, this.permitPlate});

  /// Null when nothing says; the console then reads [unknownDriverName].
  final String? name;
  final String? licence;
  final String? photoUrl;

  /// The plate the permit names, beneath the bound car in [resolveMeterPlate].
  final String? permitPlate;
}

const unknownDriverName = 'DRIVER';

/// Each field in priority order: the taxi driver permit, then the account
/// (Expo `resolveMeterDriver`). The permit is read with its placeholders and
/// stock portrait already dropped; the `—` check here is the backstop.
MeterDriverIdentity resolveMeterDriver({
  String? permitName,
  String? permitNumber,
  String? permitPhoto,
  String? permitPlate,
  String? partnerName,
  String? profileName,
  String? partnerPhoto,
  String? profilePhoto,
}) => MeterDriverIdentity(
  name: _value(permitName) ?? _value(partnerName) ?? _value(profileName),
  licence: _value(permitNumber),
  photoUrl: _value(permitPhoto) ?? _value(partnerPhoto) ?? _value(profilePhoto),
  permitPlate: _value(permitPlate),
);

// ---- Whether START opens a fare ----------------------------------------------

/// What a held hire is waiting on, which decides what the popup offers: the
/// reader for the vehicle, location settings for GPS.
enum MeterStartSource { vehicle, gps }

class MeterStartGate {
  const MeterStartGate({
    required this.canStart,
    required this.opensOn,
    required this.title,
    required this.message,
    this.waiting = false,
    this.gpsFallback = false,
  });

  final bool canStart;
  final MeterStartSource opensOn;
  final String title;
  final String message;

  /// The sensor is on its way (a reader linking, a first fix): a held press
  /// opens the hire by itself when it arrives.
  final bool waiting;

  /// The card also bills on GPS, so the driver may open on it rather than
  /// keep a passenger waiting on a reader that will not answer.
  final bool gpsFallback;
}

/// Whether START may open a hire now, and on what (Expo
/// `evaluateMeterStart`). A hire opens on the sensor it will be billed on:
///
/// * a GPS-only card has taken the bus away, so the hire opens on the first
///   fix rather than on a reader that could never release the gate;
/// * a card that allows the bus opens on the vehicle link when a reader is
///   saved on this phone, holding the press while it links. An OBD-only card
///   has nothing else; a card that also bills on GPS offers it as the
///   fallback (and opens on it outright when no reader is saved at all).
///
/// Resuming from a pause is never gated; the console does not ask.
MeterStartGate evaluateMeterStart({
  required bool gpsAllowed,
  required bool obdAllowed,
  required bool obdLinked,
  required bool obdConnecting,
  required bool readerSaved,
  required bool hasFix,
  String? obdError,
  String? locationProblem,
}) {
  final gpsReady = locationProblem == null && hasFix;
  MeterStartGate gps() {
    if (gpsReady) {
      return const MeterStartGate(
        canStart: true,
        opensOn: MeterStartSource.gps,
        title: 'GPS ready',
        message: "The meter measures the hire on the phone's own position.",
      );
    }
    if (locationProblem != null) {
      return MeterStartGate(
        canStart: false,
        opensOn: MeterStartSource.gps,
        title: 'Location is off',
        message: '$locationProblem Allow location access for this app, then start the hire.',
      );
    }
    return const MeterStartGate(
      canStart: false,
      waiting: true,
      opensOn: MeterStartSource.gps,
      title: 'Acquiring GPS…',
      message: 'No position has arrived yet. The hire starts by itself as soon as the phone has a fix.',
    );
  }

  if (!obdAllowed) return gps();
  if (obdLinked) {
    return const MeterStartGate(
      canStart: true,
      opensOn: MeterStartSource.vehicle,
      title: 'Vehicle linked',
      message: "The OBD-II reader is answering. The meter measures the hire on the vehicle's own speed.",
    );
  }
  // A card that also bills on GPS, on a phone with no reader: GPS is what
  // there is, as it was before readers existed.
  if (gpsAllowed && !readerSaved) return gps();

  final fallback = gpsAllowed && gpsReady;
  if (obdConnecting) {
    return MeterStartGate(
      canStart: false,
      waiting: true,
      gpsFallback: fallback,
      opensOn: MeterStartSource.vehicle,
      title: 'Connecting to the vehicle…',
      message: 'Linking the OBD-II reader. The hire starts by itself as soon as the vehicle answers.',
    );
  }
  final err = obdError?.trim() ?? '';
  final reason = !readerSaved
      ? 'No OBD-II reader is saved on this phone'
      : err.isNotEmpty
      ? 'The reader could not be reached: $err'
      : 'No OBD-II reader is connected';
  return MeterStartGate(
    canStart: false,
    gpsFallback: fallback,
    opensOn: MeterStartSource.vehicle,
    title: 'No vehicle link',
    message: gpsAllowed
        ? '$reason. Retry the reader, or start this hire on GPS.'
        : "$reason. This rate card bills on the vehicle's OBD-II reader only: "
              '${readerSaved ? 'retry the reader, or check it in the reader settings' : 'add one in the reader settings'}.',
  );
}
