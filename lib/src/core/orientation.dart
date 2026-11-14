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

import 'launch_destination.dart' show isTabletSize;

/// Set while a screen (the meter) is holding its own orientation, so the app
/// default is not re-applied over it on a metrics change. The meter sets it on
/// lock and clears it on release.
final meterHoldsOrientation = ValueNotifier<bool>(false);

/// The orientations allowed on a window this size.
///
/// A large screen rotates freely, a small screen is portrait only — split on
/// the app's existing tablet line ([isTabletSize]: shortest side >= 600 on a
/// device, >= 768 on web). On the iPhone Duo that line falls between the folded
/// cover (shortest side 466 -> portrait) and the unfolded inner display
/// (shortest side 669 -> rotates), which is exactly the wanted behaviour, and
/// an Android fold/flip lands the same way. [shortestSide] is rotation-
/// invariant, so folding or unfolding flips the rule on its own. Pure.
List<DeviceOrientation> appDefaultOrientations(double width, double height, {required bool web}) =>
    isTabletSize(width, height, web: web)
        ? DeviceOrientation.values
        : const [DeviceOrientation.portraitUp];

/// Pins the device to [appDefaultOrientations] for the window it is in now —
/// unless the meter is holding landscape. Called at startup, whenever the
/// window changes shape (a fold/unfold), and when the meter hands rotation
/// back. A no-op before a view exists (a test, a headless start).
Future<void> applyAppDefaultOrientation() {
  if (meterHoldsOrientation.value) return Future<void>.value();
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  if (view == null) return Future<void>.value();
  final size = view.physicalSize / view.devicePixelRatio;
  if (size.isEmpty) return Future<void>.value();
  return SystemChrome.setPreferredOrientations(
    appDefaultOrientations(size.width, size.height, web: kIsWeb),
  );
}
