import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/common.dart';
import '../partner/driver_online.dart';

class _Dest {
  const _Dest(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const _destinations = [
  _Dest('Ride', Icons.local_taxi_outlined, Icons.local_taxi),
  _Dest('Trips', Icons.receipt_long_outlined, Icons.receipt_long),
  _Dest('Wallet', Icons.account_balance_wallet_outlined, Icons.account_balance_wallet),
  _Dest('Drive', Icons.drive_eta_outlined, Icons.drive_eta),
  _Dest('Account', Icons.person_outline, Icons.person),
];

/// The Ride tab's place in [_destinations].
const rideTab = 0;

/// The Drive tab's place in [_destinations].
const driveTab = 3;

/// Adaptive navigation: a side menu on phones (the home screen's menu
/// button), a rail on tablets, an extended rail on desktop and wide web
/// windows. While the account is online as a driver
/// the Ride tab is greyed out and can't be opened ([driverOnlineProvider]).
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final online = ref.watch(driverOnlineProvider);
    void go(int i) {
      if (online && i == rideTab) return;
      shell.goBranch(i, initialLocation: i == shell.currentIndex);
    }

    if (width < 720) {
      // Trips, Wallet and Account are pages off the home screen here: back
      // from one returns home. Drive is a mode, left from its own menu.
      final page = shell.currentIndex != rideTab && shell.currentIndex != driveTab;
      return PopScope(
        canPop: !page,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && page) shell.goBranch(rideTab);
        },
        child: shell,
      );
    }
    final extended = width >= 1100;
    return Scaffold(
      body: Row(children: [
        NavigationRail(
          extended: extended,
          selectedIndex: shell.currentIndex,
          onDestinationSelected: go,
          labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
          leading: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: BrandMark(size: extended ? 26 : 14),
          ),
          destinations: [
            for (final (i, d) in _destinations.indexed)
              NavigationRailDestination(
                disabled: online && i == rideTab,
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: Text(d.label),
              ),
          ],
        ),
        const VerticalDivider(width: 1),
        Expanded(child: shell),
      ]),
    );
  }
}
