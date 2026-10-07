import 'package:flutter/material.dart';

import '../../widgets/side_menu_host.dart';
import '../profile/account_screen.dart' show RiderMenu;

/// The rider's pages under the Expo side menu ([SideMenuHost]): on phones,
/// everywhere but driver mode, which has a menu of its own.
class RiderSideMenuHost extends StatelessWidget {
  const RiderSideMenuHost({super.key, required this.location, required this.child});

  /// Where the app is, which decides whether the menu applies.
  final String location;
  final Widget child;

  /// Whether the rider menu applies at [location] on a screen [width] wide:
  /// phones only (wider screens have the rail), and not in driver mode.
  static bool appliesAt(String location, double width) =>
      width < 720 && !(location == '/drive' || location.startsWith('/drive/'));

  @override
  Widget build(BuildContext context) => SideMenuHost(
    enabled: appliesAt(location, MediaQuery.sizeOf(context).width),
    menu: const RiderSideMenu(),
    child: child,
  );
}

/// The side menu's panel: the rider menu, which closes the menu before it
/// opens a page.
class RiderSideMenu extends StatelessWidget {
  const RiderSideMenu({super.key});

  @override
  Widget build(BuildContext context) => Material(
    key: const ValueKey('rider-side-menu'),
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      right: false,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [RiderMenu(beforeOpen: SideMenuHost.of(context)?.close)],
      ),
    ),
  );
}
