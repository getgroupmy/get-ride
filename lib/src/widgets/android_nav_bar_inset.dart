// Keeps every screen clear of Android's navigation bar. Android 15 draws apps
// edge to edge, under the three buttons (or the gesture bar), so a button at
// the bottom of a page sat behind them and could not be tapped. The space is
// taken off the bottom of the whole app here instead of page by page, filled
// with the page colour; screens below see no bottom inset left, so none is
// added twice.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AndroidNavBarInset extends StatelessWidget {
  const AndroidNavBarInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || Theme.of(context).platform != TargetPlatform.android) return child;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(top: false, left: false, right: false, child: child),
    );
  }
}
