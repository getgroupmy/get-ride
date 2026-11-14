/// How the app's windows may rotate.
///
/// A large screen — a tablet, or a foldable's unfolded inner display — rotates
/// freely; a small screen — a regular phone, or a foldable's folded cover —
/// stays portrait. The one exception is the taxi meter, which forces its own
/// landscape and restores the default on the way out.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show DeviceOrientation, SystemChrome;
import 'package:flutter/widgets.dart' show ValueNotifier, WidgetsBinding;

import 'duo_fold.dart' show DuoHinge, duoHingeNow;
import 'launch_destination.dart' show isTabletSize;

/// Set while a screen (the meter) is holding its own orientation, so the app
/// default is not re-applied over it on a metrics change. The meter sets it on
/// lock and clears it on release.
final meterHoldsOrientation = ValueNotifier<bool>(false);

/// The orientations allowed on a window this size and fold pose.
///
/// A large screen rotates freely, a small screen is portrait only — split on
/// the app's existing tablet line ([isTabletSize]: shortest side >= 600 on a
/// device, >= 768 on web). On the iPhone Duo that line falls between the folded
/// cover (shortest side 466 -> portrait) and the unfolded inner display
/// (shortest side 669 -> rotates), and an Android fold/flip lands the same way.
/// The shortest side is rotation-invariant, so on a device whose window is
/// sized honestly folding or unfolding flips the rule on its own.
///
/// [hinge] overrides the size rule when the iPhone Duo bridge reports a pose,
/// because size alone deadlocks there: an app that opens on the folded cover
/// pins itself portrait, and a portrait pin can stop iOS ever handing the
/// window the unfolded inner display's larger size — so a size-only rule could
/// never unlock rotation after unfolding. The hinge pose is reported promptly
/// (unlike the laggy window geometry), so it is authoritative: the inner
/// display (partially or fully open) always rotates, the folded cover stays
/// portrait, and an unknown/absent hinge (every non-Duo device, where the
/// window size is honest) falls back to the size rule. Pure.
List<DeviceOrientation> appDefaultOrientations(
  double width,
  double height, {
  required bool web,
  DuoHinge hinge = DuoHinge.none,
}) {
  switch (hinge) {
    case DuoHinge.closed:
      return const [DeviceOrientation.portraitUp];
    case DuoHinge.partiallyOpen:
    case DuoHinge.fullyOpen:
      return DeviceOrientation.values;
    case DuoHinge.none:
    case DuoHinge.unknown:
      return isTabletSize(width, height, web: web)
          ? DeviceOrientation.values
          : const [DeviceOrientation.portraitUp];
  }
}

/// Pins the device to [appDefaultOrientations] for the window and fold pose it
/// is in now — unless the meter is holding landscape. Called at startup,
/// whenever the window changes shape (a fold/unfold), whenever the Duo hinge
/// pose changes, and when the meter hands rotation back. A no-op before a view
/// exists (a test, a headless start).
Future<void> applyAppDefaultOrientation() {
  if (meterHoldsOrientation.value) return Future<void>.value();
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  if (view == null) return Future<void>.value();
  final size = view.physicalSize / view.devicePixelRatio;
  if (size.isEmpty) return Future<void>.value();
  return SystemChrome.setPreferredOrientations(
    appDefaultOrientations(size.width, size.height, web: kIsWeb, hinge: duoHingeNow.value),
  );
}
