import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/screens/meterapp/display_logic.dart'
    show NavKind, railRideId, railTripsId, railWalletId, railDriveId, railAccountId;
import '../../core/side_menu.dart';
import '../../data/app_display_repository.dart' show displaySettingsBlobProvider;
import '../../widgets/common.dart';
import '../../widgets/focus_order.dart';
import '../../widgets/media_image.dart' show MediaIcon;
import '../../data/driver_presence.dart';
import '../../data/telematics_tracker.dart' show telematicsTrackerProvider;
import '../partner/driver_online.dart';
import 'app_side_menu.dart' show AppSideMenuHost, SideMenuMode, sideMenuModeAt;

/// The Ride tab's branch in the home shell.
const rideTab = 0;

/// The Drive tab's branch in the home shell.
const driveTab = 3;

/// Each rail tab id and the shell branch it opens. A built-in rail item the
/// admin hasn't relinked goes to its branch; a relinked or custom item
/// navigates by its route instead (see [resolveSideMenu]).
const _railBranch = <String, int>{
  railRideId: 0,
  railTripsId: 1,
  railWalletId: 2,
  railDriveId: 3,
  railAccountId: 4,
};

/// The branch roots in order, to read the current mode off the shell index.
const _branchRoots = ['/', '/trips', '/wallet', '/drive', '/account'];

/// The built-in rail item icons (outline, filled), used unless the admin
/// picks another from the Media Gallery.
const _railIcon = <String, (IconData, IconData)>{
  railRideId: (Icons.local_taxi_outlined, Icons.local_taxi),
  railTripsId: (Icons.receipt_long_outlined, Icons.receipt_long),
  railWalletId: (Icons.account_balance_wallet_outlined, Icons.account_balance_wallet),
  railDriveId: (Icons.drive_eta_outlined, Icons.drive_eta),
  railAccountId: (Icons.person_outline, Icons.person),
};

/// Adaptive navigation: a side menu on phones (the home screen's menu
/// button), a rail on tablets, an extended rail on desktop and wide web
/// windows. While the account is online as a driver the Ride tab is greyed
/// out and can't be opened ([driverOnlineProvider]).
///
/// The rail's tabs come from Admin → Display Settings → Side Rails
/// ([resolveSideMenu] with [NavKind.rail]) — renamed, hidden, reordered,
/// relinked or added to — and the admin's User rail or Partner rail applies
/// by the current mode ([sideMenuModeAt]), the same split as the side menus.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  /// The mode the rail last showed, so a shared page (wallet, account) keeps
  /// the mode that led there, exactly as [AppSideMenuHost] does for the menu.
  SideMenuMode _mode = SideMenuMode.rider;

  @override
  Widget build(BuildContext context) {
    final shell = widget.shell;
    final size = MediaQuery.sizeOf(context);
    final width = size.width;
    final online = ref.watch(driverOnlineProvider);
    // The server learns who is taking rides, and where (migration 0145).
    ref.watch(driverPresenceProvider);
    // How far the driver drives online, for Telematics (migration 0255).
    ref.watch(telematicsTrackerProvider);

    // A phone on its side is wide but short: still the phone layout.
    if (AppSideMenuHost.appliesAt(width, size.height)) {
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

    // The rail follows the mode the shell is in, so the Partner rail shows in
    // driver mode and the User rail otherwise. Caching it (as the menu host
    // does) keeps the mode on a page both modes share.
    final root = _branchRoots[shell.currentIndex.clamp(0, _branchRoots.length - 1)];
    _mode = sideMenuModeAt(root, _mode);
    final audience = _mode == SideMenuMode.partner ? 'partner' : 'user';

    final blob = ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{};
    var entries = resolveSideMenu(blob, audience, kind: NavKind.rail);
    // NavigationRail needs at least two destinations: never let the admin
    // hide the rail down to nothing — fall back to the full default set.
    if (entries.length < 2) entries = resolveSideMenu(const <String, dynamic>{}, audience, kind: NavKind.rail);

    // The slim (icon + label) rail on a tablet, the wide extended rail only on
    // a desktop / wide-web width — so a tablet in landscape (an iPad mini at
    // 1133) keeps the rail narrow and the map its half of the screen.
    final extended = width >= 1300;

    int? selected;
    for (var i = 0; i < entries.length; i++) {
      if (_railBranch[entries[i].id] == shell.currentIndex) {
        selected = i;
        break;
      }
    }

    void go(int i) {
      final e = entries[i];
      if (online && e.id == railRideId) return;
      final branch = _railBranch[e.id];
      if (e.route == null && branch != null) {
        shell.goBranch(branch, initialLocation: branch == shell.currentIndex);
      } else if (e.route != null) {
        context.go(e.route!);
      }
    }

    Widget iconFor(MenuEntry e, {required bool sel}) {
      final fb = _railIcon[e.id];
      final fallback = sel ? (fb?.$2 ?? fb?.$1 ?? Icons.circle) : (fb?.$1 ?? Icons.circle_outlined);
      return MediaIcon(e.iconName, fallback: fallback);
    }

    return Scaffold(
      // Keyboard focus in the order the screen reads: the rail, then the
      // page, and within the page what floats over a map last.
      body: ShellFocusOrder(
        rail: ScrollableRail(
          rail: NavigationRail(
            extended: extended,
            selectedIndex: selected,
            onDestinationSelected: go,
            labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: BrandMark(size: extended ? 26 : 14),
            ),
            destinations: [
              for (final e in entries)
                NavigationRailDestination(
                  disabled: online && e.id == railRideId,
                  icon: iconFor(e, sel: false),
                  selectedIcon: iconFor(e, sel: true),
                  label: Text(e.label),
                ),
            ],
          ),
        ),
        between: const VerticalDivider(width: 1),
        content: shell,
      ),
    );
  }
}
