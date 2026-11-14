/// How the app's windows may rotate.
///
/// Every screen is portrait — a phone, a foldable (iPhone Duo, Android
/// fold/flip) and a tablet alike. The taxi meter is the single exception: it
/// forces its own landscape (a dash-mounted meter) and restores this portrait
/// default on the way out.
library;

import 'package:flutter/services.dart' show DeviceOrientation, SystemChrome;

/// The orientations the app allows on every screen but the meter: portrait.
const appDefaultOrientations = <DeviceOrientation>[DeviceOrientation.portraitUp];

/// Pins the device to [appDefaultOrientations]. Called at startup and whenever
/// the meter hands rotation back.
Future<void> applyAppDefaultOrientation() =>
    SystemChrome.setPreferredOrientations(appDefaultOrientations);
