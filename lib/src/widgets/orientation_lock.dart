import 'package:flutter/widgets.dart';

import '../core/orientation.dart';

/// Keeps the device's allowed orientations in step with the window it is in:
/// applies [appDefaultOrientations] at startup and again whenever the window
/// changes shape — which is how a foldable folding or unfolding (its shortest
/// side crossing the tablet line) flips between portrait-only and free
/// rotation on its own. It yields to the meter while the meter is holding
/// landscape (via [meterHoldsOrientation]); the meter re-applies the default
/// when it releases.
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
    // After the first frame the view is sized, so a tablet / unfolded inner is
    // recognised as one before the lock is set.
    WidgetsBinding.instance.addPostFrameCallback((_) => applyAppDefaultOrientation());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Fires on rotate, resize and — the point here — a fold/unfold that changes
  // the window's shortest side.
  @override
  void didChangeMetrics() => applyAppDefaultOrientation();

  @override
  Widget build(BuildContext context) => widget.child;
}
