/// How the app's windows may rotate.
///
/// A phone stays portrait; only a tablet turns. The meter is the single screen
/// that forces its own landscape, and it restores this default on the way out.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show DeviceOrientation, SystemChrome;
import 'package:flutter/widgets.dart' show WidgetsBinding;

import 'launch_destination.dart' show isTabletSize;

/// The orientations the app allows by default on a window this size.
///
/// A phone — the iPhone Duo and an Android fold/flip held open included, since
/// its shortest side is still under a tablet's — is **portrait only**, so the
/// home map/sheet and the admin panels are never squeezed into a short
/// landscape two-pane. A tablet keeps every orientation. The line is the app's
/// existing one ([isTabletSize]: shortest side >= 600 on a device, >= 768 on
/// web). Pure.
List<DeviceOrientation> appDefaultOrientations(double width, double height, {required bool web}) =>
    isTabletSize(width, height, web: web)
        ? DeviceOrientation.values
        : const [DeviceOrientation.portraitUp];

/// Pins the device to [appDefaultOrientations] for the window it is in now.
/// Called once the first frame has sized the view (so a tablet is known as one)
/// and again whenever the meter hands rotation back. A no-op before a view
/// exists (a test, a headless start).
Future<void> applyAppDefaultOrientation() {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  if (view == null) return Future<void>.value();
  final size = view.physicalSize / view.devicePixelRatio;
  if (size.isEmpty) return Future<void>.value();
  return SystemChrome.setPreferredOrientations(
    appDefaultOrientations(size.width, size.height, web: kIsWeb),
  );
}
