import 'package:flutter/widgets.dart';

import '../core/duo_fold.dart' show duoHingeNow;
import '../core/orientation.dart';

/// Keeps the device's allowed orientations in step with the window it is in:
/// applies [appDefaultOrientations] at startup and again whenever the window
/// changes shape — which is how a foldable folding or unfolding (its shortest
/// side crossing the tablet line) flips between portrait-only and free
/// rotation on its own. It also re-applies when the iPhone Duo hinge pose
/// changes ([duoHingeNow]) and when the app returns to the foreground, because
/// on the Duo a portrait pin set on the folded cover can stop iOS ever handing
/// the window the inner display's larger size — so the hinge pose, not the
/// (then frozen) window size, is what unlocks rotation after unfolding. It
/// yields to the meter while the meter is holding landscape (via
/// [meterHoldsOrientation]); the meter re-applies the default when it releases.
class AppOrientationLock extends StatefulWidget {
  const AppOrientationLock({super.key, required this.child});

  final Widget child;

  @override
  State<AppOrientationLock> createState() => _AppOrientationLockState();
}

class _AppOrientationLockState extends State<AppOrientationLock> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The Duo hinge pose is reported promptly and, after unfolding, before the
    // window size catches up — so it, not a (possibly frozen) metrics change,
    // is what re-opens rotation on the inner display.
    duoHingeNow.addListener(_apply);
    // After the first frame the view is sized, so a tablet / unfolded inner is
    // recognised as one before the lock is set.
    WidgetsBinding.instance.addPostFrameCallback((_) => applyAppDefaultOrientation());
  }

  @override
  void dispose() {
    duoHingeNow.removeListener(_apply);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _apply() => applyAppDefaultOrientation();

  // Fires on rotate, resize and — the point here — a fold/unfold that changes
  // the window's shortest side.
  @override
  void didChangeMetrics() => applyAppDefaultOrientation();

  // Folding/unfolding can reconfigure the scene through the background, and a
  // resume can drop the lock; re-assert it on the way back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) applyAppDefaultOrientation();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
